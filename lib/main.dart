import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

// ============================================================
//  DEMO MODE — true = test on ANY phone with NO hardware
//  (Bluetooth + voice both work). false = talk to the real PCB.
// ============================================================
const bool kDemoMode = true;

// How long a voice "open" stays open before auto-closing (safety).
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
      title: 'GoFlow',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(scaffoldBackgroundColor: kInk, fontFamily: 'Roboto'),
      home: const ControlScreen(),
    );
  }
}

enum Conn { idle, scanning, connecting, ready, disconnected }

class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key});
  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  Conn _conn = Conn.idle;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _cmd;
  BluetoothCharacteristic? _state;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _stateSub;

  Timer? _cmdTimer;    // heartbeat: writes "open" repeatedly while open
  Timer? _demoTimer;   // demo-mode position animation
  Timer? _voiceTimer;  // 30s auto-close countdown for voice-open

  // ---- voice ----
  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;
  bool _voiceOn = false;     // mic listening enabled
  String _lastHeard = '';

  // ---- open intent ----
  bool _holding = false;       // finger on the button
  bool _voiceLatched = false;  // voice said "open"
  int _voiceRemaining = 0;     // seconds left before auto-close

  bool get _open => _holding || _voiceLatched;

  // ---- valve state from device ----
  int _stateByte = 0; // 0 closed,1 opening,2 open,3 closing
  int _pct = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
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

  // ---- DEMO: pretend a device is connected, integrate position locally ----
  void _startDemo() {
    setState(() => _conn = Conn.ready);
    _demoTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      const step = 50 / 4000 * 100; // 4s full travel
      if (_open && _pct < 100) _pct = (_pct + step).clamp(0, 100).round();
      if (!_open && _pct > 0)  _pct = (_pct - step).clamp(0, 100).round();
      int s;
      if (_pct <= 0 && !_open)      s = 0;
      else if (_pct >= 100 && _open) s = 2;
      else s = _open ? 1 : 3;
      if (mounted) setState(() => _stateByte = s);
    });
  }

  // ---- BLE ----
  Future<void> _startScan() async {
    await _teardownConnection();
    setState(() => _conn = Conn.scanning);
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
      if (mounted) setState(() => _conn = Conn.disconnected);
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    _device = device;
    setState(() => _conn = Conn.connecting);
    _connSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected && mounted) {
        setState(() => _conn = Conn.disconnected);
      }
    });
    try {
      await device.connect(timeout: const Duration(seconds: 12));
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
        if (mounted) setState(() => _conn = Conn.disconnected);
        return;
      }
      await _state!.setNotifyValue(true);
      _stateSub = _state!.onValueReceived.listen((v) {
        if (v.length >= 2 && mounted) {
          setState(() { _stateByte = v[0]; _pct = v[1]; });
        }
      });
      device.cancelWhenDisconnected(_stateSub!);
      if (mounted) setState(() => _conn = Conn.ready);
    } catch (_) {
      if (mounted) setState(() => _conn = Conn.disconnected);
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

  // ---- the one place that turns "open intent" into action ----
  void _applyOpen() {
    if (_open) {
      if (_cmdTimer == null) {
        _sendCmd(0x01);
        _cmdTimer = Timer.periodic(const Duration(milliseconds: 400), (_) => _sendCmd(0x01));
      }
    } else {
      _cmdTimer?.cancel();
      _cmdTimer = null;
      _sendCmd(0x00);
    }
    if (mounted) setState(() {});
  }

  void _sendCmd(int byte) {
    final c = _cmd;
    if (c == null) return; // demo or not connected: no-op
    c.write([byte], withoutResponse: true).catchError((_) {});
  }

  // ---- button: hold-to-open ----
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

  // ---- voice commands ----
  void _voiceOpen() {
    _voiceLatched = true;
    _voiceRemaining = kAutoCloseSecs;
    _voiceTimer?.cancel();
    _voiceTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _voiceRemaining--;
      if (_voiceRemaining <= 0) {
        t.cancel();
        _voiceClose(); // auto-close safety
      } else if (mounted) {
        setState(() {});
      }
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

  // ---- speech engine ----
  Future<void> _initVoice() async {
    try {
      _speechReady = await _speech.initialize(
        onStatus: _onSpeechStatus,
        onError: (e) {},
      );
    } catch (_) {
      _speechReady = false;
    }
    if (mounted) setState(() {});
  }

  void _toggleVoice() {
    if (!_speechReady) return;
    if (_voiceOn) {
      _voiceOn = false;
      _speech.stop();
    } else {
      _voiceOn = true;
      _listen();
    }
    setState(() {});
  }

  void _listen() {
    if (!_voiceReady()) return;
    _speech.listen(
      onResult: _onSpeech,
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 2),
      partialResults: true,
    );
  }

  bool _voiceReady() => _speechReady && _voiceOn;

  void _onSpeechStatus(String status) {
    // keep listening continuously while voice is on
    if ((status == 'done' || status == 'notListening') && _voiceOn) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (_voiceReady() && !_speech.isListening) _listen();
      });
    }
  }

  void _onSpeech(SpeechRecognitionResult result) {
    final words = result.recognizedWords.toLowerCase();
    if (words.isEmpty) return;
    _lastHeard = words;
    // act on whole words to avoid false triggers
    final hasOpen = RegExp(r'\bopen\b').hasMatch(words);
    final hasClose = RegExp(r'\bclose\b').hasMatch(words);
    if (hasClose) {
      _voiceClose();
    } else if (hasOpen) {
      _voiceOpen();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final ready = _conn == Conn.ready;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _header(),
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

  Widget _header() {
    return Column(children: [
      RichText(
        text: const TextSpan(
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: .5, color: Colors.white),
          children: [TextSpan(text: 'GO'), TextSpan(text: 'FLOW', style: TextStyle(color: kCyan))],
        ),
      ),
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(
          shape: BoxShape.circle, color: _conn == Conn.ready ? kCyan : const Color(0xFF3A6470))),
        const SizedBox(width: 7),
        Text(_connLabel(), style: const TextStyle(fontSize: 12, letterSpacing: 2, color: kMuted)),
      ]),
    ]);
  }

  String _connLabel() {
    switch (_conn) {
      case Conn.scanning: return 'SEARCHING…';
      case Conn.connecting: return 'CONNECTING…';
      case Conn.ready: return 'CONNECTED';
      case Conn.disconnected: return 'DISCONNECTED';
      default: return 'VALVE CONTROL';
    }
  }

  Widget _statusBlock() {
    return Column(children: [
      Text(_conn == Conn.ready ? _statusText : '—',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 3,
          color: _isOpen ? kCyan : kMint)),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 200, height: 6,
          child: LinearProgressIndicator(
            value: (_pct.clamp(0, 100)) / 100.0,
            backgroundColor: const Color(0xFF0A3742),
            valueColor: const AlwaysStoppedAnimation(kCyan),
          ),
        ),
      ),
      if (_voiceLatched)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('Auto-closing in $_voiceRemaining s',
            style: const TextStyle(fontSize: 12, color: kCyan, fontWeight: FontWeight.w600)),
        ),
    ]);
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
          width: 210, height: 210,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? kCyan : kInk2,
            border: Border.all(color: active ? Colors.white.withOpacity(.4) : kCyan.withOpacity(.35), width: 2),
          ),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('HOLD TO OPEN',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: 1,
                  color: active ? const Color(0xFF03222A) : (ready ? const Color(0xFFCFE9EF) : kMuted))),
              const SizedBox(height: 5),
              Text(ready ? 'or use voice below' : 'connect first',
                style: TextStyle(fontSize: 11, color: active ? const Color(0xFF06363F) : kMuted)),
            ]),
          ),
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
          decoration: BoxDecoration(
            color: on ? kCyan : kInk2,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: kCyan.withOpacity(.35)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(on ? Icons.mic : Icons.mic_none,
              color: on ? const Color(0xFF03222A) : kCyan, size: 20),
            const SizedBox(width: 10),
            Text(
              !_speechReady ? 'Voice unavailable'
                : on ? 'Listening — say “open” or “close”' : 'Tap to turn on voice',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                color: on ? const Color(0xFF03222A) : Colors.white)),
          ]),
        ),
      ),
      if (on && _lastHeard.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('heard: “$_lastHeard”',
            style: const TextStyle(fontSize: 11, color: kMuted, fontStyle: FontStyle.italic)),
        ),
    ]);
  }

  Widget _footer() {
    final disconnected = _conn == Conn.disconnected || _conn == Conn.idle;
    return Column(children: [
      const Text(
        'Hold the button or say “open”. The valve closes when you release, '
        'say “close”, or after 30 seconds — whichever comes first.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: kMuted, height: 1.5),
      ),
      const SizedBox(height: 10),
      if (disconnected)
        OutlinedButton(
          onPressed: _startScan,
          style: OutlinedButton.styleFrom(
            foregroundColor: kCyan, side: const BorderSide(color: kCyan)),
          child: const Text('Reconnect'),
        ),
    ]);
  }
}
