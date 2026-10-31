import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';
import '../../theme.dart';
import '../../config.dart';
import '../../core/core_bloc.dart';
import '../../services/wallet_service.dart';
import '../../core/core_event.dart';
import '../../services/ble_service.dart';
import '../../services/node_service.dart';
import '../../services/attest_service.dart';
import '../../services/pairing_service.dart';
import '../../l10n.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override State<SetupScreen> createState() => _SetupScreenState();
}

enum _Step { scan, form, connecting, done }

class _SetupScreenState extends State<SetupScreen> {
  _Step   _step     = _Step.scan;
  String? _error;
  String  _status   = '';
  bool    _scanning = false;
  final   _results  = <ScanResult>[];
  ScanResult? _selected;

  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _pinCtrl  = TextEditingController(text: '123456');
  String? _nodeIp;
  String  _authDeviceId = '';
  int     _countdown = 0;
  bool    _waitingReset = false;
  String? _resetReason;          // nagłówek ekranu odliczania — czemu rejestracja padła
  int     _doneCountdown = 3;

  // Odtwarzanie ID (FW ≥ 0.46): user wybiera z selektora offline'owy node swojego
  // walleta (lista z BE — działa też po reinstalacji apki) i ta płytka przejmuje jego
  // device_id. Tylko offline wg BE — nadpisanie ID żywego noda odcięłoby go od sieci
  // (zmiana pubkey → jego identify odrzucany).
  SavedNode? _restoreFrom;
  bool       _restoreId = false;                 // przełącznik „Odtwórz ID" (jak fuzz GPS)
  // Prywatność pozycji — ustawiana OD RAZU przy rejestracji, a nie dopiero w ustawieniach
  // noda. Kolejność ma znaczenie: kto nie chce być na mapie, nie powinien musieć się
  // na niej najpierw pojawić.
  bool       _gpsFuzz = true;
  bool       _ghost   = false;
  List<SavedNode> _restoreCandidates = [];       // TYLKO offline nody walleta (kandydaci do przejęcia ID)
  final Map<String, double?> _restoreAge = {};   // device_id → sekund od ostatniego pingu

  late final BleService _ble = context.read<BleService>();

  String _ageLabel(String id) {
    final s = _restoreAge[id];
    if (s == null)  return tr('offline');
    if (s < 3600)   return 'offline ${(s / 60).round()}m';
    if (s < 86400)  return 'offline ${(s / 3600).round()}h';
    return 'offline ${(s / 86400).round()}d';
  }

  // Kandydaci do odtworzenia = WSZYSTKIE fizyczne nody TEGO walleta wg BE (nie tylko lokalne
  // — działa po reinstalacji apki). NIE odsiewamy po czasie: świeżo sflashowany node ma stare
  // ID pingujące jeszcze sprzed chwili, więc filtr „>1h offline" chował właśnie ten przypadek.
  // Status pokazujemy w dropdownie, a przy wyborze ŻYWEGO ostrzegamy (import odetnie tamten node).
  Future<void> _loadRestoreCandidates() async {
    final ns = context.read<NodeService>();
    // Wallet z WalletService (źródło prawdy) — CoreBloc.state bywa pusty podczas onboardingu.
    final owner = (await context.read<WalletService>().load())?.address
        ?? context.read<CoreBloc>().state.wallet?.address;
    if (owner == null) return;
    final out = <SavedNode>[];
    try {
      final res = await http.get(
        Uri.parse('${Config.beUrl}/v1/nodes/by-owner/$owner'),
        headers: const {'X-App-Key': Config.appKey},
      ).timeout(const Duration(seconds: 8));
      final list = (jsonDecode(res.body) as Map<String,dynamic>)['nodes'] as List? ?? [];
      for (final raw in list) {
        final n = raw as Map<String,dynamic>;
        final id = n['device_id']?.toString() ?? '';
        if (id.length < 8) continue;
        if ((n['kind']?.toString() ?? 'real') != 'real') continue;   // virtualne nie są ESP
        // Postgres NUMERIC (EXTRACT EPOCH) przychodzi jako STRING → parsuj bezpiecznie
        final sp = n['seconds_since_ping'];
        final secs = sp == null ? null : double.tryParse(sp.toString());
        if (secs != null && secs < 300) continue;   // TYLKO offline (>5 min) — nie odcinamy żywego noda
        _restoreAge[id] = secs;
        final local = ns.nodes.where((x) => x.id == id).toList();
        out.add(local.isNotEmpty ? local.first
            : SavedNode(id: id, ip: '', pin: '', hostname: '',
                label: 'Node ${id.substring(0, 6)}'));
      }
      out.sort((a, b) => (_restoreAge[b.id] ?? 9e9).compareTo(_restoreAge[a.id] ?? 9e9)); // najdłużej offline pierwsze
    } catch (_) { /* BE niedostępny → box się nie pokaże */ }
    if (mounted) setState(() => _restoreCandidates = out);
  }

  @override
  void initState() { super.initState(); _startScan(); _loadRestoreCandidates(); }

  Future<void> _startScan() async {
    setState(() { _scanning = true; _error = null; _results.clear(); });
    if (!await _ble.isAvailable()) {
      await _ble.turnOn();
      if (!await _ble.isAvailable()) {
        setState(() { _error = tr('Włącz Bluetooth'); _scanning = false; }); return;
      }
    }
    _ble.scan(timeout: const Duration(seconds: 12)).listen(
      (r) { if (mounted) setState(() { _results..clear()..addAll(r); }); },
    );
    await Future.delayed(const Duration(seconds: 12));
    if (!mounted) return;
    setState(() => _scanning = false);
    // Android ≤11: skan BLE wymaga włączonej lokalizacji — bez niej system po cichu
    // zwraca pustą listę (na 12+ neverForLocation w manifeście załatwia sprawę).
    if (_results.isEmpty && Platform.isAndroid &&
        !await Geolocator.isLocationServiceEnabled()) {
      if (mounted) {
        setState(() => _error = tr(
            'Lokalizacja (GPS) jest wyłączona — na Androidzie 11 i starszych jest wymagana do skanowania Bluetooth.'));
      }
    }
  }

  Future<void> _connect(ScanResult r) async {
    await _ble.stopScan();
    setState(() {
      _selected = r; _step = _Step.form; _error = null;
      _restoreFrom = null; _restoreId = false;
    });
    _loadRestoreCandidates();   // async — selektor doładuje się w tle
  }


  Future<void> _startResetCountdown([String? reason]) async {
    setState(() { _waitingReset = true; _countdown = 60; _resetReason = reason; });
    while (_countdown > 0 && mounted) {
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) setState(() => _countdown--);
    }
    if (mounted) setState(() { _waitingReset = false; _step = _Step.scan; });
  }

  Future<void> _doSetup() async {
    if (_ssidCtrl.text.trim().isEmpty) {
      setState(() => _error = tr('Wpisz nazwę sieci WiFi')); return;
    }
    // Przechwyć serwisy przed awaitami (bezpieczny BuildContext)
    final walletService = context.read<WalletService>();
    final attestService = context.read<AttestService>();
    final nodeService   = context.read<NodeService>();
    final coreBloc      = context.read<CoreBloc>();
    final navigator     = Navigator.of(context);
    String? restoreBleName;   // przy restore node zwraca nową nazwę BLE (SENSMOS-<nowe ID>)
    bool restoredId = false;  // ID przywrócone na innej płytce → każdy import = nowe parowanie
    bool wasPaired  = false;  // node był sparowany na TYM telefonie → dogramy świeży klucz

    setState(() { _step = _Step.connecting; _error = null; _status = tr('Sprawdzam połączenie...'); });

    // Bez internetu rejestracja padnie TAK CZY TAK, ale node zdąży dostać konfigurację
    // WiFi i po 60 s watchdoga zrobi factory reset — tracąc tożsamość. Więc nie zaczynamy
    // w ogóle: sprawdzamy łączność, zanim dotkniemy urządzenia.
    if (!await attestService.beReachable()) {
      if (!mounted) return;
      setState(() {
        _step   = _Step.form;
        _status = '';
        _error  = tr('Nie można zarejestrować noda — aplikacja nie ma połączenia z internetem. '
                     'Telefon musi być online przez cały czas rejestracji. '
                     'Połącz się z siecią i spróbuj ponownie.');
      });
      return;
    }

    if (mounted) setState(() => _status = tr('Łączenie przez BLE...'));

    try {
      // 1. Połącz BLE + auth → nonce
      setState(() => _status = tr('Łączenie z nodem...'));
      await _ble.connect(_selected!.device);

      final nodePin = _pinCtrl.text.trim().isNotEmpty ? _pinCtrl.text.trim() : '123456';
      // Przy parowaniu PIN ustala user — pytanie o stary nie ma sensu, bo nikt go nie pamieta,
      // a BLE i tak oznacza dostep fizyczny do noda. Ustawiamy bezwarunkowo, PRZED auth.
      // Stare FW nie zna set_pin i odpowie "unknown" — wtedy auth idzie po staremu.
      setState(() => _status = tr('Ustawiam PIN na nodzie...'));
      await _ble.setPin(nodePin);
      setState(() => _status = tr('Autoryzacja BLE...'));
      final authResp = await _ble.sendCommand({'cmd': 'auth', 'pin': nodePin});
      // Zły PIN → node zwraca {status:error, msg:wrong_pin} BEZ nonce. Rozpoznaj to, zanim
      // potraktujemy brak nonce jako „stary firmware" — to zwykle po prostu zły PIN.
      if (authResp['status'] == 'error') {
        final m = authResp['msg']?.toString() ?? '';
        throw Exception(m == 'wrong_pin'
            ? tr('Zły PIN — sprawdź kod ustawiony na urządzeniu')
            : m == 'missing_pin'
                ? tr('Wpisz PIN urządzenia')
                : '${tr('Autoryzacja nieudana')}: $m');
      }
      final nonce = authResp['nonce'] as String? ?? '';
      _authDeviceId = authResp['device_id'] as String? ?? '';
      if (nonce.isEmpty) throw Exception(tr('Brak nonce — aktualizuj firmware'));

      // Odtworzenie poprzedniego ID: MUSI być przed register (sig/proof budowane z device_id).
      // Sama komenda jest testem FW — jak node ją przyjmie, umie; jak nie (stary FW → timeout/
      // błąd), PRZERYWAMY z prośbą o reflash zamiast po cichu robić nowy ID (user chciał restore).
      if (_restoreFrom != null && _restoreId && _restoreFrom!.id != _authDeviceId) {
        setState(() => _status = tr('Odtwarzam poprzednie ID noda...'));
        Map<String, dynamic> r;
        try {
          r = await _ble.sendCommand(
              {'cmd': 'set_device_id', 'id': _restoreFrom!.id},
              timeout: const Duration(seconds: 6));
        } catch (_) {
          throw Exception(tr('Ta płytka ma za stary firmware, żeby odtworzyć ID. '
              'Zaflashuj najnowszy firmware na sensmos.com/flash i spróbuj ponownie.'));
        }
        // Stary FW (<0.46) na nieznaną komendę odsyła {status:error, msg:unknown} → to samo:
        // reflash. (Poprawny id z listy nie da innego błędu.)
        if (r['status'] != 'ok') {
          throw Exception(tr('Ta płytka nie umie odtworzyć ID (firmware: %s). '
              'Zaflashuj najnowszy firmware na sensmos.com/flash i spróbuj ponownie.',
              [r['msg']?.toString() ?? '?']));
        }
        _authDeviceId = (r['device_id'] as String?) ?? _restoreFrom!.id;
        restoreBleName = r['ble_name'] as String?;   // node zmienił nazwę BLE na nowe ID
        // Inna płytka pod starym ID = klucz parowania w telefonie jest martwy (żył w NVS
        // poprzedniej płytki). Kasujemy od razu; jeśli node był sparowany, na końcu setupu
        // dogrywamy świeży klucz — cicho skasowany klucz zostawiłby usera w przekonaniu,
        // że node wciąż jest sparowany.
        wasPaired = await PairingService().hasAccess(_restoreFrom!.id);
        await PairingService().forgetLocal(_restoreFrom!.id);
        restoredId = true;
        print('[Setup] ID odtworzone: ${_authDeviceId.substring(0, 8)}… ble_name=$restoreBleName');
      }

      // 2. Rozstrzygnięcie portfela: istniejący / recovery / nowy
      setState(() => _status = tr('Sprawdzam portfel...'));
      final hasWallet = await walletService.exists();
      Map<String, dynamic> wstatus = {};
      try { wstatus = await _ble.walletStatus(); } catch (_) {}
      final nodeHasBackup = wstatus['has_backup'] == true;

      String ownerAddress;
      String? walletBlob;  // kopia do wysłania na node (jeśli go jeszcze nie ma)

      if (hasWallet) {
        ownerAddress = (await walletService.load())!.address;
        // Zawsze, nie tylko przy braku kopii: PIN wlasnie zostal ustawiony, a kopia jest nim
        // szyfrowana — zostawiona stara przestalaby sie odszyfrowywac.
        walletBlob = await walletService.exportEncrypted(nodePin);
      } else if (nodeHasBackup) {
        setState(() => _status = tr('Odzyskiwanie portfela z noda...'));
        final r = await _ble.walletRestore();
        final blob = r['blob'] as String?;
        if (blob == null || blob.isEmpty) throw Exception(tr('Brak kopii na nodzie'));
        // Kopia jest zaszyfrowana PIN-em Z CHWILI JEJ ZAPISU, a PIN wpisany teraz moze byc
        // inny — user wlasnie go ustawil. Pytamy wiec o tamten zamiast wywalac cale dodawanie.
        var tryPin = nodePin;
        String addr = '';
        while (addr.isEmpty) {
          try {
            addr = (await walletService.importEncrypted(blob, tryPin)).address;
          } catch (_) {
            if (!mounted) rethrow;
            final old = await showDialog<String>(
              context: context,
              builder: (_) => const _OldPinDialog(),
            );
            if (old == null || old.isEmpty) {
              throw Exception(tr('Bez PIN-u sprzed zmiany nie odczytam kopii portfela z noda.'));
            }
            tryPin = old;
            if (mounted) {
              setState(() => _status = tr('Odzyskiwanie portfela z noda...'));
            }
          }
        }
        ownerAddress = addr;
      } else {
        setState(() => _status = tr('Tworzę nowy portfel...'));
        final w = await walletService.create();
        ownerAddress = w.address;
        walletBlob = await walletService.exportEncrypted(nodePin);
      }

      setState(() => _status = tr('Podpisywanie challenge...'));
      final sigWallet = await walletService.signMessage(nonce);

      // GPS telefonu (jesteś fizycznie przy nodzie) → ceremonia v2 = trust + lokalizacja naraz.
      // Best-effort: brak/odmowa GPS → node zaufany, ale niebieski (GPS dograsz później).
      String? gpsLat, gpsLon;
      try {
        setState(() => _status = tr('Pobieram pozycję GPS...'));
        final gps = await AttestService.ceremonyGps();
        gpsLat = gps?.lat;
        gpsLon = gps?.lon;
      } catch (_) { /* brak GPS → node niebieski, GPS dograsz później */ }

      setState(() => _status = tr('Łączę z WiFi przez node...'));
      _nodeIp = await _ble.setupNode(
        pin:             nodePin,
        ownerAddress:    ownerAddress,
        walletSignature: sigWallet,
        nonce:           nonce,
        deviceId:        _authDeviceId,
        backendUrl:      Config.nodeBackendUrl,
        wifiSsid:        _ssidCtrl.text.trim(),
        wifiPassword:    _passCtrl.text,
        attest:          attestService,
        signAttest:      walletService.signMessage,
        walletBlob:      walletBlob,
        walletAddr:      ownerAddress,
        gpsLat:          gpsLat,
        gpsLon:          gpsLon,
        bleNameOverride: restoreBleName,
        gpsFuzz:         _gpsFuzz,
        ghost:           _ghost,
      );

      setState(() => _status = tr('Łączę z nodem przez sieć...'));
      // /node/confirm już wysłany w setupNode → watchdog wyłączony
      await nodeService.saveNode(_nodeIp!, nodePin, _authDeviceId);

      // Ceremonia mogła paść mimo udanej rejestracji (np. telefon stracił internet między
      // jednym a drugim). Node wtedy działa, ale NIE ZARABIA — i nic by o tym nie powiedziało.
      if (_ble.lastAttestError != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: AppTheme.amber,
          duration: const Duration(seconds: 8),
          content: Text(
              tr('Node dodany, ale weryfikacja się nie powiodła — bez niej nie nalicza nagród. '
                 'Powtórz ceremonię w ustawieniach noda (Zaufanie).'),
              style: const TextStyle(color: Colors.black)),
        ));
      }

      // Import noda sparowanego na tym telefonie → dogrywamy świeży klucz od razu:
      // jesteśmy fizycznie przy nodzie (BLE), znamy PIN, node właśnie wszedł do LAN-u.
      // Nie uda się (telefon w innej sieci itp.) → mówimy wprost, że trzeba sparować ręcznie.
      if (restoredId && wasPaired && mounted) {
        setState(() => _status = tr('Odtwarzam parowanie...'));
        final perr = await PairingService().pair(_authDeviceId, _nodeIp!, nodePin);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(perr == null
              ? SnackBar(content: Text(tr('Zdalny dostęp sparowany ponownie.')))
              : SnackBar(
                  backgroundColor: AppTheme.amber,
                  duration: const Duration(seconds: 10),
                  content: Text(
                      tr('Nowa płytka przejęła ID noda — zdalny dostęp wymaga ponownego sparowania: '
                         'Ustawienia noda → Zdalny dostęp, będąc w jego sieci WiFi.'),
                      style: const TextStyle(color: Colors.black)),
                ));
        }
      }

      setState(() { _step = _Step.done; _doneCountdown = 3; });
      for (int i = 3; i >= 0; i--) {
        if (!mounted) return;
        setState(() => _doneCountdown = i);
        if (i == 0) break;
        await Future.delayed(const Duration(seconds: 1));
      }
      coreBloc.add(NodeConnected());
      navigator.popUntil((r) => r.isFirst);

    } catch (e) {
      var msg = e.toString()
          .replaceAll('Exception: ', '')
          .replaceAll('TimeoutException: ', '');
      // Surowy błąd nawiązania Bluetooth (FlutterBluePlus) → ludzka rada. Częsty przypadek:
      // ktoś zrobił factory-reset przy otwartym ekranie → node ma nową nazwę, stary wybór martwy.
      final low = msg.toLowerCase();
      if (low.contains('flutterblueplus') || low.contains('fbp-code') ||
          (low.contains('connect') && low.contains('timed out'))) {
        msg = tr('Nie udało się połączyć z nodem przez Bluetooth. Upewnij się, że node jest w trybie konfiguracji (przytrzymaj przycisk ~3 s), podejdź bliżej i przełącz Bluetooth. Jeśli resetowałeś node — wróć do skanowania, bo ma teraz nową nazwę.');
      }
      try { await _ble.disconnect(); } catch (_) {}
      // Rejestracja padła po tym, jak node dostał już WiFi → watchdog zresetuje go za ~60 s.
      // Nazywamy przyczynę wprost: „urządzenie się resetuje" wskazywało palcem na sprzęt,
      // podczas gdy zwykle winna jest utrata sieci w telefonie.
      if (msg.contains('rejestracja_brak_internetu')) {
        print('[Setup] utracono internet w trakcie rejestracji — countdown reset');
        _startResetCountdown(tr('Utracono połączenie z internetem — nie udało się zarejestrować noda. '
                                'Telefon musi być online przez cały czas rejestracji.'));
      } else if (msg.contains('rejestracja_backend_odmowa')) {
        print('[Setup] BE odrzucil rejestracje — countdown reset');
        _startResetCountdown(tr('Serwer odrzucił rejestrację noda.'));
      } else {
        setState(() { _step = _Step.form; _error = msg; _status = ''; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: _step != _Step.done,
        title: Text(tr('Podłącz urządzenie')),
        actions: [
          if (_step == _Step.scan)
            IconButton(
              icon: _scanning
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.teal))
                  : const Icon(Icons.refresh),
              onPressed: _scanning ? null : _startScan,
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: switch (_step) {
          _Step.scan       => _buildScan(),
          _Step.form       => _buildForm(),
          _Step.connecting => _buildConnecting(),
          _Step.done       => _buildDone(),
        },
      ),
    );
  }

  // ── SCAN ─────────────────────────────────────────────────
  Widget _buildScan() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(children: [
        Icon(Icons.bluetooth_searching, color: _scanning ? AppTheme.teal : AppTheme.muted),
        const SizedBox(width: 10),
        Text(_scanning ? tr('Szukam...') : tr('Znalezione urządzenia'),
            style: const TextStyle(color: AppTheme.text, fontSize: 15)),
      ]),
      if (_error != null) ...[const SizedBox(height: 8),
        Text(_error!, style: const TextStyle(color: AppTheme.red))],
      const SizedBox(height: 16),
      Expanded(
        child: _results.isEmpty
            ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (_scanning) ...[
                  const CircularProgressIndicator(color: AppTheme.teal),
                  const SizedBox(height: 16),
                ],
                Text(
                    _scanning ? tr('Skanowanie...') : tr('Brak urządzeń.\nUpewnij się, że node jest w trybie konfiguracji.'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppTheme.muted)),
              ]))
            : ListView.builder(
                itemCount: _results.length,
                itemBuilder: (_, i) {
                  final r = _results[i];
                  final name = r.advertisementData.advName.isNotEmpty
                      ? r.advertisementData.advName : r.device.platformName;
                  return Card(child: ListTile(
                    leading: const Icon(Icons.sensors, color: AppTheme.teal),
                    title: Text(name, style: const TextStyle(color: AppTheme.text)),
                    subtitle: Text('RSSI ${r.rssi} dBm', style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                    trailing: const Icon(Icons.chevron_right, color: AppTheme.muted),
                    onTap: () => _connect(r),
                  ));
                }),
      ),
    ],
  );

  // ── FORM ─────────────────────────────────────────────────
  Widget _buildForm() {
    final name = _selected?.advertisementData.advName.isNotEmpty == true
        ? _selected!.advertisementData.advName : _selected?.device.platformName ?? 'Node';
    return SingleChildScrollView(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(child: ListTile(
          leading: const Icon(Icons.sensors, color: AppTheme.teal),
          title: Text(name, style: const TextStyle(color: AppTheme.text)),
          subtitle: Text(tr('Podaj dane WiFi'), style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
        )),
        const SizedBox(height: 20),
        _field(tr('Nazwa sieci WiFi (SSID)'), Icons.wifi, _ssidCtrl),
        const SizedBox(height: 12),
        _field(tr('Hasło WiFi'), Icons.lock_outline, _passCtrl, obscure: true),
        const SizedBox(height: 12),
        _field(tr('PIN noda (zapisany w urządzeniu)'), Icons.pin_outlined, _pinCtrl, type: TextInputType.number),
        if (_restoreCandidates.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: AppTheme.teal.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.teal.withOpacity(0.3)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SwitchListTile(
                value: _restoreId,
                onChanged: (v) => setState(() { _restoreId = v; if (!v) _restoreFrom = null; }),
                activeColor: AppTheme.teal,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                secondary: const Icon(Icons.history, color: AppTheme.muted),
                title: Text(tr('Odtwórz ID noda'),
                    style: const TextStyle(color: AppTheme.text, fontSize: 14)),
                subtitle: Text(
                    tr('Ta płytka przejmie ID i historię wybranego noda offline (np. po reflashu).'),
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
              ),
              if (_restoreId) ...[
                const Divider(height: 1, color: AppTheme.border),
                ..._restoreCandidates.map((n) => RadioListTile<SavedNode>(
                  value: n,
                  groupValue: _restoreFrom,
                  onChanged: (v) => setState(() => _restoreFrom = v),
                  activeColor: AppTheme.teal,
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  title: Text('${n.label} · ${n.id.substring(0, 8)}…',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppTheme.text, fontSize: 13)),
                  subtitle: Text(_ageLabel(n.id),
                      style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                )),
              ],
            ]),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.red.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.red.withOpacity(0.3)),
            ),
            child: Row(children: [
              const Icon(Icons.error_outline, color: AppTheme.red, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!, style: const TextStyle(color: AppTheme.red, fontSize: 13))),
            ]),
          ),
        ],
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.amber.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.amber.withOpacity(0.3)),
          ),
          child: Row(children: [
            const Icon(Icons.location_on_outlined, color: AppTheme.amber, size: 18),
            const SizedBox(width: 8),
            Expanded(
                child: Text(
                    tr('Zaraz poprosimy o lokalizację (GPS) — potwierdza, że node jest '
                        'fizycznie tutaj. Bez niej node działa, ale zarabia znacznie mniej.'),
                    style: const TextStyle(
                        color: AppTheme.amber, fontSize: 12, height: 1.35))),
          ]),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.teal.withOpacity(0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SwitchListTile(
              value: _gpsFuzz,
              // Przy ghoście pozycja i tak nie jest publikowana — rozmycie nie ma czego dotyczyć.
              onChanged: _ghost ? null : (v) => setState(() => _gpsFuzz = v),
              activeColor: AppTheme.teal,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              secondary: const Icon(Icons.blur_on, color: AppTheme.muted),
              title: Text(tr('Rozmyj dokładną pozycję'),
                  style: const TextStyle(color: AppTheme.text, fontSize: 14)),
              subtitle: Text(
                  tr('Na mapie pokazujemy punkt przesunięty o 200-800 m. Wyłącz tylko, '
                     'jeśli chcesz publikować dokładny adres.'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
            ),
            const Divider(height: 1, color: AppTheme.border),
            SwitchListTile(
              value: _ghost,
              onChanged: (v) => setState(() => _ghost = v),
              activeColor: AppTheme.amber,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              secondary: const Icon(Icons.visibility_off_outlined, color: AppTheme.muted),
              title: Text(tr('Tryb prywatny (ghost)'),
                  style: const TextStyle(color: AppTheme.text, fontSize: 14)),
              subtitle: Text(
                  tr('Node w ogóle nie pojawi się na mapie. Zarabia mniej, bo nie '
                     'współtworzy publicznego pokrycia sieci.'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _doSetup,
          style: FilledButton.styleFrom(backgroundColor: AppTheme.teal, foregroundColor: AppTheme.bg,
              padding: const EdgeInsets.symmetric(vertical: 16)),
          child: Text(tr('Konfiguruj'), style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        TextButton(
          onPressed: () => setState(() { _step = _Step.scan; _startScan(); }),
          child: Text(tr('← Wróć do skanowania'), style: const TextStyle(color: AppTheme.muted)),
        ),
      ],
    ));
  }

  // ── CONNECTING ───────────────────────────────────────────
  Widget _buildConnecting() {
    if (_waitingReset) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Stack(alignment: Alignment.center, children: [
            SizedBox(width: 80, height: 80,
              child: CircularProgressIndicator(
                value: _countdown / 60,
                strokeWidth: 6,
                color: AppTheme.red,
                backgroundColor: AppTheme.border,
              )),
            Text('$_countdown',
                style: const TextStyle(color: AppTheme.text,
                    fontSize: 24, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 24),
          Text(_resetReason ?? tr('Nie udało się zarejestrować noda'),
              style: const TextStyle(color: AppTheme.red, fontSize: 15,
                  fontWeight: FontWeight.w500),
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(tr('Urządzenie się resetuje — zaczekaj i spróbuj ponownie.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 13),
              textAlign: TextAlign.center),
        ]),
      ));
    }
    return Center(
    child: Padding(padding: const EdgeInsets.all(32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const CircularProgressIndicator(color: AppTheme.teal),
        const SizedBox(height: 24),
        Text(_status, style: const TextStyle(color: AppTheme.text, fontSize: 15),
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(tr('Może potrwać do 30 sekund'),
            style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
      ]),
    ),
  );
  }

  // ── DONE ─────────────────────────────────────────────────
  Widget _buildDone() => Center(
    child: Padding(padding: const EdgeInsets.all(32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: AppTheme.teal.withOpacity(0.12), shape: BoxShape.circle),
          child: const Icon(Icons.check, color: AppTheme.teal, size: 48)),
        const SizedBox(height: 20),
        Text(tr('Gotowe!'), style: const TextStyle(color: AppTheme.text, fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        if (_nodeIp != null) Text('Node: $_nodeIp', style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
        const SizedBox(height: 32),
        FilledButton(
          onPressed: () {
              context.read<CoreBloc>().add(NodeConnected());
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
          style: FilledButton.styleFrom(
              backgroundColor: AppTheme.teal, foregroundColor: AppTheme.bg,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14)),
          child: Text(
            _doneCountdown > 0
                ? tr('Przejdź do panelu (%s)', [_doneCountdown])
                : tr('Przejdź do panelu'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      ]),
    ),
  );

  TextField _field(String label, IconData icon, TextEditingController ctrl,
      {bool obscure = false, TextInputType? type}) =>
    TextField(
      controller: ctrl, obscureText: obscure, keyboardType: type,
      style: const TextStyle(color: AppTheme.text),
      decoration: InputDecoration(
        labelText: label, labelStyle: const TextStyle(color: AppTheme.muted),
        prefixIcon: Icon(icon, color: AppTheme.muted),
        filled: true, fillColor: AppTheme.card,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppTheme.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppTheme.border)),
      ),
    );

  @override
  void dispose() {
    _ssidCtrl.dispose(); _passCtrl.dispose(); _pinCtrl.dispose();
    _ble.stopScan();
    super.dispose();
  }
}

class _OldPinDialog extends StatefulWidget {
  const _OldPinDialog();
  @override
  State<_OldPinDialog> createState() => _OldPinDialogState();
}

class _OldPinDialogState extends State<_OldPinDialog> {
  final _pin = TextEditingController();

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('PIN sprzed zmiany'),
            style: const TextStyle(color: AppTheme.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('Kopia portfela na nodzie jest zaszyfrowana PIN-em, który obowiązywał w chwili '
                 'jej zapisu. Podaj tamten PIN — nowy jest już ustawiony i zostaje.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pin,
              autofocus: true,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: AppTheme.text, letterSpacing: 2),
              onSubmitted: (v) => Navigator.pop(context, v.trim()),
              decoration: InputDecoration(
                  labelText: tr('Poprzedni PIN'),
                  labelStyle: const TextStyle(color: AppTheme.muted)),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('Pomiń'))),
          TextButton(
              onPressed: () => Navigator.pop(context, _pin.text.trim()),
              child: Text(tr('Odczytaj'))),
        ],
      );
}
