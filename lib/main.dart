import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter/services.dart';

// ============================================================
//  DEMO MODE — true = test on ANY phone with NO hardware
//  (Bluetooth + voice both simulated). false = talk to real PCB.
// ============================================================
const bool kDemoMode = false;

const int kAutoCloseSecs = 30;

// ---- BLE contract (must match the firmware) ----
final Guid kSvcUuid   = Guid("a0b40001-7de2-4a3f-9c11-6f0f9e5a12b3");
final Guid kCmdUuid   = Guid("a0b40002-7de2-4a3f-9c11-6f0f9e5a12b3");
final Guid kStateUuid = Guid("a0b40003-7de2-4a3f-9c11-6f0f9e5a12b3");

// ---- Brand palette ----
const kInk   = Color(0xFF0B2A33);
const kInk2  = Color(0xFF0E3540);
const kCyan  = Color(0xFF09CFFE);
const kMint  = Color(0xFF8EDBD3);
const kMuted = Color(0xFF9FB8BF);

void main() => runApp(const GoFlowApp());

class GoFlowApp extends StatelessWidget {
  const GoFlowApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoFlowX',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(scaffoldBackgroundColor: kInk, fontFamily: 'Roboto'),
      home: const ControlScreen(),
    );
  }
}

enum Conn { idle, scanning, connecting, ready, disconnected }

String connLabel(Conn c) {
  switch (c) {
    case Conn.scanning: return 'SEARCHING…';
    case Conn.connecting: return 'CONNECTING…';
    case Conn.ready: return 'CONNECTED';
    case Conn.disconnected: return 'DISCONNECTED';
    default: return 'NOT CONNECTED';
  }
}

class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key});
  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final ValueNotifier<Conn> _connN = ValueNotifier(Conn.idle);
  Conn get _conn => _connN.value;
  void _setConn(Conn c) { _connN.value = c; if (mounted) setState(() {}); }

  BluetoothDevice? _device;
  BluetoothCharacteristic? _cmd;
  BluetoothCharacteristic? _state;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _stateSub;

  Timer? _cmdTimer;
  Timer? _demoTimer;
  Timer? _voiceTimer;

  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;
  bool _voiceOn = false;
  String _lastHeard = '';

  bool _holding = false;
  bool _voiceLatched = false;
  int _voiceRemaining = 0;
  bool get _open => _holding || _voiceLatched;

  int _stateByte = 0;
  int _pct = 0;

  late final AnimationController _bagCtrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bagCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 3));
    _bootstrap();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_voiceOn && _speechReady && !_speech.isListening) _listen();
    } else {
      _speech.stop();
    }
  }

  Future<void> _bootstrap() async {
    if (kDemoMode) {
      _startDemo();
      await _initVoice();
      return;
    }
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.microphone,
    ].request();
    await _initVoice();
    _startScan();
  }

  void _startDemo() {
    _setConn(Conn.ready);
    _demoTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      const step = 50 / 4000 * 100;
      if (_open && _pct < 100) _pct = (_pct + step).clamp(0, 100).round();
      if (!_open && _pct > 0)  _pct = (_pct - step).clamp(0, 100).round();
      int s;
      if (_pct <= 0 && !_open)      s = 0;
      else if (_pct >= 100 && _open) s = 2;
      else s = _open ? 1 : 3;
      if (mounted) setState(() => _stateByte = s);
    });
  }

  // Triggered by the Connect screen's "Search" button (and at startup).
  void _userSearch() {
    if (kDemoMode) {
      _setConn(Conn.scanning);
      Future.delayed(const Duration(milliseconds: 1500), () => _setConn(Conn.ready));
      return;
    }
    _startScan();
  }

  Future<void> _startScan() async {
    await _teardownConnection();
    _setConn(Conn.scanning);
    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) async {
      if (results.isEmpty) return;
      final r = results.first;
      await FlutterBluePlus.stopScan();
      _scanSub?.cancel();
      _connect(r.device);
    });
    try {
      await FlutterBluePlus.startScan(
        withServices: [kSvcUuid],
        timeout: const Duration(seconds: 15),
      );
    } catch (_) {
      _setConn(Conn.disconnected);
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    _device = device;
    _setConn(Conn.connecting);
    _connSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) _setConn(Conn.disconnected);
    });
    try {
      await device.connect(timeout: const Duration(seconds: 12));
      await Future.delayed(const Duration(milliseconds: 500));
      final services = await device.discoverServices();
      for (final svc in services) {
        if (svc.uuid != kSvcUuid) continue;
        for (final c in svc.characteristics) {
          if (c.uuid == kCmdUuid) _cmd = c;
          if (c.uuid == kStateUuid) _state = c;
        }
      }
      if (_cmd == null || _state == null) {
        await device.disconnect();
        _setConn(Conn.disconnected);
        return;
      }
      await _state!.setNotifyValue(true);
      _stateSub = _state!.onValueReceived.listen((v) {
        if (v.length >= 2 && mounted) {
          setState(() { _stateByte = v[0]; _pct = v[1]; });
        }
      });
      device.cancelWhenDisconnected(_stateSub!);
      _setConn(Conn.ready);
    } catch (_) {
      _setConn(Conn.disconnected);
    }
  }

  Future<void> _teardownConnection() async {
    _holding = false;
    _voiceLatched = false;
    _cmdTimer?.cancel(); _cmdTimer = null;
    _voiceTimer?.cancel(); _voiceTimer = null;
    await _stateSub?.cancel();
    await _connSub?.cancel();
    try { await _device?.disconnect(); } catch (_) {}
    _cmd = null; _state = null; _device = null;
  }

  void _applyOpen() {
    if (_open) {
      if (_cmdTimer == null) {
        _sendCmd(0x01);
        _cmdTimer = Timer.periodic(const Duration(milliseconds: 400), (_) => _sendCmd(0x01));
      }
      if (!_bagCtrl.isAnimating) _bagCtrl.repeat();
    } else {
      _cmdTimer?.cancel();
      _cmdTimer = null;
      _sendCmd(0x00);
      _bagCtrl.stop();
      _bagCtrl.value = 0.0;
    }
    if (mounted) setState(() {});
  }

  void _sendCmd(int byte) {
    final c = _cmd;
    if (c == null) return;
    c.write([byte], withoutResponse: true).catchError((_) {});
  }

  void _startHold() {
    if (_conn != Conn.ready) return;
    _holding = true;
    _applyOpen();
  }
  void _endHold() {
    if (!_holding) return;
    _holding = false;
    _applyOpen();
  }

  void _voiceOpen() {
    _voiceLatched = true;
    _voiceRemaining = kAutoCloseSecs;
    _voiceTimer?.cancel();
    _voiceTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _voiceRemaining--;
      if (_voiceRemaining <= 0) { t.cancel(); _voiceClose(); }
      else if (mounted) setState(() {});
    });
    _applyOpen();
  }

  void _voiceClose() {
    _voiceLatched = false;
    _voiceTimer?.cancel();
    _voiceTimer = null;
    _voiceRemaining = 0;
    _applyOpen();
  }

  Future<void> _initVoice() async {
    try {
      _speechReady = await _speech.initialize(onStatus: _onSpeechStatus, onError: (e) {});
    } catch (_) {
      _speechReady = false;
    }
    if (_speechReady) { _voiceOn = true; _listen(); }
    if (mounted) setState(() {});
  }

  void _toggleVoice() {
    if (!_speechReady) return;
    if (_voiceOn) { _voiceOn = false; _speech.stop(); }
    else { _voiceOn = true; _listen(); }
    setState(() {});
  }

  void _listen() {
    if (!_voiceReady()) return;
    _speech.listen(
      onResult: _onSpeech,
      listenFor: const Duration(seconds: 60),
      pauseFor: const Duration(seconds: 10),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        onDevice: false,
        listenMode: ListenMode.dictation,
      ),
    );
  }

  bool _voiceReady() => _speechReady && _voiceOn;

  void _onSpeechStatus(String status) {
    if ((status == 'done' || status == 'notListening') && _voiceOn) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (_voiceReady() && !_speech.isListening) _listen();
      });
    }
  }

  void _onSpeech(SpeechRecognitionResult result) {
    final words = result.recognizedWords.toLowerCase();
    if (words.isEmpty) return;

    String? cmd;
    if (words.contains('exit') || words.contains('quit') || words.contains('goodbye') ||
        (words.contains('close') && words.contains('app'))) {
      cmd = 'exit';
      _closeApp();
    } else if (words.contains('close') || words.contains('shut') || words.contains('stop')) {
      cmd = 'close';
      _voiceClose();
    } else if (words.contains('open') || words.contains('drain')) {
      cmd = 'open';
      _voiceOpen();
    }

    // Only react to and show recognised commands - ignore everything else the
    // mic picks up, so random speech isn't transcribed or displayed.
    if (cmd != null) {
      _lastHeard = cmd;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bagCtrl.dispose();
    _demoTimer?.cancel();
    _voiceTimer?.cancel();
    _cmdTimer?.cancel();
    _speech.stop();
    _teardownConnection();
    super.dispose();
  }

  String get _statusText {
    switch (_stateByte) {
      case 1: return 'OPENING';
      case 2: return 'OPEN';
      case 3: return 'CLOSING';
      default: return 'CLOSED';
    }
  }
  bool get _isOpen => _stateByte != 0;

  // ---- menu actions ----
  void _openConnect() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ConnectScreen(status: _connN, onSearch: _userSearch),
    ));
  }
  void _closeApp() {
    _holding = false;
    _voiceLatched = false;
    _voiceOn = false;
    _applyOpen();        // sends the valve a close command and stops the animation
    _speech.stop();      // stop listening so the beeping stops
    SystemNavigator.pop(); // close the app
  }
  void _showHelp() {
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: kInk2,
      title: const Text('How to use', style: TextStyle(color: Colors.white)),
      content: const Text(
        '• Hold the circle to open the valve; release to close.\n'
        '• Or just say “open” and “close”.\n'
        '• Say “exit” (or “quit”) to close the app.\n'
        '• It always closes after 30 seconds for safety.\n\n'
        'Not connected? Open the menu → Connect.',
        style: TextStyle(color: kMuted, height: 1.5)),
      actions: [TextButton(onPressed: () => Navigator.pop(context),
        child: const Text('Got it', style: TextStyle(color: kCyan)))],
    ));
  }
  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'GoFlowX',
      applicationVersion: '1.0.0',
      applicationIcon: Image.asset('logo.png', height: 30),
      children: const [Text('Smart, app-controlled flow management in one device.')],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = _conn == Conn.ready;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _topBarAndLogo(),
              _statusBlock(),
              _holdButton(ready),
              _voicePanel(),
              _footer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBarAndLogo() {
    final ready = _conn == Conn.ready;
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: const [
          Icon(Icons.battery_full, color: kMint, size: 18),
          SizedBox(width: 4),
          Text('87%', style: TextStyle(color: kMint, fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
        PopupMenuButton<String>(
          icon: const Icon(Icons.menu, color: kMuted),
          color: kInk2,
          onSelected: (v) {
            if (v == 'connect') _openConnect();
            else if (v == 'help') _showHelp();
            else if (v == 'about') _showAbout();
            else if (v == 'exit') _closeApp();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'connect', child: Text('Connect', style: TextStyle(color: Colors.white))),
            PopupMenuItem(value: 'help', child: Text('Help', style: TextStyle(color: Colors.white))),
            PopupMenuItem(value: 'about', child: Text('About', style: TextStyle(color: Colors.white))),
            PopupMenuItem(value: 'exit', child: Text('Close app', style: TextStyle(color: Color(0xFFFF6B6B)))),
          ],
        ),
      ]),
      Image.asset('logo.png', height: 72),
      const SizedBox(height: 8),
      GestureDetector(
        onTap: _openConnect,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(
            shape: BoxShape.circle, color: ready ? kCyan : const Color(0xFF3A6470))),
          const SizedBox(width: 7),
          Text(connLabel(_conn), style: const TextStyle(fontSize: 12, letterSpacing: 2, color: kMuted)),
        ]),
      ),
    ]);
  }

  Widget _statusBlock() {
    return Column(children: [
      Text(_conn == Conn.ready ? _statusText : '—',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 3,
          color: _isOpen ? kCyan : kMint)),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(width: 200, height: 6,
          child: LinearProgressIndicator(
            value: (_pct.clamp(0, 100)) / 100.0,
            backgroundColor: const Color(0xFF0A3742),
            valueColor: const AlwaysStoppedAnimation(kCyan))),
      ),
      const SizedBox(height: 14),
      _bag(),
      if (_open)
        const Padding(padding: EdgeInsets.only(top: 6),
          child: Text('draining…', style: TextStyle(fontSize: 11, color: kMint, letterSpacing: 1))),
      if (_voiceLatched)
        Padding(padding: const EdgeInsets.only(top: 8),
          child: Text('Auto-closing in $_voiceRemaining s',
            style: const TextStyle(fontSize: 12, color: kCyan, fontWeight: FontWeight.w600))),
    ]);
  }

  Widget _bag() {
    return SizedBox(
      width: 58, height: 74,
      child: AnimatedBuilder(
        animation: _bagCtrl,
        builder: (context, _) {
          final v = _bagCtrl.value;
          final level = _open ? (0.72 - 0.60 * v).clamp(0.10, 0.72) : 0.72;
          final frac = (v * 3) % 1.0;
          return Stack(clipBehavior: Clip.none, children: [
            Positioned.fill(child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0A3742),
                border: Border.all(color: const Color(0xFF2C5560), width: 2),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(8), bottom: Radius.circular(14))),
              clipBehavior: Clip.antiAlias,
              child: Align(alignment: Alignment.bottomCenter,
                child: FractionallySizedBox(heightFactor: level, widthFactor: 1,
                  child: Container(color: const Color(0xFF2BB6C9)))),
            )),
            Positioned(bottom: -6, left: 25, child: Container(width: 8, height: 8,
              decoration: const BoxDecoration(color: Color(0xFF2C5560),
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(3))))),
            if (_open)
              Positioned(bottom: -6 - frac * 16, left: 26,
                child: Opacity(opacity: (1 - frac).clamp(0.0, 1.0),
                  child: Transform.rotate(angle: 0.785,
                    child: Container(width: 6, height: 6,
                      decoration: const BoxDecoration(color: Color(0xFF2BB6C9),
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(3), topRight: Radius.circular(3),
                          bottomRight: Radius.circular(3))))))),
          ]);
        },
      ),
    );
  }

  Widget _holdButton(bool ready) {
    final active = _open;
    return GestureDetector(
      onTapDown: (_) => _startHold(),
      onTapUp: (_) => _endHold(),
      onTapCancel: _endHold,
      child: AnimatedScale(
        scale: _holding ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Container(
          width: 176, height: 176,
          decoration: BoxDecoration(shape: BoxShape.circle,
            color: active ? kCyan : kInk2,
            border: Border.all(color: active ? Colors.white.withOpacity(.4) : kCyan.withOpacity(.35), width: 2)),
          child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('HOLD TO OPEN', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: 1,
              color: active ? const Color(0xFF03222A) : (ready ? const Color(0xFFCFE9EF) : kMuted))),
            const SizedBox(height: 5),
            Text(ready ? 'or use voice below' : 'connect first',
              style: TextStyle(fontSize: 11, color: active ? const Color(0xFF06363F) : kMuted)),
          ])),
        ),
      ),
    );
  }

  Widget _voicePanel() {
    final on = _voiceOn;
    return Column(children: [
      GestureDetector(
        onTap: _speechReady ? _toggleVoice : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(color: on ? kCyan : kInk2,
            borderRadius: BorderRadius.circular(30), border: Border.all(color: kCyan.withOpacity(.35))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(on ? Icons.mic : Icons.mic_none, color: on ? const Color(0xFF03222A) : kCyan, size: 20),
            const SizedBox(width: 10),
            Text(!_speechReady ? 'Voice unavailable'
                : on ? 'Listening hands-free — “open” / “close”  (tap to mute)' : 'Voice off — tap to listen',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                color: on ? const Color(0xFF03222A) : Colors.white)),
          ]),
        ),
      ),
      if (on && _lastHeard.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 8),
          child: Text('heard: “$_lastHeard”',
            style: const TextStyle(fontSize: 11, color: kMuted, fontStyle: FontStyle.italic))),
    ]);
  }

  Widget _footer() {
    final disconnected = _conn == Conn.disconnected || _conn == Conn.idle;
    return Column(children: [
      const Text(
        'Hold the button or say “open”. The valve closes when you release, '
        'say “close”, or after 30 seconds — whichever comes first.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: kMuted, height: 1.5)),
      const SizedBox(height: 8),
      if (disconnected)
        OutlinedButton(onPressed: _openConnect,
          style: OutlinedButton.styleFrom(foregroundColor: kCyan, side: const BorderSide(color: kCyan)),
          child: const Text('Connect')),
    ]);
  }
}

// =====================================================================
//  CONNECT SCREEN — reached from the menu. Instructions + Search button.
// =====================================================================
class ConnectScreen extends StatelessWidget {
  final ValueNotifier<Conn> status;
  final VoidCallback onSearch;
  const ConnectScreen({super.key, required this.status, required this.onSearch});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kInk,
      appBar: AppBar(
        backgroundColor: kInk, elevation: 0, foregroundColor: Colors.white,
        title: const Text('Connect'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(children: [
            const Icon(Icons.bluetooth, color: kCyan, size: 34),
            const SizedBox(height: 8),
            const Text('Connect to GoFlowX',
              style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            ValueListenableBuilder<Conn>(
              valueListenable: status,
              builder: (_, c, __) {
                final ready = c == Conn.ready;
                final busy = c == Conn.scanning || c == Conn.connecting;
                return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Container(width: 9, height: 9, decoration: BoxDecoration(shape: BoxShape.circle,
                    color: ready ? kCyan : busy ? const Color(0xFFF0B400) : const Color(0xFF3A6470))),
                  const SizedBox(width: 8),
                  Text(connLabel(c).replaceAll('…', '').trim().toLowerCase(),
                    style: const TextStyle(color: kMuted, fontSize: 13)),
                ]);
              },
            ),
            const SizedBox(height: 22),
            _step(1, 'Turn the GoFlowX device on. A light shows it is awake.'),
            _step(2, 'Make sure your phone\u2019s Bluetooth is switched on.'),
            _step(3, 'Tap \u201cSearch for device\u201d below.'),
            _step(4, 'It finds \u201cGoFlowX\u201d and connects on its own. A green dot means ready.'),
            const Spacer(),
            ValueListenableBuilder<Conn>(
              valueListenable: status,
              builder: (_, c, __) {
                final ready = c == Conn.ready;
                final busy = c == Conn.scanning || c == Conn.connecting;
                return SizedBox(width: double.infinity, child: ElevatedButton.icon(
                  onPressed: (ready || busy) ? null : onSearch,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ready ? kInk2 : kCyan,
                    disabledBackgroundColor: ready ? kInk2 : const Color(0xFF0E3540),
                    foregroundColor: ready ? Colors.white : const Color(0xFF03222A),
                    disabledForegroundColor: ready ? kCyan : kMuted,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  icon: Icon(ready ? Icons.check : Icons.search),
                  label: Text(ready ? 'Connected' : busy ? 'Searching…' : 'Search for device',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ));
              },
            ),
            const SizedBox(height: 14),
            const Text('Trouble connecting? Make sure the device is on and within a few metres, '
              'then toggle Bluetooth off and on.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Color(0xFF6E8B93), height: 1.5)),
          ]),
        ),
      ),
    );
  }

  Widget _step(int n, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 26, height: 26, alignment: Alignment.center,
          decoration: const BoxDecoration(color: kInk2, shape: BoxShape.circle),
          child: Text('$n', style: const TextStyle(color: kCyan, fontSize: 13, fontWeight: FontWeight.w700))),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(color: Color(0xFFD6E6EA), fontSize: 13, height: 1.45))),
      ]),
    );
  }
}
