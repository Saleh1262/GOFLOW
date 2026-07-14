import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ============================================================
//  DEMO MODE — true = test on ANY phone with NO hardware
//  (Bluetooth + voice both simulated). false = talk to real PCB.
// ============================================================
const bool kDemoMode = false;

const int kAutoCloseSecs = 30;

// ---- Battery thresholds (device pack, reported by firmware) ----
const int kBattWarnPct = 20;      // "charge soon" warning
const int kBattCriticalPct = 10;  // app shuts down; firmware refuses OPEN

// ---- Scheduled drainage ----
const int kPreDrainWarnSecs = 60; // warning window before a scheduled drain
const int kMaxDrainSecs = 30;     // hard cap, same as kAutoCloseSecs

// ---- BLE contract (must match the firmware) ----
final Guid kSvcUuid   = Guid("a0b40001-7de2-4a3f-9c11-6f0f9e5a12b3");
final Guid kCmdUuid   = Guid("a0b40002-7de2-4a3f-9c11-6f0f9e5a12b3");
final Guid kStateUuid = Guid("a0b40003-7de2-4a3f-9c11-6f0f9e5a12b3");
final Guid kBattSvcUuid  = Guid("0000180f-0000-1000-8000-00805f9b34fb");
final Guid kBattChrUuid  = Guid("00002a19-0000-1000-8000-00805f9b34fb");

// ---- Brand palette ----
const kInk   = Color(0xFF0B2A33);
const kInk2  = Color(0xFF0E3540);
const kCyan  = Color(0xFF09CFFE);
const kMint  = Color(0xFF8EDBD3);
const kMuted = Color(0xFF9FB8BF);
const kAmber = Color(0xFFF0B400);
const kRed   = Color(0xFFFF6B6B);

final FlutterLocalNotificationsPlugin _notifPlugin = FlutterLocalNotificationsPlugin();

Future<void> _initNotifications() async {
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _notifPlugin.initialize(const InitializationSettings(android: android));
}

Future<void> _notify(int id, String title, String body) async {
  const det = AndroidNotificationDetails(
    'goflow_alerts', 'GoFlowX alerts',
    channelDescription: 'Drain schedule and battery alerts',
    importance: Importance.max, priority: Priority.high, playSound: true);
  try {
    await _notifPlugin.show(id, title, body, const NotificationDetails(android: det));
  } catch (_) {}
}

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
  State<ControlScreen> createState() => ControlScreenState();
}

class ControlScreenState extends State<ControlScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final ValueNotifier<Conn> _connN = ValueNotifier(Conn.idle);
  Conn get _conn => _connN.value;
  void _setConn(Conn c) { _connN.value = c; if (mounted) setState(() {}); }

  BluetoothDevice? _device;
  BluetoothCharacteristic? _cmd;
  BluetoothCharacteristic? _state;
  BluetoothCharacteristic? _batt;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _stateSub;
  StreamSubscription<List<int>>? _battSub;

  Timer? _cmdTimer;
  Timer? _demoTimer;
  Timer? _voiceTimer;
  Timer? _schedTicker;
  Timer? _drainTimer;
  Timer? _shutdownTimer;

  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;
  bool _voiceOn = false;
  String _lastHeard = '';

  bool _holding = false;
  bool _voiceLatched = false;
  bool _schedLatched = false;
  int _voiceRemaining = 0;
  int _drainRemaining = 0;
  DateTime? _holdStart;
  DateTime? _voiceStart;
  bool get _open => _holding || _voiceLatched || _schedLatched;

  int _stateByte = 0;
  int _pct = 0;

  // ---- Battery ----
  int? _battPct;
  bool _battWarned = false;
  bool _shuttingDown = false;

  // ---- Schedule ----
  bool schedOn = false;
  List<TimeOfDay> schedTimes = [];
  int drainSecs = kMaxDrainSecs;
  DateTime? _skipBefore;
  DateTime? _pending;        // occurrence currently in its warning window
  bool _pendingCancelled = false;
  int _preSecs = 0;

  // ---- Drain log: newest first. {t: iso, s: source, d: seconds} ----
  List<Map<String, dynamic>> log = [];

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
    await _loadPrefs();
    await _initNotifications();
    _schedTicker = Timer.periodic(const Duration(seconds: 1), (_) => _schedTick());
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
      Permission.notification,
    ].request();
    await _initVoice();
    _startScan();
  }

  // ============================================================
  //  PERSISTENCE
  // ============================================================
  Future<void> _loadPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      schedOn = p.getBool('sched_on') ?? false;
      drainSecs = (p.getInt('drain_secs') ?? kMaxDrainSecs).clamp(5, kMaxDrainSecs);
      final ts = p.getStringList('sched_times') ?? [];
      schedTimes = ts.map((s) {
        final parts = s.split(':');
        return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
      }).toList();
      _sortTimes();
      final lg = p.getString('drain_log');
      if (lg != null) {
        log = (jsonDecode(lg) as List).cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('sched_on', schedOn);
      await p.setInt('drain_secs', drainSecs);
      await p.setStringList('sched_times',
        schedTimes.map((t) => '${t.hour}:${t.minute}').toList());
      await p.setString('drain_log', jsonEncode(log));
    } catch (_) {}
  }

  void _sortTimes() {
    schedTimes.sort((a, b) => (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute));
  }

  void logEvent(String source, int secs) {
    log.insert(0, {'t': DateTime.now().toIso8601String(), 's': source, 'd': secs});
    if (log.length > 200) log.removeRange(200, log.length);
    savePrefs();
    if (mounted) setState(() {});
  }

  // ============================================================
  //  SCHEDULE ENGINE (app-side: only fires while app is open
  //  and connected — firmware-side version planned post-PCB)
  // ============================================================
  DateTime? nextOccurrence() {
    if (!schedOn || schedTimes.isEmpty) return null;
    final now = DateTime.now();
    DateTime? best;
    for (final t in schedTimes) {
      var d = DateTime(now.year, now.month, now.day, t.hour, t.minute);
      if (!d.isAfter(now)) d = d.add(const Duration(days: 1));
      if (_skipBefore != null && !d.isAfter(_skipBefore!)) {
        d = d.add(const Duration(days: 1));
      }
      if (best == null || d.isBefore(best)) best = d;
    }
    return best;
  }

  void skipNext() {
    final n = nextOccurrence();
    if (n == null) return;
    _skipBefore = n;
    if (_pending != null) { _pending = null; _pendingCancelled = false; }
    logEvent('skipped', 0);
  }

  void _schedTick() {
    if (_shuttingDown) return;
    final next = nextOccurrence();
    if (next == null) {
      if (_pending != null && mounted) setState(() => _pending = null);
      return;
    }
    final secs = next.difference(DateTime.now()).inSeconds;
    if (_pending == null || _pending != next) {
      if (secs <= kPreDrainWarnSecs && secs > 0) {
        _pending = next;
        _pendingCancelled = false;
        _preSecs = secs;
        _notify(1, 'GoFlowX', 'Scheduled drain in 1 minute. Open the app to cancel.');
        if (mounted) setState(() {});
      }
      return;
    }
    _preSecs = secs.clamp(0, kPreDrainWarnSecs);
    if (secs <= 0) {
      final fired = _pending!;
      _pending = null;
      _skipBefore = fired; // consume this occurrence
      if (_pendingCancelled) {
        logEvent('cancelled', 0);
      } else {
        _fireScheduledDrain();
      }
      savePrefs();
    }
    if (mounted) setState(() {});
  }

  void cancelPending() {
    _pendingCancelled = true;
    if (mounted) setState(() {});
  }

  void _fireScheduledDrain() {
    if (_conn != Conn.ready) {
      logEvent('missed', 0);
      _notify(2, 'GoFlowX', 'Scheduled drain skipped — device not connected.');
      return;
    }
    if (_battPct != null && _battPct! <= kBattCriticalPct) {
      logEvent('missed', 0);
      _notify(2, 'GoFlowX', 'Scheduled drain skipped — battery critical.');
      return;
    }
    _notify(3, 'GoFlowX', 'Scheduled drain started.');
    _schedLatched = true;
    _drainRemaining = drainSecs;
    _drainTimer?.cancel();
    _drainTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _drainRemaining--;
      if (_drainRemaining <= 0) {
        t.cancel();
        _endScheduledDrain();
      } else if (mounted) {
        setState(() {});
      }
    });
    _applyOpen();
  }

  void _endScheduledDrain() {
    if (!_schedLatched) return;
    _schedLatched = false;
    _drainTimer?.cancel();
    _drainTimer = null;
    logEvent('scheduled', drainSecs);
    _applyOpen();
  }

  // ============================================================
  //  DEMO
  // ============================================================
  void _startDemo() {
    _setConn(Conn.ready);
    _battPct = 87;
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

  // ============================================================
  //  BLE
  // ============================================================
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
        if (svc.uuid == kSvcUuid) {
          for (final c in svc.characteristics) {
            if (c.uuid == kCmdUuid) _cmd = c;
            if (c.uuid == kStateUuid) _state = c;
          }
        }
        if (svc.uuid == kBattSvcUuid) {
          for (final c in svc.characteristics) {
            if (c.uuid == kBattChrUuid) _batt = c;
          }
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

      // ---- Battery Service (0x180F / 0x2A19) ----
      if (_batt != null) {
        try {
          final v = await _batt!.read();
          if (v.isNotEmpty) _onBattery(v[0]);
          await _batt!.setNotifyValue(true);
          _battSub = _batt!.onValueReceived.listen((v) {
            if (v.isNotEmpty) _onBattery(v[0]);
          });
          device.cancelWhenDisconnected(_battSub!);
        } catch (_) {}
      }
      _setConn(Conn.ready);
    } catch (_) {
      _setConn(Conn.disconnected);
    }
  }

  Future<void> _teardownConnection() async {
    _holding = false;
    _voiceLatched = false;
    _schedLatched = false;
    _cmdTimer?.cancel(); _cmdTimer = null;
    _voiceTimer?.cancel(); _voiceTimer = null;
    _drainTimer?.cancel(); _drainTimer = null;
    await _stateSub?.cancel();
    await _battSub?.cancel();
    await _connSub?.cancel();
    try { await _device?.disconnect(); } catch (_) {}
    _cmd = null; _state = null; _batt = null; _device = null;
    _battPct = null;
  }

  // ============================================================
  //  BATTERY HANDLING
  // ============================================================
  void _onBattery(int p) {
    if (mounted) setState(() => _battPct = p);
    if (_shuttingDown) return;
    if (p <= kBattCriticalPct) {
      _criticalShutdown(p);
    } else if (p <= kBattWarnPct && !_battWarned) {
      _battWarned = true;
      _notify(4, 'GoFlowX', 'Device battery $p% — charge it soon.');
      if (mounted) {
        showDialog(context: context, builder: (_) => AlertDialog(
          backgroundColor: kInk2,
          title: const Text('Battery low', style: TextStyle(color: kAmber)),
          content: Text(
            'The GoFlowX device battery is at $p%.\n\nCharge it soon. '
            'At $kBattCriticalPct% the app will close and the device will '
            'reserve the rest so it can always close the valve on its own.',
            style: const TextStyle(color: kMuted, height: 1.5)),
          actions: [TextButton(onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: kCyan)))],
        ));
      }
    } else if (p > kBattWarnPct) {
      _battWarned = false; // recharged: re-arm the warning
    }
  }

  void _criticalShutdown(int p) {
    if (_shuttingDown) return;
    _shuttingDown = true;
    _holding = false;
    _voiceLatched = false;
    _schedLatched = false;
    _applyOpen();          // close the valve now
    _notify(5, 'GoFlowX', 'Battery critical ($p%). Charge the device now. '
      'The remaining charge is reserved so the valve can always close safely.');
    if (mounted) {
      showDialog(context: context, barrierDismissible: false, builder: (_) => AlertDialog(
        backgroundColor: kInk2,
        title: const Text('Battery critical', style: TextStyle(color: kRed)),
        content: Text(
          'Device battery is at $p%.\n\nThe app will close. The remaining '
          'charge is kept so the valve can always close safely. '
          'Charge the device now.',
          style: const TextStyle(color: kMuted, height: 1.5)),
        actions: [TextButton(onPressed: _closeApp,
          child: const Text('Close now', style: TextStyle(color: kRed)))],
      ));
    }
    _shutdownTimer = Timer(const Duration(seconds: 10), _closeApp);
  }

  // ============================================================
  //  VALVE COMMANDS
  // ============================================================
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
    if (_conn != Conn.ready || _shuttingDown) return;
    if (_battPct != null && _battPct! <= kBattCriticalPct) return;
    _holding = true;
    _holdStart = DateTime.now();
    _applyOpen();
  }
  void _endHold() {
    if (!_holding) return;
    _holding = false;
    if (_holdStart != null) {
      final s = DateTime.now().difference(_holdStart!).inSeconds;
      logEvent('manual', s < 1 ? 1 : s);
      _holdStart = null;
    }
    _applyOpen();
  }

  void _voiceOpen() {
    if (_shuttingDown) return;
    if (_battPct != null && _battPct! <= kBattCriticalPct) return;
    _voiceLatched = true;
    _voiceStart = DateTime.now();
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
    final was = _voiceLatched;
    _voiceLatched = false;
    _voiceTimer?.cancel();
    _voiceTimer = null;
    _voiceRemaining = 0;
    if (was && _voiceStart != null) {
      final s = DateTime.now().difference(_voiceStart!).inSeconds;
      logEvent('voice', s < 1 ? 1 : s);
      _voiceStart = null;
    }
    _applyOpen();
  }

  // ============================================================
  //  VOICE
  // ============================================================
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
    _schedTicker?.cancel();
    _drainTimer?.cancel();
    _shutdownTimer?.cancel();
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

  // ---- helpers ----
  String fmt12(TimeOfDay t) {
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.period == DayPeriod.am ? 'AM' : 'PM'}';
  }

  String _fmtIn(Duration d) {
    if (d.inHours >= 1) return '${d.inHours} h ${d.inMinutes % 60} m';
    if (d.inMinutes >= 1) return '${d.inMinutes} m';
    return '${d.inSeconds} s';
  }

  // ---- menu actions ----
  void _openConnect() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ConnectScreen(status: _connN, onSearch: _userSearch),
    ));
  }
  void _openSchedule() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ScheduleScreen(home: this),
    ));
  }
  void _openLog() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LogScreen(home: this),
    ));
  }
  void _closeApp() {
    _holding = false;
    _voiceLatched = false;
    _schedLatched = false;
    _voiceOn = false;
    _applyOpen();
    _speech.stop();
    SystemNavigator.pop();
  }
  void _showHelp() {
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: kInk2,
      title: const Text('How to use', style: TextStyle(color: Colors.white)),
      content: const Text(
        '• Hold the circle to open the valve; release to close.\n'
        '• Or just say “open” and “close”.\n'
        '• Say “exit” (or “quit”) to close the app.\n'
        '• It always closes after 30 seconds for safety.\n'
        '• Schedule (menu) drains at set times — the app warns you '
        '60 seconds before each drain so you can cancel.\n'
        '• Scheduled drains only run while the app is open and connected.\n\n'
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
      applicationVersion: '2.1.0',
      applicationIcon: Image.asset('logo.png', height: 30),
      children: const [Text('Smart, app-controlled flow management in one device.')],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = _conn == Conn.ready;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.of(context).size.height -
                MediaQuery.of(context).padding.vertical),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _topBarAndLogo(),
                  if (_pending != null && !_pendingCancelled) _preDrainBanner(),
                  if (schedTimes.isNotEmpty) _nextDrainCard(),
                  _statusBlock(),
                  const SizedBox(height: 10),
                  _holdButton(ready),
                  const SizedBox(height: 10),
                  _voicePanel(),
                  _footer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBarAndLogo() {
    final ready = _conn == Conn.ready;
    final p = _battPct;
    Color battColor;
    IconData battIcon;
    if (p == null) { battColor = kMuted; battIcon = Icons.battery_unknown; }
    else if (p <= kBattCriticalPct) { battColor = kRed; battIcon = Icons.battery_alert; }
    else if (p <= kBattWarnPct) { battColor = kAmber; battIcon = Icons.battery_2_bar; }
    else if (p <= 50) { battColor = kMint; battIcon = Icons.battery_4_bar; }
    else { battColor = kMint; battIcon = Icons.battery_full; }
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: [
          Icon(battIcon, color: battColor, size: 26),
          const SizedBox(width: 5),
          Text(p == null ? '--%' : '$p%',
            style: TextStyle(color: battColor, fontSize: 17, fontWeight: FontWeight.w700)),
        ]),
        PopupMenuButton<String>(
          icon: const Icon(Icons.menu, color: kMuted),
          color: kInk2,
          onSelected: (v) {
            if (v == 'connect') _openConnect();
            else if (v == 'schedule') _openSchedule();
            else if (v == 'log') _openLog();
            else if (v == 'help') _showHelp();
            else if (v == 'about') _showAbout();
            else if (v == 'exit') _closeApp();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'connect', child: Text('Connect', style: TextStyle(color: Colors.white))),
            PopupMenuItem(value: 'schedule', child: Text('Schedule', style: TextStyle(color: Colors.white))),
            PopupMenuItem(value: 'log', child: Text('Drain log', style: TextStyle(color: Colors.white))),
            PopupMenuItem(value: 'help', child: Text('Help', style: TextStyle(color: Colors.white))),
            PopupMenuItem(value: 'about', child: Text('About', style: TextStyle(color: Colors.white))),
            PopupMenuItem(value: 'exit', child: Text('Close app', style: TextStyle(color: kRed))),
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

  Widget _preDrainBanner() {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: kAmber.withOpacity(.12),
        border: Border.all(color: kAmber.withOpacity(.5)),
        borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Icon(Icons.warning_amber_rounded, color: kAmber, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text('Scheduled drain in $_preSecs s',
          style: const TextStyle(color: kAmber, fontSize: 13, fontWeight: FontWeight.w700))),
        TextButton(onPressed: cancelPending,
          child: const Text('Cancel', style: TextStyle(color: kRed, fontWeight: FontWeight.w700))),
      ]),
    );
  }

  Widget _nextDrainCard() {
    final next = nextOccurrence();
    final now = DateTime.now();
    return GestureDetector(
      onTap: _openSchedule,
      child: Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: kInk2,
          border: Border.all(color: kCyan.withOpacity(.35)),
          borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('NEXT DRAIN',
              style: TextStyle(fontSize: 10, letterSpacing: 1, color: kMuted)),
            const SizedBox(height: 2),
            Text(
              !schedOn ? 'Schedule off'
                : next == null ? '—'
                : '${fmt12(TimeOfDay.fromDateTime(next))} · in ${_fmtIn(next.difference(now))}',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                color: schedOn ? kCyan : kMuted)),
            if (schedOn && next != null)
              GestureDetector(onTap: skipNext,
                child: const Padding(padding: EdgeInsets.only(top: 3),
                  child: Text('Skip next',
                    style: TextStyle(fontSize: 11, color: kMint,
                      decoration: TextDecoration.underline, decorationColor: kMint)))),
          ])),
          Switch(
            value: schedOn,
            activeColor: kCyan,
            inactiveThumbColor: kMuted,
            onChanged: (v) { setState(() => schedOn = v); savePrefs(); },
          ),
        ]),
      ),
    );
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
      if (_schedLatched)
        Padding(padding: const EdgeInsets.only(top: 8),
          child: Text('Scheduled drain — closing in $_drainRemaining s',
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
//  SCHEDULE SCREEN
// =====================================================================
class ScheduleScreen extends StatefulWidget {
  final ControlScreenState home;
  const ScheduleScreen({super.key, required this.home});
  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  ControlScreenState get h => widget.home;

  Future<void> _addTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 8, minute: 0),
    );
    if (t == null) return;
    final exists = h.schedTimes.any((x) => x.hour == t.hour && x.minute == t.minute);
    if (!exists) {
      h.schedTimes.add(t);
      h.schedTimes.sort((a, b) => (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute));
      h.savePrefs();
    }
    setState(() {});
  }

  void _removeTime(TimeOfDay t) {
    h.schedTimes.removeWhere((x) => x.hour == t.hour && x.minute == t.minute);
    h.savePrefs();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final next = h.nextOccurrence();
    return Scaffold(
      backgroundColor: kInk,
      appBar: AppBar(
        backgroundColor: kInk, elevation: 0, foregroundColor: Colors.white,
        title: const Text('Schedule'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(color: kInk2, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
                  SizedBox(height: 8),
                  Text('Scheduled drainage', style: TextStyle(color: Colors.white, fontSize: 14)),
                  SizedBox(height: 2),
                  Text('Drains at set times while the app is open and connected',
                    style: TextStyle(color: kMuted, fontSize: 11)),
                  SizedBox(height: 8),
                ])),
                Switch(
                  value: h.schedOn,
                  activeColor: kCyan,
                  inactiveThumbColor: kMuted,
                  onChanged: (v) { h.schedOn = v; h.savePrefs(); setState(() {}); },
                ),
              ]),
            ),
            const SizedBox(height: 18),
            const Text('DRAIN TIMES', style: TextStyle(fontSize: 11, letterSpacing: 1, color: kMuted)),
            const SizedBox(height: 8),
            if (h.schedTimes.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 10),
                child: Text('No times yet. Add your first drain time below.',
                  style: TextStyle(color: kMuted, fontSize: 13))),
            Container(
              decoration: BoxDecoration(color: kInk2, borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                for (final t in h.schedTimes)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(children: [
                      Expanded(child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        child: Text(
                          next != null &&
                            next.hour == t.hour && next.minute == t.minute && h.schedOn
                            ? '${h.fmt12(t)} · next' : h.fmt12(t),
                          style: TextStyle(fontSize: 14,
                            color: next != null && next.hour == t.hour &&
                                   next.minute == t.minute && h.schedOn
                              ? kCyan : Colors.white)))),
                      IconButton(
                        icon: const Icon(Icons.close, color: kMuted, size: 18),
                        onPressed: () => _removeTime(t)),
                    ]),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
            Center(child: TextButton.icon(
              onPressed: _addTime,
              icon: const Icon(Icons.add, color: kCyan, size: 18),
              label: const Text('Add time', style: TextStyle(color: kCyan)))),
            const SizedBox(height: 14),
            const Text('DRAIN DURATION', style: TextStyle(fontSize: 11, letterSpacing: 1, color: kMuted)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: kInk2, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Expanded(child: Text('${h.drainSecs} seconds',
                  style: const TextStyle(color: Colors.white, fontSize: 14))),
                DropdownButton<int>(
                  value: h.drainSecs,
                  dropdownColor: kInk2,
                  underline: const SizedBox.shrink(),
                  items: const [10, 15, 20, 30].map((s) => DropdownMenuItem(
                    value: s,
                    child: Text('$s s', style: const TextStyle(color: kCyan)))).toList(),
                  onChanged: (v) { if (v != null) { h.drainSecs = v; h.savePrefs(); setState(() {}); } },
                ),
                const SizedBox(width: 6),
                const Text('max 30 s', style: TextStyle(color: kMuted, fontSize: 11)),
              ]),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: kAmber.withOpacity(.12),
                border: Border.all(color: kAmber.withOpacity(.4)),
                borderRadius: BorderRadius.circular(12)),
              child: const Text(
                'The app warns you 60 seconds before each drain — tap Cancel to skip it. '
                'Drains are skipped automatically if the device is not connected or the '
                'battery is critical. Every drain still auto-closes at 30 seconds.',
                style: TextStyle(color: kAmber, fontSize: 12, height: 1.5)),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
//  DRAIN LOG SCREEN
// =====================================================================
class LogScreen extends StatelessWidget {
  final ControlScreenState home;
  const LogScreen({super.key, required this.home});

  String _label(String s) {
    switch (s) {
      case 'manual': return 'Manual (hold)';
      case 'voice': return 'Voice';
      case 'scheduled': return 'Scheduled';
      case 'missed': return 'Missed — not connected';
      case 'skipped': return 'Skipped by you';
      case 'cancelled': return 'Cancelled by you';
      default: return s;
    }
  }

  Color _color(String s) {
    switch (s) {
      case 'missed': return kRed;
      case 'skipped':
      case 'cancelled': return kAmber;
      default: return kMint;
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = home.log;
    return Scaffold(
      backgroundColor: kInk,
      appBar: AppBar(
        backgroundColor: kInk, elevation: 0, foregroundColor: Colors.white,
        title: const Text('Drain log'),
      ),
      body: SafeArea(
        child: entries.isEmpty
          ? const Center(child: Text('No drains recorded yet.',
              style: TextStyle(color: kMuted, fontSize: 13)))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              itemCount: entries.length,
              separatorBuilder: (_, __) => const Divider(color: Color(0xFF0A3742), height: 1),
              itemBuilder: (_, i) {
                final e = entries[i];
                final t = DateTime.tryParse(e['t'] ?? '') ?? DateTime.now();
                final src = (e['s'] ?? '') as String;
                final d = (e['d'] ?? 0) as int;
                final hh = t.hour % 12 == 0 ? 12 : t.hour % 12;
                final mm = t.minute.toString().padLeft(2, '0');
                final ap = t.hour < 12 ? 'AM' : 'PM';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(children: [
                    Container(width: 8, height: 8,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: _color(src))),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_label(src), style: const TextStyle(color: Colors.white, fontSize: 13)),
                      Text('${t.day}/${t.month}/${t.year} · $hh:$mm $ap',
                        style: const TextStyle(color: kMuted, fontSize: 11)),
                    ])),
                    if (d > 0)
                      Text('$d s', style: const TextStyle(color: kMint, fontSize: 13)),
                  ]),
                );
              },
            ),
      ),
    );
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
            _step(2, 'Make sure your phone’s Bluetooth is switched on.'),
            _step(3, 'Tap “Search for device” below.'),
            _step(4, 'It finds “GoFlowX” and connects on its own. A green dot means ready.'),
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
