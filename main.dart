import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// ============================================================
//  DEMO MODE — set to true to test the app on ANY phone with NO
//  hardware (no PCB, no Bluetooth). The button works and the bar
//  animates exactly like the real thing. Set back to false when
//  your PCB is ready and you want to talk to the real device.
// ============================================================
const bool kDemoMode = true;

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
  Timer? _holdTimer;
  Timer? _demoTimer;

  int _stateByte = 0; // 0 closed,1 opening,2 open,3 closing
  int _pct = 0;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (kDemoMode) { _startDemo(); return; }
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    _startScan();
  }

  // Pretend a device is connected and integrate position locally.
  void _startDemo() {
    setState(() => _conn = Conn.ready);
    _demoTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      const step = 50 / 4000 * 100; // 4s full travel, matches STROKE_MS
      if (_holding && _pct < 100) _pct = (_pct + step).clamp(0, 100).round();
      if (!_holding && _pct > 0)  _pct = (_pct - step).clamp(0, 100).round();
      int s;
      if (_pct <= 0 && !_holding)      s = 0; // closed
      else if (_pct >= 100 && _holding) s = 2; // open
      else s = _holding ? 1 : 3;              // opening / closing
      if (mounted) setState(() => _stateByte = s);
    });
  }

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
    _endHold();
    await _stateSub?.cancel();
    await _connSub?.cancel();
    try { await _device?.disconnect(); } catch (_) {}
    _cmd = null; _state = null; _device = null;
  }

  // ---- hold-to-open: write 0x01 immediately, then every 400ms; 0x00 on release ----
  void _startHold() {
    if (kDemoMode) { setState(() => _holding = true); return; }
    if (_conn != Conn.ready || _cmd == null) return;
    setState(() => _holding = true);
    _sendCmd(0x01);
    _holdTimer?.cancel();
    _holdTimer = Timer.periodic(const Duration(milliseconds: 400), (_) => _sendCmd(0x01));
  }

  void _endHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    if (_holding) _sendCmd(0x00);
    if (mounted) setState(() => _holding = false);
  }

  void _sendCmd(int byte) {
    final c = _cmd;
    if (c == null) return;
    c.write([byte], withoutResponse: true).catchError((_) {});
  }

  @override
  void dispose() {
    _demoTimer?.cancel();
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
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _header(),
              _statusBlock(),
              _holdButton(ready),
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
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: .5, color: Colors.white),
          children: [TextSpan(text: 'GO'), TextSpan(text: 'FLOW', style: TextStyle(color: kCyan))],
        ),
      ),
      const SizedBox(height: 8),
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
      const SizedBox(height: 12),
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
    ]);
  }

  Widget _holdButton(bool ready) {
    final active = _holding;
    return GestureDetector(
      onTapDown: (_) => _startHold(),
      onTapUp: (_) => _endHold(),
      onTapCancel: _endHold,
      child: AnimatedScale(
        scale: active ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Container(
          width: 230, height: 230,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? kCyan : kInk2,
            border: Border.all(color: active ? Colors.white.withOpacity(.4) : kCyan.withOpacity(.35), width: 2),
          ),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('HOLD TO OPEN',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 1,
                  color: active ? const Color(0xFF03222A) : (ready ? const Color(0xFFCFE9EF) : kMuted))),
              const SizedBox(height: 6),
              Text(ready ? 'release to close' : 'connect first',
                style: TextStyle(fontSize: 12, color: active ? const Color(0xFF06363F) : kMuted)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _footer() {
    final disconnected = _conn == Conn.disconnected || _conn == Conn.idle;
    return Column(children: [
      const Text(
        'The valve stays closed unless you are holding the button. '
        'It closes automatically if you let go or move out of range.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: kMuted, height: 1.5),
      ),
      const SizedBox(height: 14),
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
