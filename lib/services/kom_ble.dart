import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n.dart';

/// Komunikator przez BLE (SPEC-komunikator-ble §2–§3): telefon jest ekranem i klawiaturą,
/// komunikator radiem i skrzynką. Jedna wiadomość JSON na jeden zapis i jedno powiadomienie.
class KomSaved {
  final String remoteId, id8, name;
  const KomSaved(this.remoteId, this.id8, this.name);
}

/// Odpowiedź `ok:false` (kod z pola `err`) albo `offline`, gdy łącze padło w trakcie.
class KomError implements Exception {
  final String code;
  const KomError(this.code);
  @override
  String toString() => 'KomError($code)';
}

String komErrText(Object e) => switch (e is KomError ? e.code : '') {
      'budget' => tr('Brak pasma radiowego, spróbuj za chwilę'),
      'radio' => tr('Radio komunikatora nie działa.'),
      'text' => tr('Wiadomość jest pusta, dłuższa niż 100 bajtów albo zawiera niedozwolone znaki.'),
      'name' => tr('Nazwa może mieć najwyżej 10 znaków.'),
      'pin' => tr('Zły PIN.'),
      'locked' => tr('Za dużo prób. Spróbuj ponownie za minutę.'),
      'auth' => tr('Podaj PIN komunikatora.'),
      final String c when c.isNotEmpty && c != 'offline' => tr('Komunikator odrzucił polecenie (%s).', [c]),
      _ => tr('Komunikator nie odpowiada.'),
    };

/// `pin` — podłączony, ale komunikator ma PIN, którego ten telefon jeszcze nie zna.
enum KomLink { idle, connecting, ready, lost, pin }

class KomBle {
  static final svcUuid = Guid('b7c1a000-6f2d-4e0a-9d3e-5a1c2b3d4e5f');
  static final _writeUuid = Guid('b7c1a001-6f2d-4e0a-9d3e-5a1c2b3d4e5f');
  static final _notifyUuid = Guid('b7c1a002-6f2d-4e0a-9d3e-5a1c2b3d4e5f');
  static const _kSaved = 'kom_ble_saved';
  static String _pinKey(String remoteId) => 'kom_pin_$remoteId';
  static const _retryS = [2, 5, 10, 30];

  final link = ValueNotifier(KomLink.idle);
  final saved = ValueNotifier<KomSaved?>(null);
  final info = ValueNotifier<Map<String, dynamic>?>(null);
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _write;
  StreamSubscription? _notifySub, _connSub;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _nextId = 1, _retryN = 0, _gen = 0;
  bool _opening = false;
  Timer? _retry;

  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_kSaved);
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        saved.value = KomSaved('${j['remoteId']}', '${j['id8']}', '${j['name'] ?? ''}');
      }
    } catch (_) {}
    if (saved.value != null) _reconnect();
  }

  Future<void> _save(KomSaved s) async {
    saved.value = s;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kSaved, jsonEncode({'remoteId': s.remoteId, 'id8': s.id8, 'name': s.name}));
    } catch (_) {}
  }

  /// Odłączenie: komunikator znika z apki razem z zapamiętanym PIN-em i bondem systemowym,
  /// który mogła zostawić 1.5.83 (parowanie Androida).
  Future<void> forget() async {
    final s = saved.value;
    saved.value = null;
    await _close();
    info.value = null;
    link.value = KomLink.idle;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kSaved);
      if (s != null) await p.remove(_pinKey(s.remoteId));
    } catch (_) {}
    if (s != null && Platform.isAndroid) {
      try { await BluetoothDevice.fromId(s.remoteId).removeBond(); } catch (_) {}
    }
  }

  Future<String?> _storedPin(String remoteId) async {
    try {
      return (await SharedPreferences.getInstance()).getString(_pinKey(remoteId));
    } catch (_) {
      return null;
    }
  }

  Future<void> _storePin(String pin) async {
    final id = saved.value?.remoteId ?? _device?.remoteId.str;
    if (id == null) return;
    try {
      final p = await SharedPreferences.getInstance();
      pin.isEmpty ? await p.remove(_pinKey(id)) : await p.setString(_pinKey(id), pin);
    } catch (_) {}
  }

  /// PIN wpisany na ekranie „PIN komunikatora” — po przyjęciu apka go zapamiętuje.
  Future<void> auth(String pin) async {
    await request('auth', {'pin': pin});
    await _storePin(pin);
    link.value = KomLink.ready;
  }

  /// Ustawienie, zmiana („6 cyfr”) albo usunięcie („”) PIN-u; ten telefon zapamiętuje nowy od razu.
  Future<void> setPin(String pin) async {
    await request('pin', {'pin': pin});
    await _storePin(pin);
    await refreshInfo();
  }

  // Komunikator z PIN-em: apka podaje zapamiętany sama; nieznany albo zły → ekran PIN-u.
  Future<bool> _autoAuth(String remoteId, Map<String, dynamic> i) async {
    if (i['pin_set'] != true) return true;
    final pin = await _storedPin(remoteId);
    if (pin == null) return false;
    try {
      await request('auth', {'pin': pin});
      return true;
    } on KomError catch (e) {
      if (e.code == 'offline') rethrow;
      return false;
    }
  }

  Future<bool> bluetoothOn() async {
    if (!await FlutterBluePlus.isSupported) return false;
    // iOS: pierwszy stan bywa `unknown`, zanim CoreBluetooth wstanie (albo trwa pytanie o zgodę).
    final s = await FlutterBluePlus.adapterState
        .firstWhere((v) => v != BluetoothAdapterState.unknown)
        .timeout(const Duration(seconds: 10), onTimeout: () => BluetoothAdapterState.unknown);
    if (s == BluetoothAdapterState.on) return true;
    try { await FlutterBluePlus.turnOn(); } catch (_) {}
    return await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on;
  }

  Stream<List<ScanResult>> scan({Duration timeout = const Duration(seconds: 12)}) {
    final ctrl = StreamController<List<ScanResult>>.broadcast();
    FlutterBluePlus.startScan(withServices: [svcUuid], timeout: timeout).catchError((_) {});
    final sub = FlutterBluePlus.scanResults.listen(ctrl.add);
    ctrl.onCancel = () { sub.cancel(); FlutterBluePlus.stopScan(); };
    return ctrl.stream;
  }

  /// Dodanie z listy skanu: podłączenie (bez parowania systemowego), `info` i zapamiętanie.
  Future<void> add(BluetoothDevice d) async {
    await _close();
    link.value = KomLink.connecting;
    try {
      await _connectTo(d);
    } catch (_) {
      link.value = KomLink.idle;
      rethrow;
    }
    final i = info.value!;
    await _save(KomSaved(d.remoteId.str, '${i['id8']}', '${i['name'] ?? ''}'));
  }

  Future<void> refreshInfo() async => _setInfo(await request('info'));

  Future<void> _setInfo(Map<String, dynamic> i) async {
    info.value = i;
    final s = saved.value;
    if (s != null && (s.id8 != '${i['id8']}' || s.name != '${i['name'] ?? ''}')) {
      await _save(KomSaved(s.remoteId, '${i['id8']}', '${i['name'] ?? ''}'));
    }
  }

  /// Cała skrzynka komunikatora — po 3 wpisy na odpowiedź, rosnąco po `seq`.
  Future<List<Map<String, dynamic>>> messages() async {
    final out = <Map<String, dynamic>>[];
    var after = 0;
    while (true) {
      final r = await request('msgs', {'after': after});
      final page = List<Map<String, dynamic>>.from(r['msgs'] ?? const []);
      out.addAll(page);
      if (r['more'] != true || page.isEmpty) return out;
      after = (page.last['seq'] as num).toInt();
    }
  }

  /// „W pobliżu” z komunikatora — stronicowane (`from`/`next`), żeby zmieścić się w 500 B.
  Future<List<Map<String, dynamic>>> near() async {
    final out = <Map<String, dynamic>>[];
    var from = 0;
    while (true) {
      final r = await request('near', {'from': from});
      out.addAll(List<Map<String, dynamic>>.from(r['near'] ?? const []));
      final next = (r['next'] as num?)?.toInt() ?? from;
      if (r['more'] != true || next <= from) return out;
      from = next;
    }
  }

  Future<Map<String, dynamic>> request(String cmd,
      [Map<String, dynamic> args = const {}, Duration timeout = const Duration(seconds: 8)]) async {
    final w = _write;
    if (w == null) throw const KomError('offline');
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    try {
      await w.write(utf8.encode(jsonEncode({'cmd': cmd, 'id': id, ...args})));
      final r = await c.future.timeout(timeout);
      if (r['ok'] != true) throw KomError('${r['err'] ?? '?'}');
      return r;
    } on TimeoutException {
      throw const KomError('offline');
    } finally {
      _pending.remove(id);
    }
  }

  // Próba sprzed forget()/add()/dispose() (inne _gen) nie może już ruszać bieżącego połączenia.
  void _live(int g) {
    if (g != _gen) throw const KomError('offline');
  }

  Future<void> _connectTo(BluetoothDevice d) async {
    final g = _gen;
    _opening = true;
    _device = d;
    try {
      await _open(d, g);
      final i = await request('info');
      _live(g);
      await _setInfo(i);
      final authed = await _autoAuth(d.remoteId.str, i);
      _live(g);
      _retryN = 0;
      link.value = authed ? KomLink.ready : KomLink.pin;
    } catch (_) {
      if (g == _gen) {
        await _close();
      } else if (_device != d) {
        try { await d.disconnect(); } catch (_) {}
      }
      rethrow;
    } finally {
      if (g == _gen) _opening = false;
    }
  }

  Future<void> _link(BluetoothDevice d, int g) async {
    Object? err;
    // Android bywa kapryśny przy pierwszej próbie GATT (133/62) — kilka podejść z przerwą.
    for (var i = 0; i < 3; i++) {
      _live(g);
      try {
        await d.connect(timeout: const Duration(seconds: 15), mtu: 512);
        return;
      } catch (e) {
        err = e;
        try { await d.disconnect(); } catch (_) {}
        await Future.delayed(Duration(milliseconds: 600 * (i + 1)));
      }
    }
    throw err!;
  }

  Future<void> _open(BluetoothDevice d, int g) async {
    await _link(d, g);
    _live(g);
    _connSub?.cancel();
    _connSub = d.connectionState.listen(_onConn);
    await _subscribe(d, g);
  }

  Future<void> _subscribe(BluetoothDevice d, int g) async {
    final svc = (await d.discoverServices()).where((s) => s.uuid == svcUuid).firstOrNull;
    BluetoothCharacteristic? w, n;
    for (final c in svc?.characteristics ?? const <BluetoothCharacteristic>[]) {
      if (c.uuid == _writeUuid) w = c;
      if (c.uuid == _notifyUuid) n = c;
    }
    if (w == null || n == null) throw Exception('kom: brak usługi');
    _notifySub?.cancel();
    _notifySub = n.onValueReceived.listen(_onValue);
    await n.setNotifyValue(true);
    _live(g);
    _write = w;
  }

  void _onValue(List<int> bytes) {
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (j['ev'] != null) {
      _events.add(j);
    } else {
      final c = _pending.remove(j['id']);
      if (c != null && !c.isCompleted) c.complete(j);
    }
  }

  void _failPending() {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(const KomError('offline'));
    }
    _pending.clear();
  }

  void _onConn(BluetoothConnectionState s) {
    if (s != BluetoothConnectionState.disconnected || _opening) return;
    _write = null;
    _failPending();
    if (saved.value == null) return;
    link.value = KomLink.lost;
    _schedule();
  }

  void _schedule() {
    _retry?.cancel();
    _retry = Timer(Duration(seconds: _retryS[_retryN.clamp(0, _retryS.length - 1)]), _reconnect);
    _retryN++;
  }

  Future<void> _reconnect() async {
    final s = saved.value;
    if (s == null || _opening || _write != null) return;
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      link.value = KomLink.lost;
      return _schedule();
    }
    link.value = KomLink.connecting;
    try {
      await _connectTo(BluetoothDevice.fromId(s.remoteId));
    } catch (e) {
      if (saved.value == null || _opening || _write != null) return;
      link.value = KomLink.lost;
      _schedule();
    }
  }

  Future<void> _close() async {
    _gen++;
    _opening = false;
    _retry?.cancel();
    await _connSub?.cancel();
    _connSub = null;
    await _notifySub?.cancel();
    _notifySub = null;
    _write = null;
    _failPending();
    final d = _device;
    _device = null;
    try { await d?.disconnect(); } catch (_) {}
  }

  void dispose() {
    _close();
    _events.close();
  }
}
