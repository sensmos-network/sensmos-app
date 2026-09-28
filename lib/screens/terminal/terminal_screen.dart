import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/wallet_service.dart';
import '../../services/terminal_relay.dart';
import '../../services/pairing_service.dart';
import '../../util/pair_gate.dart';
import '../../util/owner_token_gate.dart';
import '../../services/owner_token_service.dart';
import '../../services/integrations/integration_store.dart';
import '../../services/integrations/ssh_secrets.dart';

/// RemoteTerminal — zdalny terminal do LAN-u noda przez tunel. Node = głupia rura, SSH E2E w apce.
/// Bierze device_id + etykietę (NIE SavedNode) — działa też dla nodów widocznych tylko z BE
/// (bez lokalnego wpisu), bo tunel idzie przez relay, nie po lokalnej sieci.
// dartssh2 4 nie proponuje już SHA-1, CBC ani ssh-rsa. Terminal łączy się ze sprzętem w LAN-ie
// właściciela (stare routery, NAS, dropbear), który często nic innego nie umie — dokładamy je na KONIEC
// list, więc nowoczesny serwer dalej wynegocjuje mocne algorytmy, a stary nadal się połączy (jak w 2.14).
const _sshAlgorithms = SSHAlgorithms(
  kex: [
    SSHKexType.x25519Rfc, SSHKexType.x25519, SSHKexType.nistp521, SSHKexType.nistp384,
    SSHKexType.nistp256, SSHKexType.dhGexSha256, SSHKexType.dh14Sha256,
    SSHKexType.dh14Sha1, SSHKexType.dhGexSha1, SSHKexType.dh1Sha1,
  ],
  hostkey: [
    SSHHostkeyType.ed25519, SSHHostkeyType.rsaSha512, SSHHostkeyType.rsaSha256,
    SSHHostkeyType.ecdsa521, SSHHostkeyType.ecdsa384, SSHHostkeyType.ecdsa256,
    SSHHostkeyType.rsaSha1,
  ],
  cipher: [
    SSHCipherType.aes256gcm, SSHCipherType.aes128gcm, SSHCipherType.chacha20poly1305,
    SSHCipherType.aes256ctr, SSHCipherType.aes128ctr,
    SSHCipherType.aes128cbc, SSHCipherType.aes256cbc,
  ],
  mac: [
    SSHMacType.hmacSha256Etm, SSHMacType.hmacSha512Etm, SSHMacType.hmacSha256,
    SSHMacType.hmacSha512, SSHMacType.hmacSha1,
    SSHMacType.hmacSha256_96, SSHMacType.hmacSha512_96, SSHMacType.hmacMd5,
  ],
);

class TerminalScreen extends StatefulWidget {
  final String deviceId;
  final String label;
  /// Cel wybrany z listy zapisanych połączeń (albo null = pusty formularz).
  final SshHost? host;
  const TerminalScreen({super.key, required this.deviceId, required this.label, this.host});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

enum _Phase { connecting, form, session, error }

class _TerminalScreenState extends State<TerminalScreen> {
  _Phase _phase = _Phase.connecting;
  String _status = '';
  TerminalRelay? _relay;
  SSHClient? _ssh;
  SSHSession? _session;
  Timer? _resizeDebounce;
  int _rw = 0, _rh = 0;

  final _terminal = Terminal(maxLines: 10000);
  final _host = TextEditingController(text: '192.168.1.1');
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController(text: 'root');
  final _pass = TextEditingController();
  bool _paired = false;
  Uint8List? _pairKey;
  bool _savePass = false;
  bool _autoStart = false;          // wybrany cel ma komplet danych → wchodzimy prosto w sesję
  bool _showPass = false;

  // Zapamiętane pola formularza — PER NODE, bo każdy stoi w innej sieci i celujesz w co innego.
  // Hasło NIGDY nie idzie do SharedPreferences: to zwykły plik XML w katalogu apki. Ląduje
  // w tym samym szyfrowanym magazynie co klucze parowania i tylko za zgodą użytkownika.
  static const _formPrefix = 'term_form_';
  final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  void initState() {
    super.initState();
    // Kolejność ma znaczenie: dopiero po wczytaniu celu wiadomo, czy mamy hasło i można
    // wejść w sesję bez pokazywania formularza.
    _loadForm().then((_) { if (mounted) _connect(); });
  }

  Future<void> _loadForm() async {
    try {
      final p = await SharedPreferences.getInstance();
      final pre = widget.host;
      if (pre != null) {
        _host.text = pre.host; _port.text = '${pre.port}'; _user.text = pre.user;
        final pw = await _passFor(pre.slug);
        _pass.text = pw ?? '';
        _savePass = pw != null && pw.isNotEmpty;
        _autoStart = _savePass;   // bez hasła i tak trzeba by o nie zapytać
        if (mounted) setState(() {});
        return;   // cel z listy ma pierwszeństwo nad ostatnio używanym
      }
      final raw = p.getString('$_formPrefix${widget.deviceId}');
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        if (j['host'] is String) _host.text = j['host'] as String;
        if (j['port'] is String) _port.text = j['port'] as String;
        if (j['user'] is String) _user.text = j['user'] as String;
        _savePass = j['savePass'] == true;
      }
      if (_savePass) {
        _pass.text = await _passFor(_slugOf()) ?? '';
      }
      if (mounted) setState(() {});
    } catch (_) {/* brak zapamiętanych wartości to nie błąd — zostają domyślne */}
  }

  /// Zapis DOPIERO po udanym połączeniu. Zapisywanie przy każdej próbie utrwaliłoby literówki
  /// — np. domyślne 192.168.1.1, pod którym w Twojej sieci nic nie stoi — i apka podsuwałaby
  /// je przy każdym wejściu.
  Future<void> _saveForm() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('$_formPrefix${widget.deviceId}', jsonEncode({
        'host': _host.text.trim(),
        'port': _port.text.trim(),
        'user': _user.text.trim(),
        'savePass': _savePass,
      }));
      final k = _passKey(_slugOf());
      if (_savePass) {
        await _secure.write(key: k, value: _pass.text);
      } else {
        await _secure.delete(key: k);   // odznaczone = kasujemy też to, co zapisaliśmy wcześniej
      }
      // Cel trafia na listę dopiero po działającym połączeniu — z tego samego powodu, co reszta
      // tego zapisu: literówka nie ma prawa zostać zakładką.
      await IntegrationStore.rememberSshHost(widget.deviceId, SshHost(
        name: '', host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? 22, user: _user.text.trim(),
      ));
      if (mounted) setState(() {});
    } catch (_) {}
  }

  String _slugOf() => '${_host.text.trim()}:${_port.text.trim()}:${_user.text.trim()}';
  String _passKey(String slug) => SshSecrets.keyFor(widget.deviceId, slug);

  /// Hasło dla celu — wspólny magazyn z edytorem zapisanych połączeń.
  Future<String?> _passFor(String slug) => SshSecrets.read(widget.deviceId, slug);

  Future<void> _connect() async {
    _relay?.dispose(); _relay = null;   // retry: bez tego każda próba zostawia martwy WS + dubluje listener
    setState(() { _phase = _Phase.connecting; _status = tr('Łączę z relayem…'); });
    try {
      final wallet = await context.read<WalletService>().load();
      if (wallet == null) throw Exception(tr('Brak portfela w apce'));

      // Klucz MUSI być wczytany przed budową relaya — on go dostaje przez konstruktor
      // i bez niego openTunnel od razu odmówi. Brak klucza nie jest tu błędem: ekran
      // pokaże kartę „niesparowany" z przyciskiem parowania.
      final svc = PairingService();
      _pairKey = await svc.keyFor(widget.deviceId);
      _paired  = _pairKey != null;

      // Token ownera: pyta o hasło portfela najwyżej raz w życiu apki, potem tunel działa
      // przy zamkniętym portfelu (także z widgetu na pulpicie).
      if (!mounted) return;
      final token = await ensureOwnerToken(context, wallet.address, label: 'Ten telefon');
      if (!mounted) return;

      final relay = TerminalRelay(
        deviceId: widget.deviceId,
        owner: wallet.address,
        signMessage: (m) => context.read<WalletService>().signMessage(m),
        ownerToken: token,
        onTokenRejected: () => OwnerTokenService().forget(wallet.address),
        pairKey: _pairKey,
      );
      _relay = relay;                   // track wcześnie → dispose posprząta też gdy connect rzuci
      relay.events.listen(_onEvent);
      await relay.connect();
      if (!mounted) return;
      if (!relay.nodeOnline) {
        // node nie ma żywego połączenia z chmurą — bez niego tunel nie ruszy
        setState(() { _phase = _Phase.error; _status = tr('Node jest offline — nie połączysz się z nim, dopóki nie wróci do sieci.'); });
        return;
      }
      // Tylko PIERWSZE wejście idzie prosto w sesję. Gdy hasło okaże się złe, ekran wraca
      // do formularza z błędem — kolejna próba ma być świadoma, nie pętlą tego samego.
      if (_autoStart) { _autoStart = false; _startSession(); return; }
      setState(() { _phase = _Phase.form; _status = ''; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _phase = _Phase.error; _status = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  void _onEvent(String ev) {
    if (!mounted) return;
    // "down:<msg>" = transport/auth PADŁ (fatalne) → ekran błędu z „Spróbuj ponownie".
    // Bez tego sesyjny widok (sam TerminalView, brak paska statusu) wisi w miejscu i user
    // myśli, że apka zamarła — nie wie, że trzeba wyjść i wejść od nowa.
    if (ev.startsWith('down:')) {
      setState(() { _phase = _Phase.error; _status = tr('Połączenie zerwane — dotknij „Spróbuj ponownie".'); });
    } else if (ev.startsWith('error:')) {
      setState(() => _status = ev.substring(6));
    } else if (ev.startsWith('state:')) {
      final parts = ev.split(':');
      final st = parts.length > 1 ? parts[1] : '';
      if (st == 'error' || st == 'closed') {
        setState(() => _status = parts.length > 2 && parts[2].isNotEmpty ? parts[2] : 'tunnel $st');
      }
    }
  }

  /// Parowanie: klucz trafia do noda po LAN, z pominięciem naszego serwera. Dopiero on
  /// uprawnia do otwarcia tunelu — backend sam z siebie tego nie zrobi.
  Future<void> _doPair() async {
    final acc = await ensurePaired(context, widget.deviceId);
    if (!mounted) return;
    // Żywy relay musi dostać dostęp, inaczej openTunnel dalej odmawia.
    _relay?.pairKey = acc.key;
    setState(() {
      _pairKey = acc.key;
      _paired  = acc.ok;
      if (acc.ok) _status = tr('Node sparowany — możesz się połączyć.');
    });
  }

  Future<void> _startSession() async {
    final relay = _relay;
    if (relay == null) return;
    final ip = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 22;
    if (ip.isEmpty) return;
    setState(() { _phase = _Phase.connecting; _status = tr('Otwieram tunel → %s:%s…', [ip, port]); });
    try {
      final socket = await relay.openTunnel(ip, port);
      final ssh = SSHClient(
        socket,
        username: _user.text.trim().isEmpty ? 'root' : _user.text.trim(),
        onPasswordRequest: () => _pass.text,
        algorithms: _sshAlgorithms,
      );
      _ssh = ssh;
      final session = await ssh.shell(
        pty: SSHPtyConfig(width: _terminal.viewWidth, height: _terminal.viewHeight),
      );
      _session = session;
      _saveForm();   // fire-and-forget: połączenie działa, więc te wartości warto zapamiętać
      _terminal.onOutput = (data) => session.write(utf8.encode(data));
      // Dynamiczny resize (htop skaluje się do ekranu). Debounce 300ms — chowanie klawiatury sypie
      // serią resize, wysyłamy tylko końcowy (jeden SIGWINCH zamiast lawiny).
      _terminal.onResize = (w, h, pw, ph) {
        if (w <= 0 || h <= 0) return;
        _rw = w; _rh = h;
        _resizeDebounce?.cancel();
        _resizeDebounce = Timer(const Duration(milliseconds: 300),
            () { try { _session?.resizeTerminal(_rw, _rh); } catch (_) {} });
      };
      session.stdout.listen((d) => _terminal.write(utf8.decode(d, allowMalformed: true)));
      session.stderr.listen((d) => _terminal.write(utf8.decode(d, allowMalformed: true)));
      session.done.then((_) {
        if (mounted && _phase == _Phase.session) {
          setState(() { _status = tr('Sesja zakończona'); _phase = _Phase.form; });
        }
      });
      if (!mounted) return;
      setState(() { _phase = _Phase.session; _status = ''; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _phase = _Phase.form; _status = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  @override
  void dispose() {
    _resizeDebounce?.cancel();
    try { _ssh?.close(); } catch (_) {}
    _relay?.dispose();
    _host.dispose(); _port.dispose(); _user.dispose(); _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // JEDNA zasada w całej apce: „<plugin> · <alias noda albo jego id>". Nazwa celu jest
    // w treści ekranu, nie w belce — inaczej każdy ekran miał inny format tytułu.
    final title = widget.label;
    // JEDEN sposób wyjścia: BACK. Zamyka sesję SSH, tunel na nodzie i relay (patrz dispose),
    // więc firmware oddaje ~27 kB heapu — potrzebne monitorom. Osobny przycisk „Rozłącz"
    // wyglądał identycznie, a zostawiał tunel zamknięty, ale ekran i WS żywe; przy dwóch
    // kontrolkach od tego samego lepiej zostawić tę, którą użytkownik i tak zna.
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: Text('${tr('Terminal')} · $title')),
      body: switch (_phase) {
        _Phase.connecting => _center(const CircularProgressIndicator(color: AppTheme.teal)),
        _Phase.error => _errorView(),
        _Phase.form => _formView(),
        _Phase.session => _sessionView(),
      },
    );
  }

  Widget _center(Widget w) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          w,
          if (_status.isNotEmpty) Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(_status, style: const TextStyle(color: AppTheme.muted)),
          ),
        ]),
      );

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: AppTheme.amber, size: 40),
            const SizedBox(height: 12),
            Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.text)),
            const SizedBox(height: 20),
            FilledButton(onPressed: _connect, child: Text(tr('Spróbuj ponownie'))),
          ]),
        ),
      );

  Widget _formView() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Tylko gdy czegoś brakuje. Potwierdzanie „sparowany" przy każdym wejściu to szum —
          // o wymogu user dowiaduje się przy dodawaniu integracji, tu zostaje sama droga wyjścia.
          if (!_paired) ...[
            Card(
              color: AppTheme.card,
              child: ListTile(
                leading: const Icon(Icons.vpn_key_outlined, color: AppTheme.amber),
                title: Text(tr('Node niesparowany'), style: const TextStyle(color: AppTheme.text)),
                subtitle: Text(
                  tr('Zdalny dostęp wymaga jednorazowego sparowania w tej samej sieci WiFi co node.'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                ),
                trailing: FilledButton(
                  onPressed: _doPair,
                  style: FilledButton.styleFrom(backgroundColor: AppTheme.teal, foregroundColor: Colors.black),
                  child: Text(tr('Sparuj')),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          _field(_host, tr('Host w sieci noda'), Icons.lan_outlined, hint: '192.168.1.1'),
          Row(children: [
            Expanded(flex: 2, child: _field(_port, tr('Port'), Icons.tag, keyboard: TextInputType.number)),
            const SizedBox(width: 10),
            Expanded(flex: 3, child: _field(_user, tr('Użytkownik SSH'), Icons.person_outline)),
          ]),
          _field(_pass, tr('Hasło SSH'), Icons.lock_outline, obscure: !_showPass, suffix: IconButton(
            icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility,
                color: AppTheme.muted, size: 20),
            onPressed: () => setState(() => _showPass = !_showPass),
          )),
          InkWell(
            onTap: () => setState(() => _savePass = !_savePass),
            child: Row(children: [
              Checkbox(
                value: _savePass,
                onChanged: (v) => setState(() => _savePass = v ?? false),
                activeColor: AppTheme.teal,
                checkColor: Colors.black,
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: Text(tr('Zapamiętaj hasło na tym telefonie'),
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12.5)),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          Text(
            tr('SSH jest szyfrowany end-to-end — node i nasze serwery przekazują tylko zaszyfrowane bajty.'),
            style: const TextStyle(color: AppTheme.muted, fontSize: 11.5),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _paired ? _startSession : null,
            icon: const Icon(Icons.terminal),
            label: Text(tr('Połącz')),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.teal, foregroundColor: Colors.black),
          ),
          if (!_paired) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(tr('Najpierw sparuj node powyżej.'),
                style: const TextStyle(color: AppTheme.amber, fontSize: 12)),
          ),
          if (_status.isNotEmpty) Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(_status, style: const TextStyle(color: AppTheme.muted, fontSize: 12.5)),
          ),
        ],
      );

  Widget _sessionView() => Container(
        color: const Color(0xFF05070B),
        child: SafeArea(
          child: TerminalView(
            _terminal,
            textStyle: const TerminalStyle(fontSize: 13, fontFamily: 'monospace'),
            padding: const EdgeInsets.all(8),
          ),
        ),
      );

  Widget _field(TextEditingController c, String label, IconData icon,
          {bool obscure = false, String? hint, TextInputType? keyboard, Widget? suffix}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: c,
          obscureText: obscure,
          keyboardType: keyboard,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(color: AppTheme.text),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            hintStyle: const TextStyle(color: AppTheme.muted),
            labelStyle: const TextStyle(color: AppTheme.muted),
            prefixIcon: Icon(icon, color: AppTheme.muted, size: 20),
            suffixIcon: suffix,
            filled: true,
            fillColor: AppTheme.card,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          ),
        ),
      );
}
