import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:dartssh2/dartssh2.dart';
import 'tunnel_crypto.dart';
import '../config.dart';
import '../l10n.dart';
import 'pairing_service.dart';

/// RemoteTerminal — most apka↔BE(/v1/term)↔node.
/// Owner-auth podpisem portfela; otwiera tunel TCP na nodzie (np. 192.168.1.1:22) i wystawia
/// [SSHSocket] dla dartssh2. Node to głupia rura — cała krypto SSH jest tu (E2E), BE/node nie
/// widzą haseł SSH. Jeden WS na żywotność ekranu: connect() → openTunnel().
class TerminalRelay {
  final String deviceId;
  final String owner;
  final Future<String> Function(String message) signMessage;

  /// Token ownera (`smt_…`) — jeśli jest, uwierzytelniamy się nim zamiast świeżego podpisu,
  /// dzięki czemu portfel może zostać zamknięty. Gdy BE go odrzuci (odwołany/wygasł), relay
  /// sam wraca do podpisu na tym samym sockecie i zgłasza to przez [onTokenRejected].
  final String? ownerToken;

  /// Wołane, gdy BE odrzucił token — ekran ma go zapomnieć, żeby przy następnym wejściu
  /// apka wyrobiła nowy.
  final void Function()? onTokenRejected;
  /// Klucz parowania tego noda (32 B). Bez niego node ODMÓWI otwarcia tunelu — backend nie
  /// potrafi go wytworzyć, i o to właśnie chodzi.
  /// NIE final: user może sparować node już po otwarciu ekranu, a wtedy nie chcemy przebudowywać
  /// całego relaya (żywy WS + uwierzytelnienie) tylko po to, żeby wstrzyknąć klucz.
  Uint8List? pairKey;

  /// Wersja firmware noda — BE podaje ją w odpowiedzi `auth`, prosto z bazy. Tunel v2 umie
  /// dopiero FW ≥1.01; starszemu nodowi NIE wolno wysłać zaszyfrowanej ramki, bo jego
  /// `ws_enc_open` nie zna koperty 0x02 i node rozłączyłby WS przy każdej próbie.
  String nodeFw = '';

  WebSocketChannel? _ch;
  _RelaySocket? _sock;
  bool _authed = false;
  bool nodeOnline = false;
  bool remoteEnabled = false;

  final _events = StreamController<String>.broadcast(); // "state:<st>:<msg>" / "error:<msg>"
  Stream<String> get events => _events.stream;
  StreamSubscription? _sub;
  void _emit(String s) { if (!_events.isClosed) _events.add(s); }

  Completer<void>? _auth;
  Completer<SSHSocket>? _open;
  TunnelCrypto? _crypto;   // ustawiane przy `open`, żyje tyle co sesja

  TerminalRelay({required this.deviceId, required this.owner, required this.signMessage,
                 this.ownerToken, this.onTokenRejected, this.pairKey});

  /// Czy node umie tunel v2 (FW ≥ 1.01). Porównujemy major.minor, sufiksy typu `-lora1`
  /// nie mają tu znaczenia.
  static bool fwSupportsV2(String fw) {
    final m = RegExp(r'^(\d+)\.(\d+)').firstMatch(fw.trim());
    if (m == null) return false;
    final major = int.parse(m.group(1)!), minor = int.parse(m.group(2)!);
    return major > 1 || (major == 1 && minor >= 1);
  }

  /// Czy bieżąca próba uwierzytelnienia poszła tokenem (do jednorazowego powrotu na podpis).
  bool _triedToken = false;

  String get _wsUrl => '${Config.beUrl.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://')}/v1/term';

  /// Połącz i uwierzytelnij jako właściciel noda. Rzuca przy odmowie/timeout.
  Future<void> connect() async {
    _auth = Completer<void>();
    _ch = WebSocketChannel.connect(Uri.parse(_wsUrl));
    _sub = _ch!.stream.listen(_onMessage,
        onError: (e) => _fail('connection error: $e'), onDone: () => _fail('connection closed'));
    // Token najpierw: nie dotyka portfela, więc wejście w tunel nie wymaga hasła.
    if (ownerToken != null && ownerToken!.isNotEmpty) {
      _triedToken = true;
      _send({'type': 'auth', 'device_id': deviceId, 'token': ownerToken});
    } else {
      await _authWithSignature();
    }
    await _auth!.future.timeout(const Duration(seconds: 12),
        onTimeout: () => throw Exception('auth timeout'));
  }

  /// Uwierzytelnienie świeżym podpisem portfela — droga pierwotna i zapas, gdy token padnie.
  Future<void> _authWithSignature() async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final sig = await signMessage('sensmos:term:$deviceId:$ts');
    _send({'type': 'auth', 'device_id': deviceId, 'owner': owner, 'ts': ts, 'sig': sig});
  }

  /// Otwórz tunel TCP do ip:port na LAN-ie noda; zwraca SSHSocket dla SSHClient.
  Future<SSHSocket> openTunnel(String ip, int port) async {
    if (!_authed) throw Exception('not authenticated');
    final key = pairKey;
    if (key == null) {
      throw Exception(tr('Node nie jest sparowany z tym telefonem — sparuj go, będąc w tej samej sieci WiFi.'));
    }
    if (!fwSupportsV2(nodeFw)) {
      throw Exception(tr('Node ma za stare oprogramowanie (%s) — zaktualizuj je do 1.01 lub nowszego.',
                         [nodeFw.isEmpty ? '?' : nodeFw]));
    }
    _open = Completer<SSHSocket>();
    // Dowód liczony TUTAJ i przepychany przez backend nietknięty. ip i port siedzą w środku
    // podpisywanego ciągu, więc przejęty serwer nie podmieni celu na inny adres w LAN-ie.
    // Ten sam `ts` wchodzi do AAD ramek, więc wiąże je z TĄ sesją.
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final proof = PairingService.proof(key, deviceId, ip, port, ts);
    _crypto = TunnelCrypto(key, ts);
    _send({'type': 'open', 'ip': ip, 'port': port, 'ts': ts, 'proof': proof, 'v': 2});
    return _open!.future.timeout(const Duration(seconds: 20),
        onTimeout: () => throw Exception('tunnel open timeout'));
  }

  // sink bywa zamknięty (dispose/rozłączenie), a dartssh2 przy zamykaniu dopina jeszcze
  // pakiet „disconnect" → add po close rzucał „Cannot add event after closing" i wywalał apkę
  void _send(Map<String, dynamic> m) { try { _ch?.sink.add(jsonEncode(m)); } catch (_) {} }
  void _sendBin(Uint8List b) { try { _ch?.sink.add(b); } catch (_) {} }

  void _onMessage(dynamic raw) {
    // Bajty tunelu przychodzą ramką BINARNĄ (v2). Sterowanie zostaje JSON-em.
    if (raw is! String) {
      final cr = _crypto;
      if (cr == null || _sock == null) return;
      try {
        _sock!.feed(cr.open(Uint8List.fromList(raw as List<int>)));
      } catch (e) {
        // Zły tag albo powtórzona porcja = ktoś majstrował przy strumieniu ALBO doszło do
        // rozjazdu. Cichy drop byłby gorszy: SSH i tak padnie na MAC, a panel HTTP dostanie
        // uciętą odpowiedź bez wyjaśnienia. Zrywamy z komunikatem.
        _fail('tunnel: ${tr('Ramka odrzucona — zerwane szyfrowanie tunelu.')}');
      }
      return;
    }
    Map<String, dynamic> m;
    try { m = jsonDecode(raw) as Map<String, dynamic>; } catch (_) { return; }
    switch (m['type']) {
      case 'auth':
        if (m['ok'] == true) {
          _authed = true;
          nodeOnline = m['online'] == true;
          remoteEnabled = m['remote'] == true;
          nodeFw = (m['fw'] ?? '').toString();
          if (_auth != null && !_auth!.isCompleted) _auth!.complete();
        } else {
          // Token odwołany/wygasły: kasujemy go i ponawiamy podpisem na TYM SAMYM sockecie —
          // BE przyjmuje ramkę auth w dowolnym momencie, więc user niczego nie zauważy poza
          // (ewentualnym) jednym pytaniem o hasło.
          if (_triedToken) {
            _triedToken = false;
            onTokenRejected?.call();
            _authWithSignature().catchError((e) => _fail('auth: $e'));
            return;
          }
          _fail('auth: ${m['error'] ?? 'denied'}');
        }
        break;
      case 'tun_state':
        final st = m['st'] ?? '';
        _emit('state:$st:${m['msg'] ?? ''}');
        if (st == 'open') {
          _sock = _RelaySocket(
            // chunk już ≤1024B (chunkowanie + paceowanie robi _RelaySocket._pumpOut) — node dekoduje
            // do bufora TUN_CHUNK=1024B; pace chroni przed przepełnieniem s_toLan przy długiej linii
            onSend: (chunk) => _sendBin(_crypto!.seal(Uint8List.fromList(chunk))),
            onClose: () => _send({'type': 'close'}),
          );
          if (_open != null && !_open!.isCompleted) _open!.complete(_sock!);
        } else if (st == 'closed' || st == 'error') {
          _crypto = null;
          // „node not paired" jest autorytatywne: node mówi, że nie ma ŻADNYCH kluczy —
          // reflash albo wymiana płytki z przywróconym ID. Lokalny klucz jest wtedy martwy
          // i trzymanie go blokowało parowanie na zawsze (apka uważała node za sparowany
          // i nigdy nie pokazywała dialogu). Kasujemy klucz/znacznik legacy, żeby następna
          // próba przeszła przez ensurePaired i zaproponowała parowanie od nowa.
          final notPaired = st == 'error' && '${m['msg'] ?? ''}'.contains('not paired');
          if (notPaired) PairingService().forget(deviceId);
          _sock?.remoteClosed();
          if (_open != null && !_open!.isCompleted) {
            _open!.completeError(Exception(notPaired
                ? tr('Node nie ma zapisanych kluczy (przeflashowany?) — sparuj go ponownie, będąc w jego sieci WiFi.')
                : 'tunnel $st: ${m['msg'] ?? ''}'));
          }
        }
        break;
    }
  }

  void _fail(String msg) {
    _emit('down:$msg');   // FATALNE: transport/auth padł (odróżnia od błędów pojedynczej operacji)
    if (_auth != null && !_auth!.isCompleted) _auth!.completeError(Exception(msg));
    if (_open != null && !_open!.isCompleted) _open!.completeError(Exception(msg));
  }

  void dispose() {
    try { _sub?.cancel(); } catch (_) {}   // NAJPIERW — inaczej onDone woła _fail po zamknięciu _events (crash)
    try { _sock?.destroy(); } catch (_) {}
    try { _ch?.sink.close(); } catch (_) {}
    if (!_events.isClosed) _events.close();
  }
}

/// SSHSocket na kanale relay: bajty SSH klienta → tun_data(app→LAN); tun_data(LAN→app) → strumień.
class _RelaySocket implements SSHSocket {
  final void Function(List<int> data) onSend;
  final void Function() onClose;
  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _done = Completer<void>();

  StreamSubscription? _outSub;
  final _outBuf = <int>[];
  bool _pumping = false, _closed = false;

  _RelaySocket({required this.onSend, required this.onClose}) {
    _outSub = _outgoing.stream.listen((data) { _outBuf.addAll(data); _pumpOut(); });
  }

  // Paceowanie app→LAN: dartssh2 zrzuca długą linię/paste jako kilka KB naraz. Node dekoduje do
  // bufora s_toLan (głęb. 6) i pisze do LAN — blast >6 chunków przepełnia go szybciej niż zdąży
  // zapisać → drop → SSH MAC fail → serwer wypisuje „Error" i rozłącza. Wysyłamy po 1024B z
  // mikro-oddechem, żeby node zdrenował do LAN między chunkami (małe wpisy i tak lecą od razu).
  Future<void> _pumpOut() async {
    if (_pumping) return;
    _pumping = true;
    while (_outBuf.isNotEmpty && !_closed) {
      final n = _outBuf.length < 1024 ? _outBuf.length : 1024;
      final chunk = Uint8List.fromList(_outBuf.sublist(0, n));
      _outBuf.removeRange(0, n);
      onSend(chunk);
      if (_outBuf.isNotEmpty) await Future.delayed(const Duration(milliseconds: 3));
    }
    _pumping = false;
  }

  void feed(Uint8List data) { if (!_incoming.isClosed) _incoming.add(data); }
  void remoteClosed() => _finish();

  @override
  Stream<Uint8List> get stream => _incoming.stream;
  @override
  StreamSink<List<int>> get sink => _outgoing.sink;
  @override
  Future<void> get done => _done.future;
  @override
  Future<void> close() { onClose(); _finish(); return _done.future; }
  @override
  void destroy() { onClose(); _finish(); }
  @override
  Future<void> flush() async {
    while ((_pumping || _outBuf.isNotEmpty) && !_closed) {
      await Future.delayed(const Duration(milliseconds: 3));
    }
  }

  void _finish() {
    _closed = true;      // zatrzymaj pompę pace
    _outSub?.cancel();   // stop pompowania wychodzących; NIE zamykamy _outgoing — dartssh2 przy teardown
    _outSub = null;      // bywa dopina jeszcze pakiet, a add-after-close = crash. Reszta idzie w próżnię.
    _outBuf.clear();
    if (!_incoming.isClosed) _incoming.close();
    if (!_done.isCompleted) _done.complete();
  }
}
