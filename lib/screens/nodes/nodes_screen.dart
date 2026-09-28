import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import '../../theme.dart';
import '../../app_shell.dart';
import '../../core/core_bloc.dart';
import '../../core/core_state.dart';
import '../../core/core_event.dart';
import '../../services/wallet_service.dart';
import '../../services/owner_token_service.dart';
import '../../services/store_card_pref.dart';
import '../../services/node_service.dart';
import '../../services/ble_service.dart';
import '../../log.dart';
import '../node_config/node_config_screen.dart';
import '../node_config/trust_screen.dart';
import '../node_config/service_screen.dart';
import '../../config.dart';
import '../entities/entities_screen.dart';
import '../setup/setup_screen.dart';
import '../node/node_manager_screen.dart';
import 'gateway_screen.dart';
import '../node/emergency_screen.dart';
import '../terminal/terminal_screen.dart';
import '../terminal/terminal_hosts_screen.dart';
import '../integrations/ha_panel_screen.dart';
import '../integrations/link_report_screen.dart';
import '../integrations/lan_panels_screen.dart';
import '../integrations/store_screen.dart';
import '../integrations/ha_settings_screen.dart';
import '../../services/integrations/integration_kind.dart';
import '../../services/integrations/integration_store.dart';
import '../../services/pairing_service.dart';
import '../../util/pair_gate.dart';
import '../../widgets/news_section.dart';
import '../../l10n.dart';
import '../../services/deeplink_service.dart';

/// Panel — JEDNA lista nodów, źródło prawdy = BE (owned by wallet), działa wszędzie.
/// Lokalny wpis (IP/PIN) dopina się po device_id → odblokowuje akcje LOKALNE (tylko w sieci noda).
/// Akcje dzielą się na „Dostępne zawsze" (przez BE/relay: terminal, statystyki, usuń)
/// i „Sieć lokalna" (encje, ustawienia, lokalizacja — wyszarzone poza LAN-em).
class NodesScreen extends StatefulWidget {
  const NodesScreen({super.key});
  @override
  State<NodesScreen> createState() => _NodesScreenState();
}

class _NodesScreenState extends State<NodesScreen> {
  final _expanded = <String, bool>{};
  final _online = <String, bool>{}; // LOKALNA osiągalność (telefon w sieci noda)
  final _paired = <String, bool>{}; // czy TEN telefon ma klucz do noda (tunel bez niego nie ruszy)
  int _tick = 0;                    // licznik ticków pollingu (saldo rzadziej niż status online)
  final _nodeData = <String, Map<String, dynamic>>{}; // /info z noda (entity_count itd.)
  // Mnożnik geograficzny: im dalej najbliższy sąsiad, tym wyższy. W BE nazywa się
  // wciąż `scarcity`, ale liczy pokrycie, nie rzadkość danych — nazwa w apce idzie
  // za znaczeniem, nie za kolumną w bazie.
  final _coverage = <String, String>{};
  final _beData = <String, Map<String, dynamic>>{}; // /v1/nodes/:id (sąsiedzi/promień/saldo)
  final _kinds = <String, Set<String>>{}; // podpięte integracje per node (opt-in)
  final _attachments = <String, List<Map<String, dynamic>>>{}; // Additions: przystawki, za które node ręczy
  Map<String, dynamic>? _storePkg;   // karta Storage: /v1/store/package/:owner (na portfel, bez podpisu)
  List<Map<String, dynamic>> _myBeNodes = []; // WSZYSTKIE nody walleta wg BE — PRYMARNE źródło
  List<Map<String, dynamic>> _myGateways = []; // bramy LoRaWAN walleta (kind='gateway') — osobna sekcja
  final _nodeErr = <String, String>{};
  String? _balance;
  BleService? _bleRef;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    StoreCardPref.load();
    StoreCardPref.hidden.addListener(_onStorePref);
    _refresh();
    // częste odświeżanie statusu online (ws_online z BE = żywy WS, nie próg 10 min)
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      _fetchMyBeNodes();
      _probeAllLocal();
      // Saldo to DRUGIE, niezależne źródło tej samej liczby co w Portfelu. Bez tego po claimie
      // kafel trzymał kwotę sprzed operacji aż do pull-to-refresh albo restartu apki.
      // Co 3. tick (30 s) — saldo nie potrzebuje granulacji statusu online.
      if (++_tick % 3 == 0) { _fetchBalance(); _fetchStorePkg(); }
    });
    // Skróty z widgetu na pulpicie — przy starcie i przy każdym kolejnym stuknięciu.
    DeepLinkService.initial().then((l) { if (l != null) _handleLink(l); });
    DeepLinkService.listen(_handleLink);
  }


  /// Jedna zasada w całej apce: ALIAS, a gdy go nie ma — ID. Bez wariantów pośrednich,
  /// żeby ten sam node nie nazywał się raz miejscowością, raz identyfikatorem.
  String _nodeName(SavedNode n) =>
      (n.label.isNotEmpty && n.label != 'Node')
          ? n.label
          : (n.id.length >= 8 ? n.id.substring(0, 8) : n.id);

  /// `sensmos://open?kind=ha|term` → otwórz plugin. Jeden node z tym pluginem = wchodzimy
  /// od razu (dwa stuknięcia od pulpitu); kilka — pokazujemy wybór, bo zgadywanie tu boli.
  Future<void> _handleLink(String link) async {
    final kind = DeepLinkService.kindOf(link);
    if (kind == null || kind == 'app') return;
    final want = kind == 'ha' ? IntegrationKind.homeAssistant : IntegrationKind.terminal;

    // Zimny start: widget budzi apkę i deep link przychodzi ZANIM NodeService wczyta nody.
    // Bez tego czekania pierwsze stuknięcie zawsze kończyło się „żaden node nie ma pluginu".
    var nodes = context.read<NodeService>().nodes;
    for (var i = 0; i < 20 && nodes.isEmpty; i++) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      nodes = context.read<NodeService>().nodes;
    }
    if (!mounted || nodes.isEmpty) return;

    // Cel przypięty w konfiguracji („V") — wtedy widget nie pyta o nic.
    if (want == IntegrationKind.terminal) {
      final t = await IntegrationStore.widgetTermTarget();
      if (t != null && mounted) {
        final n = nodes.where((e) => e.id == t.$1).toList();
        final hosts = n.isEmpty ? <SshHost>[] : await IntegrationStore.sshHosts(t.$1);
        final h = hosts.where((e) => e.slug == t.$2).toList();
        if (n.isNotEmpty && h.isNotEmpty && mounted) {
          Navigator.push(context, MaterialPageRoute(
              builder: (_) => TerminalScreen(
                  deviceId: n.first.id, label: _nodeName(n.first), host: h.first)));
          return;
        }
      }
    } else {
      final id = await IntegrationStore.widgetHaTarget();
      if (id != null && mounted) {
        final n = nodes.where((e) => e.id == id).toList();
        if (n.isNotEmpty) { _openIntegration(want, n.first.id, _nodeName(n.first)); return; }
      }
    }
    if (!mounted) return;

    final matches = <SavedNode>[];
    for (final n in nodes) {
      final kinds = _kinds[n.id] ?? await IntegrationStore.enabledKinds(n.id);
      if (kinds.contains(want.id)) matches.add(n);
    }
    if (!mounted) return;

    if (matches.length == 1) { _openIntegration(want, matches.first.id, _nodeName(matches.first)); return; }

    // Nikt nie ma tego pluginu podpiętego (albo ma go kilka nodów) → wybór. Przy pustym
    // wyniku pokazujemy wszystkie nody i podpinamy plugin przy okazji — inaczej widget
    // odsyłał usera do ręcznego dodawania, co przeczy „dwa stuknięcia".
    final pinning = matches.isEmpty;
    final options = pinning ? nodes : matches;
    final picked = await showModalBottomSheet<SavedNode>(
      context: context,
      backgroundColor: AppTheme.card,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
            child: Text(tr(want.labelKey), style: const TextStyle(color: AppTheme.text, fontSize: 15)),
          ),
          if (pinning) Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Text(tr('Wybierz node — plugin zostanie do niego podpięty.'),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          ),
          for (final n in options)
            ListTile(
              leading: Icon(want.icon, color: AppTheme.teal),
              title: Text(_nodeName(n), style: const TextStyle(color: AppTheme.text)),
              subtitle: Text('id ${n.id.length >= 8 ? n.id.substring(0, 8) : n.id}',
                  style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
              onTap: () => Navigator.pop(ctx, n),
            ),
        ]),
      ),
    );
    if (picked == null || !mounted) return;
    if (pinning) {
      await IntegrationStore.setKind(picked.id, want.id, true);
      await _loadKinds(picked.id);
      if (!mounted) return;
    }
    _openIntegration(want, picked.id, _nodeName(picked));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bleRef = context.read<BleService>();
  }

  @override
  void dispose() {
    _poll?.cancel();
    StoreCardPref.hidden.removeListener(_onStorePref);
    super.dispose();
  }

  void _onStorePref() { if (mounted) setState(() {}); }

  Future<void> _refresh() async {
    final ns = context.read<NodeService>();
    _fetchMyBeNodes();
    _probeAllLocal();
    _pruneStale();
    _fetchBalance();
    _fetchStorePkg();
    for (final n in ns.nodes) { _fetchBeData(n.id); }
  }

  // Karta Storage czyta publiczne liczby pakietu — bez podpisu, żeby lista nodów nie wymagała
  // odblokowanego portfela.
  Future<void> _fetchStorePkg() async {
    final owner = context.read<CoreBloc>().state.wallet?.address;
    if (owner == null) return;
    try {
      final r = await http.get(Uri.parse('${Config.beUrl}/v1/store/package/${owner.toLowerCase()}'))
          .timeout(const Duration(seconds: 5));
      if (mounted) setState(() => _storePkg = jsonDecode(r.body) as Map<String, dynamic>);
    } catch (e) { Log.w('nodes', 'store: $e'); }
  }

  // ── merge BE (prymarne) + lokalne wpisy (IP/PIN) → jedna lista ──
  List<_UnifiedNode> _merged() {
    final ns = context.read<NodeService>();
    final localById = {for (final s in ns.nodes) s.id: s};
    final out = <_UnifiedNode>[];
    final seen = <String>{};
    for (final be in _myBeNodes) {
      final id = be['device_id'] as String;
      seen.add(id);
      out.add(_UnifiedNode(id: id, be: be, saved: localById[id]));
    }
    // lokalne, których BE (jeszcze) nie zwrócił — nie chowamy
    for (final s in ns.nodes) {
      if (!seen.contains(s.id)) out.add(_UnifiedNode(id: s.id, be: null, saved: s));
    }
    // Stała kolejność po ID. BE sortuje po last_ping, więc kafle skakały przy każdym
    // odświeżeniu i nie dało się trafić w ten, który się chciało otworzyć.
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  Future<void> _pruneStale() async {
    final ns = context.read<NodeService>();
    final coreBloc = context.read<CoreBloc>();
    final byIp = <String, List<SavedNode>>{};
    for (final n in ns.nodes) {
      if (n.ip.isEmpty) continue;
      byIp.putIfAbsent(n.ip, () => []).add(n);
    }
    for (final group in byIp.values.where((g) => g.length > 1)) {
      final ping = <String, DateTime?>{};
      for (final n in group) {
        try {
          final res = await http.get(Uri.parse('${Config.beUrl}/v1/nodes/${n.id}'))
              .timeout(const Duration(seconds: 5));
          final dev = (jsonDecode(res.body) as Map<String, dynamic>)['device']
              as Map<String, dynamic>? ?? {};
          ping[n.id] = DateTime.tryParse(dev['last_ping']?.toString() ?? '');
        } catch (_) { ping[n.id] = null; }
      }
      SavedNode? winner;
      for (final n in group) {
        final p = ping[n.id];
        if (p == null) continue;
        if (winner == null || p.isAfter(ping[winner.id]!)) winner = n;
      }
      if (winner == null) continue;
      final now = DateTime.now().toUtc();
      if (now.difference(ping[winner.id]!.toUtc()) > const Duration(minutes: 10)) continue;
      for (final n in group) {
        if (n.id == winner.id) continue;
        final p = ping[n.id];
        final stale = p == null || now.difference(p.toUtc()) > const Duration(hours: 1);
        if (!stale) continue;
        coreBloc.add(NodeRemoved(n.id));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
              tr('Usunięto nieaktywny wpis %s (node po reflashu)', [n.id.substring(0, 8)]))));
        }
      }
    }
  }

  String? _searching;   // device_id noda, dla którego trwa szukanie po mDNS

  // Odnalezienie noda w LAN po fakcie. Potrzebne, gdy onboarding poszedł po LTE:
  // telefon nigdy nie był z nodem w jednej sieci, więc nie miał skąd wziąć IP,
  // a późniejszy powrót na WiFi sam z siebie tego nie naprawia.
  Future<void> _findLocally(String id) async {
    setState(() => _searching = id);
    final ble = context.read<BleService>();
    final ns  = context.read<NodeService>();
    final short = id.length >= 6 ? id.substring(0, 6) : id;
    String? ip;
    try {
      ip = await ble.discoverByHostname(
          hostname: 'sensmos-$short', timeout: const Duration(seconds: 12));
    } catch (e) {
      Log.w('nodes', 'mDNS $short: $e');
    }
    if (!mounted) return;
    setState(() => _searching = null);

    if (ip == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppTheme.amber,
        duration: const Duration(seconds: 6),
        content: Text(
            tr('Nie znaleziono noda w tej sieci. Upewnij się, że telefon jest '
               'w tej samej sieci WiFi co node.'),
            style: const TextStyle(color: Colors.black)),
      ));
      return;
    }

    final pin = await _askPin();
    if (pin == null || !mounted) return;
    await ns.saveNode(ip, pin, id);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr('Node znaleziony: %s', [ip]))));
  }

  Future<String?> _askPin() async {
    final ctrl = TextEditingController(text: '123456');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Podaj PIN noda')),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('PIN noda')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anuluj'))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(tr('Zapisz'))),
        ],
      ),
    );
  }

  // Komunikat „czemu ten node zarabia inaczej". Bez tego user widział spadek nagród
  // i nie miał jak się dowiedzieć, że zabrakło potwierdzenia GPS.
  Widget _geoNotice(bool ghost) {
    final color = ghost ? const Color(0xFF3B82F6) : const Color(0xFFFF4444);
    final text = ghost
        ? tr('Tryb prywatny — node nie jest pokazywany na mapie i zarabia w obniżonej '
             'stawce, bo nie współtworzy publicznego pokrycia sieci.')
        : tr('Brak potwierdzonej lokalizacji GPS — ten node prawie nie zarabia. '
             'Podejdź do niego z telefonem i ustaw lokalizację.');
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(ghost ? Icons.visibility_off_outlined : Icons.location_off, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text,
            style: TextStyle(color: color, fontSize: 12, height: 1.35))),
      ]),
    );
  }

  Future<void> _fetchMyBeNodes() async {
    final owner = context.read<CoreBloc>().state.wallet?.address;
    if (owner == null) return;
    try {
      final res = await http.get(
        Uri.parse('${Config.beUrl}/v1/nodes/by-owner/$owner'),
        headers: {'X-App-Key': Config.appKey, 'X-App-Version': Config.appVersion},
      ).timeout(const Duration(seconds: 6));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final all = List<Map<String, dynamic>>.from(j['nodes'] ?? []);
      if (mounted) setState(() {
        _myBeNodes  = all.where((n) => n['kind'] != 'gateway').toList();
        _myGateways = all.where((n) => n['kind'] == 'gateway').toList();
      });
    } catch (e) { Log.w('nodes', 'by-owner: $e'); }
  }

  // Zapomnij node WYLACZNIE lokalnie — nie rusza BE. Dla wpisow, ktorych nie da sie
  // skasowac z sieci, bo naleza do innego portfela (zmiana tozsamosci, cudza plytka).
  Future<void> _forgetLocally(String id) async {
    final short = id.length > 8 ? '${id.substring(0, 8)}…' : id;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Usunąć z aplikacji?')),
        content: Text(tr('Node %s zniknie z tej listy. W sieci SENSMOS zostaje bez zmian — '
                         'nie należy do Twojego portfela, więc nie możesz go stamtąd usunąć.', [short])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anuluj'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Usuń z aplikacji'), style: const TextStyle(color: Color(0xFFFF6666)))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Klucz parowania też — sierota w secure storage blokowałaby parowanie po ponownym
    // dodaniu noda (apka uważałaby go za sparowanego martwym kluczem).
    await PairingService().forgetLocal(id);
    if (!mounted) return;
    context.read<CoreBloc>().add(NodeRemoved(id));
    setState(() { _expanded.remove(id); _online.remove(id); _nodeData.remove(id); });
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Usunięto z aplikacji: %s', [short]))));
  }

  Future<void> _deleteFromNetwork(String id) async {
    final short = id.length > 8 ? '${id.substring(0, 8)}…' : id;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Usunąć node z sieci?')),
        content: Text(tr(
            'Node %s i WSZYSTKIE jego dane zostaną trwale usunięte z SENSMOS. '
            'Możesz go później dodać ponownie (onboarding przez Bluetooth). '
            'Zarobione GALU pozostają w Twoim portfelu.', [short])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anuluj'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Usuń permanentnie'), style: const TextStyle(color: Color(0xFFFF4444)))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final owner = context.read<CoreBloc>().state.wallet?.address;
      final wallet = context.read<WalletService>();
      if (owner == null) throw Exception(tr('Brak portfela'));
      final ts = (DateTime.now().millisecondsSinceEpoch / 1000).floor();
      final sig = await wallet.signMessage('sensmos:delete:$id:$ts');
      final res = await http.delete(
        Uri.parse('${Config.beUrl}/v1/nodes/$id'),
        headers: {'Content-Type': 'application/json', 'X-App-Key': Config.appKey},
        body: jsonEncode({'owner': owner, 'ts': ts, 'sig': sig}),
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw Exception(jsonDecode(res.body)['error'] ?? res.statusCode);
      if (!mounted) return;
      await PairingService().forgetLocal(id);
      if (!mounted) return;
      final ns = context.read<NodeService>();
      if (ns.nodes.any((x) => x.id == id)) context.read<CoreBloc>().add(NodeRemoved(id));
      _fetchMyBeNodes();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Node usunięty z sieci'))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Błąd usuwania: %s', [e.toString()])),
          backgroundColor: const Color(0xFFFF4444)));
    }
  }

  Future<void> _fetchBeData(String deviceId) async {
    try {
      final res = await http.get(Uri.parse('${Config.beUrl}/v1/nodes/$deviceId'))
          .timeout(const Duration(seconds: 5));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final entities = j['entities'] as List? ?? [];
      final device = j['device'] as Map<String, dynamic>? ?? {};
      final balance = j['balance'] as Map<String, dynamic>? ?? {};
      // Mnożnik pokrycia = NAJLEPSZY z encji noda, dokładnie jak MAX(mult) w rozliczeniu
      // epoki (BE: epoch/rewards.js → nodeWeight) i jak best_mult na mapie. Wcześniej brana
      // była `entities.first`, a endpoint sortuje po entity_id — apka pokazywała mnożnik
      // przypadkowej encji (alfabetycznie pierwszej), nie ten, za który node dostaje GALU.
      // Po dojściu encji lora_* wartość na karcie zmieniła się bez żadnej zmiany w sieci.
      double? best;
      for (final e in entities) {
        final m = double.tryParse('${(e as Map)['scarcity_mult']}');
        if (m != null && (best == null || m > best)) best = m;
      }
      final coverage = best?.toStringAsFixed(3) ?? '—';
      if (mounted) setState(() {
        _coverage[deviceId] = coverage;
        _attachments[deviceId] = ((j['attachments'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _beData[deviceId] = {
          'neighbors': device['neighbor_count']?.toString() ?? '0',
          'radius': device['radius_km'] != null
              ? '${double.tryParse(device['radius_km'].toString())?.toStringAsFixed(1)} km' : '—',
          'balance': balance['available'] != null
              ? (double.tryParse(balance['available'].toString())?.toStringAsFixed(2) ?? '—') : '—',
          'located': device['located'] == true,
        };
      });
    } catch (e) { Log.w('nodes', 'beData: $e'); }
  }

  // 0.73: saldo z BE wprost (publiczne, po adresie właściciela) — koniec proxy przez noda.
  Future<void> _fetchBalance() async {
    final addr = context.read<CoreBloc>().state.wallet?.address;
    if (addr == null) return;
    try {
      final res = await http.get(Uri.parse('${Config.beUrl}/v1/wallet/$addr'))
          .timeout(const Duration(seconds: 6));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (mounted) {
        final bal = j['available'] ?? j['total_earned'];
        if (bal != null) setState(() => _balance = double.tryParse(bal.toString())?.toStringAsFixed(2) ?? bal.toString());
      }
    } catch (_) {}
  }

  // Sprawdź LOKALNĄ osiągalność (telefon w sieci noda) — na rozwinięcie karty.
  Future<void> _probeLocal(SavedNode n) async {
    if (await _tryInfo(n.ip, n.id, n.pin)) return;
    final short = n.id.length >= 6 ? n.id.substring(0, 6).toLowerCase() : n.id.toLowerCase();
    String? fresh;
    try {
      fresh = await _bleRef?.discoverByHostname(hostname: 'sensmos-$short.local', timeout: const Duration(seconds: 5));
    } catch (e) { Log.w('node', 'mDNS sensmos-$short: $e'); }
    if (fresh != null && fresh.isNotEmpty && fresh != n.ip) {
      if (mounted) await context.read<NodeService>().updateNodeIp(n.id, fresh);
      if (await _tryInfo(fresh, n.id, n.pin)) return;
    }
    if (mounted) setState(() => _online[n.id] = false);
  }

  void _probeAllLocal() {
    for (final n in context.read<NodeService>().nodes) { _probeLocalQuick(n); }
  }

  // Lekki, okresowy test osiągalności lokalnej (bez mDNS/retry) — żeby badge „W tej sieci"/„Zdalnie"
  // odświeżał się sam z pollingu, a nie dopiero po rozwinięciu karty.
  Future<void> _probeLocalQuick(SavedNode n) async {
    if (n.ip.isEmpty) { if (mounted && _online[n.id] != false) setState(() => _online[n.id] = false); return; }
    try {
      final res = await http.get(Uri.parse('http://${n.ip}/info'),
          headers: {'Authorization': 'Bearer ${n.pin}'}).timeout(const Duration(seconds: 3));
      if (!mounted) return;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (!_identityOk(j, n.id)) {
        _identityMismatch(n.id, j);
        setState(() { _online[n.id] = false; _nodeData.remove(n.id); });
        return;
      }
      setState(() { _online[n.id] = true; _nodeData[n.id] = j; _nodeErr.remove(n.id); });
    } catch (_) {
      if (mounted && _online[n.id] != false) setState(() => _online[n.id] = false);
    }
  }

  // Czy pod tym adresem stoi TEN node. Po przeflashowaniu płytka dostaje nową tożsamość,
  // a stary wpis lokalny nadal wskazuje to samo IP — bez tego sprawdzenia apka uznawała
  // osierocony node za żywy i wysyłała komendy do zupełnie innego urządzenia.
  bool _identityOk(Map<String, dynamic> j, String expectedId) {
    final got = j['device_id']?.toString() ?? '';
    return got.isEmpty || got == expectedId;   // starsze FW bez pola → nie blokuj
  }

  void _identityMismatch(String id, Map<String, dynamic> j) {
    final got = j['device_id']?.toString() ?? '?';
    _nodeErr[id] = tr('Pod tym adresem jest inny node (%s) — ta płytka została przeflashowana '
                      'i ma nową tożsamość.', [got.length >= 8 ? got.substring(0, 8) : got]);
  }

  Future<bool> _tryInfo(String ip, String id, String pin) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final res = await http.get(Uri.parse('http://$ip/info'),
            headers: {'Authorization': 'Bearer $pin'}).timeout(const Duration(seconds: 6));
        if (!mounted) return true;
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        if (!_identityOk(j, id)) {
          _identityMismatch(id, j);
          setState(() { _online[id] = false; _nodeData.remove(id); });
          return false;   // bez retry: to nie jest problem łączności
        }
        setState(() { _online[id] = true; _nodeData[id] = j; _nodeErr.remove(id); });
        return true;
      } catch (e) {
        Log.w('node', '/info $ip: ${e.toString().split('\n').first}');
        _nodeErr[id] = _simpleErr(e);
        if (attempt == 0) await Future.delayed(const Duration(milliseconds: 400));
      }
    }
    return false;
  }

  String _simpleErr(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('timeout')) return tr('Nie odpowiada (offline?)');
    if (s.contains('socketexception') || s.contains('refused') ||
        s.contains('unreachable') || s.contains('failed host')) return tr('Poza siecią');
    if (s.contains('formatexception')) return tr('Błędna odpowiedź noda');
    return tr('Niedostępny');
  }

  // ── stan noda z chmury (ws_online = żywy WS; fallback last_ping) ──
  double? _beSecs(Map<String, dynamic>? be) {
    final s = be?['seconds_since_ping'];
    if (s == null) return null;
    return double.tryParse(s.toString());
  }
  String _ago(num secs) {
    if (secs < 60) return tr('przed chwilą');
    if (secs < 3600) return '${(secs / 60).floor()}m';
    if (secs < 86400) return '${(secs / 3600).floor()}h';
    return '${(secs / 86400).floor()}d';
  }

  // ── LoRa awaryjne (FW 0.91 + model v2): baner na karcie noda ──
  // active=true: node BEZ żywego WS + świeża ramka (≤12 h) → bursztynowy alarm.
  // active=false: epizod HISTORYCZNY (≤48 h, node może być online) → wyciszony wpis,
  // żeby wejście do Panelu Emergency nie znikało razem z alarmem (dane/historia komend).
  Map<String, dynamic>? _emergInfo(Map<String, dynamic>? be) {
    if (be == null) return null;
    final at = DateTime.tryParse((be['lora_emerg_at'] ?? '').toString());
    if (at == null) return null;
    final secs = DateTime.now().difference(at).inSeconds;
    if (secs > 48 * 3600) return null;
    final last = be['lora_emerg_last'];
    if (last is! Map) return null;
    final vals = last['vals'];
    final active = be['ws_online'] != true && secs <= 12 * 3600;
    return {
      'secs': secs,
      'active': active,
      'rx': (last['rx'] ?? '').toString(),
      'vals': vals is Map ? vals : const {},
    };
  }

  // Licznik „Online" obejmuje też bramy LoRaWAN — właściciel samych bram nie może widzieć 0/0.
  int get _totalNodes => _myBeNodes.length + _myGateways.length;
  int get _reportingCount =>
      _myBeNodes.where((n) => n['ws_online'] == true || (n['status'] == 'online')).length +
      _myGateways.where((g) => g['status'] == 'online').length;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CoreBloc, CoreState>(builder: (context, state) {
      final list = _merged();
      return Scaffold(
        appBar: AppBar(
          title: Text(tr('Panel')),
          automaticallyImplyLeading: false,
          actions: [
            IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh, tooltip: tr('Odśwież')),
            IconButton(icon: const Icon(Icons.add), tooltip: tr('Dodaj node'),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NodeManagerScreen()))
                    .then((_) { if (mounted) _fetchMyBeNodes(); })),
            const InboxBellSlot(),
          ],
        ),
        body: list.isEmpty && _myGateways.isEmpty
            ? _buildEmpty()
            : RefreshIndicator(
                onRefresh: _refresh,
                color: AppTheme.teal,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildGlobalStats(),
                    if (state.wallet == null) _noWalletBanner(),
                    const SizedBox(height: 16),
                    // Aktualności pod portfelem, nad listą nodów. Gdy nie ma wpisów, widget
                    // ma zerowy rozmiar i niczego tu nie przesuwa. Adres portfela decyduje
                    // o wpisach celowanych (kraj / wersja FW / konkretne portfele).
                    NewsSection(owner: state.wallet?.address),
                    ...list.map(_buildCard),
                    ..._myGateways.map(_gatewayCard),
                    // Karta Storage: na portfel, nie na noda — dlatego pod listą, nie w karcie.
                    // Warunku „co najmniej jeden node" JUŻ NIE MA (2026-09-09): miejsce kupuje się
                    // na adres, a pokrycie sprawdza BE przy zakładaniu pakietu. Ukrywanie karty
                    // przed kimś bez sprzętu zamykało mu jedyną drogę, którą właśnie otworzyliśmy.
                    if (!StoreCardPref.hidden.value && state.wallet != null)
                      _storageCard(),
                  ],
                ),
              ),
      );
    });
  }

  // RemoteTerminal (on-demand tunel + PIN gate) jest dopiero od FW > 0.70 — na starszych ukryj wejście.
  bool _fwGt(dynamic fw, double min) {
    // Wersja bywa z sufiksem gałęzi ('0.80-lora6', '0.80-fsk3') — double.tryParse zwracał wtedy
    // null i node z LoRy wyglądał na starszy niż 0.70, więc integracje były dla niego zablokowane
    // mimo firmware 0.80. Bierzemy sam prefiks major.minor.
    final m = RegExp(r'^\d+\.\d+').firstMatch(fw?.toString() ?? '');
    final v = m == null ? null : double.tryParse(m.group(0)!);
    return v != null && v > min;
  }

  Future<void> _loadKinds(String id) async {
    final k = await IntegrationStore.enabledKinds(id);
    final p = await PairingService().hasAccess(id);
    if (mounted) setState(() { _kinds[id] = k; _paired[id] = p; });
  }

  // Rząd integracji: podpięte (tap → otwórz, long-press → odepnij) + „Dodaj".
  Widget _integrationsRow(String id, String name, Map<String, dynamic>? be, bool wsOnline) {
    final enabled = _kinds[id] ?? const <String>{};
    final fwOk = _fwGt(be?['firmware'], 0.70);
    final hasWallet = context.read<CoreBloc>().state.wallet != null;
    // Pluginy tunelowe wymagają żywego WS i FW>0.70; chmurowe (Raport łącza) tylko
    // portfela — działają też, gdy node właśnie leży (to wtedy raport jest najciekawszy).
    final canOpenTunnel = wsOnline && hasWallet && fwOk;
    final hasAddable = IntegrationKind.values.any((k) => !enabled.contains(k.id));
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final kid in enabled)
        if (IntegrationKindX.fromId(kid) case final k?)
          OutlinedButton.icon(
            onPressed: (k.needsTunnel ? canOpenTunnel : hasWallet)
                ? () => _openIntegration(k, id, name) : null,
            onLongPress: () => _removeIntegration(id, k),
            icon: Icon(k.icon, size: 16),
            label: Text(tr(k.labelKey)),
            style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.teal,
                side: BorderSide(color: AppTheme.teal.withOpacity(0.5))),
          ),
      // „Dodaj" tylko gdy jest jeszcze co dodać (wszystko podpięte → chowamy)
      if (hasAddable)
        OutlinedButton.icon(
          onPressed: () => _addIntegration(id, name, be),
          icon: const Icon(Icons.add, size: 16),
          label: Text(tr('Dodaj')),
          style: OutlinedButton.styleFrom(foregroundColor: AppTheme.muted),
        ),
    ]);
  }

  void _openIntegration(IntegrationKind k, String id, String name) {
    final screen = switch (k) {
      IntegrationKind.terminal => TerminalHostsScreen(deviceId: id, label: name),
      IntegrationKind.homeAssistant => HaPanelScreen(deviceId: id, label: name),
      IntegrationKind.linkReport => LinkReportScreen(deviceId: id, label: name),
      IntegrationKind.lanPanel => LanPanelsScreen(deviceId: id, label: name),
    };
    // Po powrocie odśwież parowanie — ekran mógł je zmienić (parowanie w terminalu,
    // samonaprawa kasująca martwy klucz przy „node not paired").
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen))
        .then((_) { if (mounted) _loadKinds(id); });
  }

  Future<void> _addIntegration(String id, String name, Map<String, dynamic>? be) async {
    final fwOk = _fwGt(be?['firmware'], 0.70);
    final paired = _paired[id] == true;
    final enabled = _kinds[id] ?? const <String>{};
    final addable = IntegrationKind.values.where((k) => !enabled.contains(k.id)).toList();
    final chosen = await showModalBottomSheet<IntegrationKind>(
      context: context,
      backgroundColor: AppTheme.surface,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(tr('Dodaj integrację'),
                style: const TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600, fontSize: 15)),
          ),
          for (final k in addable)
            ListTile(
              leading: Icon(k.icon, color: AppTheme.teal),
              title: Text(tr(k.labelKey), style: const TextStyle(color: AppTheme.text)),
              // Warunki wstępne wprost przy wyborze. FW jest twardy (blokuje), parowanie tylko
              // uprzedza — da się je zrobić po dodaniu, byle w sieci noda.
              subtitle: (k.needsTunnel && !fwOk)
                  ? Text(tr('Wymaga FW > 0.70'), style: const TextStyle(color: AppTheme.amber, fontSize: 12))
                  : (k.needsTunnel && !paired)
                      ? Text(tr('Wymaga sparowania noda — tylko w jego sieci WiFi'),
                          style: const TextStyle(color: AppTheme.amber, fontSize: 12))
                      : null,
              enabled: !(k.needsTunnel && !fwOk),
              onTap: () => Navigator.pop(context, k),
            ),
          if (addable.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(tr('Wszystko już podpięte'), style: const TextStyle(color: AppTheme.muted)),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (chosen == null) return;
    if (!mounted) return;   // sheet mógł się zamknąć razem z ekranem — dalej idzie context
    // Parowanie ZARAZ po wyborze, póki user jest w sieci noda — a jest, bo integracje dodaje się
    // zwykle tuż po onboardingu, w domu. Odłożenie tego do pierwszego użycia znaczy, że o wymogu
    // dowie się z wakacji, gdzie klucza nie ma jak zapisać (kanał jest wyłącznie lokalny).
    if (chosen.needsTunnel && _paired[id] != true) {
      if (_online[id] == true) {
        final acc = await ensurePaired(context, id);
        if (!mounted) return;
        // Prawda z wyniku, nie życzeniowe true: anulowane parowanie zostawiało
        // kartę w stanie „sparowany" — odwrotne kłamstwo niż to z ustawień.
        setState(() => _paired[id] = acc.ok);
        _loadKinds(id);   // i tak przeładuj z magazynu (źródło prawdy)
      } else {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppTheme.card,
            title: Text(tr('Wymagane sparowanie'), style: const TextStyle(color: AppTheme.text)),
            content: Text(
              tr('Ta integracja otwiera tunel do Twojej sieci, a zgodę na to daje sam node — nie nasz '
                 'serwer. Trzeba zapisać w nim klucz, będąc w tej samej sieci WiFi: '
                 'Ustawienia noda → Zdalny dostęp.\n\nIntegrację dodam już teraz, ale połączy się '
                 'dopiero po sparowaniu.'),
              style: const TextStyle(color: AppTheme.muted)),
            actions: [
              FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Rozumiem'))),
            ],
          ),
        );
        if (!mounted) return;
      }
    }
    if (chosen.needsConfig) {
      final Widget cfg = switch (chosen) {
        IntegrationKind.lanPanel =>
            LanPanelsScreen(deviceId: id, label: name, configMode: true),
        IntegrationKind.terminal =>
            TerminalHostsScreen(deviceId: id, label: name, configMode: true),
        _ => HaSettingsScreen(deviceId: id, label: name),
      };
      final saved = await Navigator.push<bool>(
          context, MaterialPageRoute(builder: (_) => cfg));
      if (saved != true) return; // anulował konfigurację → nie podpinaj
    }
    await IntegrationStore.setKind(id, chosen.id, true);
    await _loadKinds(id);
  }

  Future<void> _removeIntegration(String id, IntegrationKind k) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('Odpiąć integrację?'), style: const TextStyle(color: AppTheme.text)),
        content: Text(tr(k.labelKey), style: const TextStyle(color: AppTheme.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anuluj'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Odepnij'))),
        ],
      ),
    );
    if (ok != true) return;
    await IntegrationStore.setKind(id, k.id, false);
    if (k == IntegrationKind.homeAssistant) await IntegrationStore.remove(id); // wyczyść binding HA
    await _loadKinds(id);
  }

  // ── Karta noda (zunifikowana) ──
  Future<void> _editAlias(String id, SavedNode saved) async {
    final ctrl = TextEditingController(text: saved.label == 'Node' ? '' : saved.label);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('Nazwa / tag noda'), style: const TextStyle(color: AppTheme.text)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Twoja etykieta, żeby łatwiej rozpoznać node — np. Garaż albo Router.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          const SizedBox(height: 10),
          TextField(controller: ctrl, autofocus: true, maxLength: 24,
              style: const TextStyle(color: AppTheme.text),
              decoration: InputDecoration(
                  hintText: 'sensmos-${id.substring(0, id.length >= 6 ? 6 : id.length)}',
                  hintStyle: const TextStyle(color: AppTheme.muted))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anuluj'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.teal),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('Zapisz'), style: const TextStyle(color: Colors.black))),
        ],
      ),
    );
    if (v == null || !mounted) return;
    await context.read<NodeService>().renameNode(id, v.isEmpty ? 'Node' : v);
    // Dosyłka aliasu na node (NVS, widoczny w /info) — best-effort, tylko gdy znamy IP
    // z LAN; poza siecią etykieta i tak żyje lokalnie, node dostanie ją następnym razem.
    if (saved.ip.isNotEmpty) {
      http.post(Uri.parse('http://${saved.ip}/node/alias'),
          headers: {'Content-Type': 'application/json',
                    'Authorization': 'Bearer ${saved.pin}'},
          body: jsonEncode({'alias': v}))
        .timeout(const Duration(seconds: 4))
        .catchError((_) => http.Response('', 0));
    }
    if (mounted) setState(() {});
  }

  Widget _buildCard(_UnifiedNode u) {
    final be = u.be;
    final saved = u.saved;
    final id = u.id;
    final expanded = _expanded[id] ?? false;
    // Nazwa noda dla pluginów i belek: ALIAS, a gdy go nie ma — ID. Miejscowość wypadła:
    // ten sam node nazywał się raz miastem, raz identyfikatorem (na karcie miasto jest
    // osobno, niżej).
    final name = (saved?.label.isNotEmpty == true && saved?.label != 'Node')
        ? saved!.label
        : (id.length >= 8 ? id.substring(0, 8) : id);

    // Stan z chmury: ws_online (żywy WS) najpewniejszy; inaczej last_ping.
    final wsOnline = be?['ws_online'] == true;
    final secs = _beSecs(be);
    final healthColor = wsOnline ? AppTheme.teal
        : (secs != null && secs < 3600) ? Colors.amber.shade700 : AppTheme.muted;
    // „online" = żywe połączenie WS. Gdy node jest cichy (>3 min bez sygnału mimo połączenia)
    // dopisujemy kiedy ostatnio się odezwał — żeby „online" nie było gołym twierdzeniem.
    final healthText = wsOnline
        ? (secs != null && secs > 180 ? '${tr('online')} · ${_ago(secs)}' : tr('online'))
        : secs != null ? '${tr('cisza')} ${_ago(secs)}' : tr('brak danych z chmury');

    // Osiągalność lokalna (do akcji lokalnych)
    final localReachable = _online[id] == true;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: AppTheme.border, width: 1)),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            setState(() => _expanded[id] = !expanded);
            if (!expanded) {
              _fetchBeData(id);
              _loadKinds(id);
              if (saved != null) _probeLocal(saved);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              // Ghost = niebieski, jak na mapie (tam blue to node bez potwierdzonej
              // pozycji publicznej). Stan łączności nie ginie — jest wypisany tekstem
              // w linijce pod spodem.
              Container(width: 10, height: 10, decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: be?['ghost'] == true ? const Color(0xFF3B82F6) : healthColor)),
              if (saved != null) ...[
                const SizedBox(width: 8),
                InkWell(
                    onTap: () => _editAlias(id, saved),
                    child: const Icon(Icons.edit_outlined, size: 16, color: AppTheme.muted)),
              ],
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // ID na pierwszym planie — to ono identyfikuje node jednoznacznie,
                // a miejscowość bywa ta sama dla kilku sztuk albo pusta.
                // Ikonki stanu w prawym rogu TEJ linii, a nie w głównym rzędzie —
                // tam konkurowały o szerokość z badge'em i strzałką i nic się nie mieściło.
                // ID + firmware jako JEDEN Text z elipsą wewnątrz Expanded. Wcześniej były
                // to dwa Texty w zagnieżdżonym Row — przy ciasnym kafelku ten Row przepełniał
                // się i malował po ikonach, które przez to siedziały na napisie „fw 0.79".
                // Text z ellipsis nie wyjdzie poza swój box niezależnie od szerokości.
                Row(children: [
                  Expanded(child: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                          text: id.substring(0, id.length >= 8 ? 8 : id.length),
                          style: const TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600,
                              fontSize: 14, letterSpacing: 0.6)),
                      TextSpan(text: '   fw ${be?['firmware'] ?? '?'}',
                          style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                    ]),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  )),
                  if (be != null && be['geo_state'] != 'gps')
                    const Padding(padding: EdgeInsets.only(left: 8),
                        child: Icon(Icons.location_off, size: 15, color: Color(0xFFFF4444))),
                  if (be?['ghost'] == true)
                    const Padding(padding: EdgeInsets.only(left: 8),
                        child: Icon(Icons.visibility_off_outlined, size: 15, color: Color(0xFF3B82F6))),
                ]),
                // Linia 2: miejscowość z lewej, znacznik sieci z prawej. Badge zszedł
                // z głównego rzędu — tam zabierał szerokość wszystkim trzem liniom naraz
                // i to on wypychał ikony na tekst pierwszej linii.
                Row(children: [
                  Expanded(child: Text(
                      (be?['city']?.toString().isNotEmpty == true) ? be!['city'] as String : name,
                      style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 8),
                  _reachBadge(localReachable, saved != null),
                ]),
                Text(healthText, style: TextStyle(color: healthColor, fontSize: 11),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                if (_emergInfo(be)?['active'] == true)
                  Text('⚠ ${tr('LoRa awaryjne — słyszany radiem')}',
                      style: TextStyle(color: Colors.amber.shade700, fontSize: 11),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
              ])),
              const SizedBox(width: 8),
              Icon(expanded ? Icons.expand_less : Icons.expand_more, color: AppTheme.muted, size: 20),
            ]),
          ),
        ),
        if (expanded) ...[
          const Divider(color: AppTheme.border, height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // LoRa awaryjne (model v2): kompaktowy banner — encje, historia i komenda
              // awaryjna żyją na osobnym ekranie (Panel Emergency), nie na kafelku.
              if (_emergInfo(be) case final emerg?) ...[
                Builder(builder: (context) {
                  final active = emerg['active'] == true;
                  final col = active ? Colors.amber.shade700 : AppTheme.muted;
                  final bg  = active ? Colors.amber : Colors.grey;
                  return Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: bg.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: bg.withValues(alpha: 0.35)),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Icon(Icons.cell_tower, size: 16, color: col),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            active
                                ? tr('LoRa awaryjne — bez internetu, słyszany %s temu przez %s',
                                    [_ago(emerg['secs'] as int), emerg['rx']])
                                : tr('LoRa awaryjne — ostatni epizod %s temu',
                                    [_ago(emerg['secs'] as int)]),
                            style: TextStyle(color: col, fontSize: 12),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: col,
                            side: BorderSide(color: bg.withValues(alpha: 0.5)),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          icon: const Icon(Icons.emergency_share, size: 16),
                          label: Text(tr('Panel Emergency — encje i komenda'),
                              style: const TextStyle(fontSize: 12)),
                          onPressed: () => Navigator.push(context, MaterialPageRoute(
                              builder: (_) => EmergencyScreen(deviceId: id, name: name))),
                        ),
                      ),
                    ]),
                  );
                }),
              ],
              // Statystyki. Elastyczne, bo na wąskich ekranach (starsze telefony) sztywne
              // odstępy + Spacer wypychały „Pełne ID / Kopiuj" poza kartę.
              Row(children: [
                // „Scarcity" to była nazwa sprzed lat — ten mnożnik liczy się z promienia pokrycia,
                // nie z rzadkości danych. Nazwa ujednolicona z mapą i stroną noda (2026-08-18).
                Expanded(child: _stat(tr('Pokrycie'), _coverage[id] ?? '—')),
                Expanded(child: _stat(tr('Sąsiedzi'), _beData[id]?['neighbors'] ?? '—')),
                Expanded(child: _stat(tr('Promień'), _beData[id]?['radius'] ?? '—')),
                const SizedBox(width: 8),
                // Wcześniej sama ikonka kopiowania obok trzech opisanych statystyk —
                // nie było wiadomo, czego dotyczy. Teraz podpisana jak reszta.
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: id));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(tr('ID skopiowane: %s', [id])), duration: const Duration(seconds: 2)));
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(tr('Pełne ID'),
                          style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                      const SizedBox(height: 2),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(tr('Kopiuj'), style: const TextStyle(
                            color: AppTheme.teal, fontSize: 13, fontWeight: FontWeight.w500)),
                        const SizedBox(width: 4),
                        const Icon(Icons.copy, size: 14, color: AppTheme.teal),
                      ]),
                    ]),
                  ),
                ),
              ]),
              const SizedBox(height: 14),

              // ── Additions: przystawki, za które ten node ręczy (brama LoRa, agent Store).
              // Nie integracje: integrację dodaje user w apce, przystawkę paruje się na LAN-ie.
              if ((_attachments[id] ?? const []).isNotEmpty) ...[
                _groupLabel(Icons.usb_outlined, tr('Dodatki')),
                const SizedBox(height: 8),
                for (final a in _attachments[id]!) _attachmentTile(id, a),
                const SizedBox(height: 14),
              ],

              // ── Integracje (opt-in: user dodaje tylko to, czego potrzebuje) ──
              _groupLabel(Icons.extension_outlined, tr('Integracje')),
              const SizedBox(height: 8),
              _integrationsRow(id, name, be, wsOnline),
              if (!wsOnline) Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(tr('Integracje wymagają noda online (połączonego z chmurą).'),
                    style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
              ),
              // Ostrzeżenie zostaje na karcie, a nie znika razem z bottom-sheetem — user widzi je
              // za każdym razem, gdy jest w domu, a nie dopiero gdy tunel odmówi z wakacji.
              if (_paired[id] != true && (_kinds[id]?.isNotEmpty ?? false)) Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(tr('Node niesparowany — tunel nie ruszy. Sparuj, będąc w jego sieci WiFi.'),
                    style: const TextStyle(color: AppTheme.amber, fontSize: 11)),
              ),
              const SizedBox(height: 14),
              // Dwie ROZNE operacje, wiec dwa osobne przyciski obok siebie:
              //   z sieci  — kasuje w BE, wymaga podpisu portfelem WLASCICIELA
              //   z listy  — czysci tylko lokalny wpis w tej apce, BE nietkniete
              // Bez tego drugiego porzucony node (zmieniona tozsamosc, inny portfel)
              // zostawal na liscie na zawsze, bo pierwszego nie da sie wykonac.
              Row(children: [
                // FittedBox zamiast ellipsis: „Remove from network" ma się zmniejszyć,
                // a nie zostać przycięte do „Remov…" (bez tego etykieta traci sens).
                Expanded(child: OutlinedButton.icon(
                  onPressed: () => _deleteFromNetwork(id),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: FittedBox(fit: BoxFit.scaleDown, child: Text(tr('Usuń z sieci'), maxLines: 1)),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      foregroundColor: const Color(0xFFFF6666),
                      side: const BorderSide(color: Color(0x55FF6666))),
                )),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(
                  onPressed: saved == null ? null : () => _forgetLocally(id),
                  icon: const Icon(Icons.playlist_remove, size: 16),
                  label: FittedBox(fit: BoxFit.scaleDown, child: Text(tr('Usuń z listy'), maxLines: 1)),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      foregroundColor: AppTheme.amber,
                      side: BorderSide(color: AppTheme.amber.withOpacity(0.35))),
                )),
              ]),
              const SizedBox(height: 16),

              // ── Sieć lokalna (tylko w domu) ──
              _groupLabel(Icons.wifi, tr('Sieć lokalna (tylko w sieci noda)')),
              // Adres IP wprost, z kopiowaniem — potrzebny wszędzie tam, gdzie wpisuje się
              // go ręcznie (np. integracja w Home Assistancie), a dotąd nigdzie go nie było.
              if (saved != null && saved.ip.isNotEmpty) ...[
                const SizedBox(height: 6),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: saved.ip));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        duration: const Duration(seconds: 2),
                        content: Text(tr('Skopiowano %s', [saved.ip]))));
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      const Icon(Icons.lan_outlined, size: 14, color: AppTheme.muted),
                      const SizedBox(width: 6),
                      Text('${tr('Adres IP')}:  ',
                          style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                      Text(saved.ip, style: const TextStyle(
                          color: AppTheme.text, fontSize: 13,
                          fontFeatures: [FontFeature.tabularFigures()])),
                      const SizedBox(width: 6),
                      const Icon(Icons.copy, size: 13, color: AppTheme.teal),
                    ]),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              if (saved != null && localReachable) ...[
                Row(children: [
                  Expanded(child: OutlinedButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(
                        builder: (_) => EntitiesScreen(ip: saved.ip, pin: saved.pin))),
                    icon: const Icon(Icons.sensors, size: 16),
                    label: Text(tr('Encje')),
                    style: OutlinedButton.styleFrom(foregroundColor: AppTheme.teal, side: const BorderSide(color: AppTheme.teal)),
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: OutlinedButton.icon(
                    // Po powrocie odśwież stan parowania: user mógł sparować/rozparować
                    // w ustawieniach, a karta trzymała starą mapkę i „kłamała" (niesparowany
                    // mimo świeżego klucza — zgłoszone 2026-08-26).
                    onPressed: () => Navigator.push(context, MaterialPageRoute(
                        builder: (_) => NodeConfigScreen(node: saved)))
                        .then((_) { if (mounted) _loadKinds(saved.id); }),
                    icon: const Icon(Icons.settings_outlined, size: 16),
                    label: Text(tr('Ustawienia')),
                    style: OutlinedButton.styleFrom(foregroundColor: AppTheme.text, side: const BorderSide(color: AppTheme.border)),
                  )),
                ]),
                // Dlaczego node zarabia mało albo wcale — wprost, zamiast samej ikonki.
                // Oba powody mogą wystąpić naraz i wtedy oba są pokazywane: brak GPS
                // jest ważniejszy (kosztuje więcej), więc idzie pierwszy.
                if (be != null && be['geo_state'] != null && be['geo_state'] != 'gps') ...[
                  const SizedBox(height: 10),
                  _geoNotice(false),
                ],
                if (be?['ghost'] == true) ...[
                  const SizedBox(height: 8),
                  _geoNotice(true),
                ],
                if (be != null && be['geo_state'] != 'gps') ...[
                  const SizedBox(height: 8),
                  SizedBox(width: double.infinity, child: TextButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TrustScreen(node: saved))),
                    icon: const Icon(Icons.add_location_alt, size: 18),
                    label: Text(tr('Ustaw lokalizację (BLE + GPS)')),
                    style: TextButton.styleFrom(foregroundColor: Colors.amber.shade700),
                  )),
                ],
                if (context.read<CoreBloc>().state.wallet == null) ...[
                  const SizedBox(height: 8),
                  SizedBox(width: double.infinity, child: TextButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ServiceScreen(node: saved))),
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: Text(tr('Importuj portfel z noda')),
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF6666)),
                  )),
                ],
              ] else _localLocked(saved != null, id),
            ]),
          ),
        ],
      ]),
    );
  }

  // ── Additions ──
  Widget _attachmentTile(String deviceId, Map<String, dynamic> a) {
    final isStore = a['kind'] == 'store';
    final store = a['store'] as Map<String, dynamic>?;
    final online = a['online'] == true;
    final rawName = (a['name'] as String?)?.trim() ?? '';
    final name = rawName.isNotEmpty ? rawName : (isStore ? 'Store' : tr('Brama LoRa'));
    final since = DateTime.tryParse('${a['created_at']}')?.toLocal();
    final sinceS = since == null ? '' : ' · ${tr('od %s', ['${since.day}.${since.month.toString().padLeft(2, '0')}'])}';
    // Sprzedawca patrzy w apkę, nie w log agenta — więc to jedyne miejsce, gdzie się dowie,
    // że warto podmienić plik. Jedna rada, nie dwie: o portach nie piszemy, bo stary agent
    // i tak nie dostanie transferu bezpośredniego, choćby port był otwarty.
    final storeHint = store == null || store['agent_old'] != true ? null
        : tr('Dostępna nowsza wersja: sensmos-store.py');
    final String info;
    if (isStore && store != null) {
      info = '${tr('oferowane %s GB · zajęte %s GB', [_gbS(store['capacity_b']), _gbS(store['used_b'])])}\n'
          '${tr('kopii u Ciebie: %s · dowody 7 dni: %s ✓ %s ✗', [store['objects'] ?? 0, store['proof_ok_7d'] ?? 0, store['proof_fail_7d'] ?? 0])}\n'
          '${tr('zarobek 7 dni: %s · łącznie: %s GALU', [_galuS(store['earned_7d']), _galuS(store['earned_total'])])}';
    } else {
      info = tr('meldunków: %s', [a['req_count'] ?? 0]) + sinceS;
    }
    return Card(
      color: AppTheme.surface, margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: Icon(isStore ? Icons.sd_storage_outlined : Icons.cell_tower,
            color: online ? AppTheme.teal : AppTheme.muted),
        title: Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle,
              color: online ? AppTheme.teal : AppTheme.muted)),
          const SizedBox(width: 8),
          Expanded(child: Text('${isStore ? 'Store' : tr('Brama LoRa')} · $name',
              style: const TextStyle(color: AppTheme.text, fontSize: 13), overflow: TextOverflow.ellipsis)),
          Text(online ? tr('online') : tr('offline'),
              style: TextStyle(color: online ? AppTheme.teal : AppTheme.muted, fontSize: 11)),
        ]),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Nasłuchuje, ale nie da się do niego dodzwonić — pliki chodzą przez serwer zamiast
          // wprost. Sam stan, bez rady. Przy starszym agencie ten znacznik byłby kłamstwem,
          // bo tamten nie otwiera żadnego portu — tam pokazujemy komunikat o wersji.
          if (isStore && store != null && store['agent_old'] != true && store['direct'] != true)
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.amber), borderRadius: BorderRadius.circular(4)),
                child: const Text('NAT',
                    style: TextStyle(color: AppTheme.amber, fontSize: 10, fontWeight: FontWeight.w600)),
              ),
            ),
          Text(info, style: const TextStyle(color: AppTheme.muted, fontSize: 11, height: 1.35)),
          if (isStore && storeHint != null) Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(storeHint, style: const TextStyle(color: AppTheme.muted, fontSize: 11, height: 1.35)),
          ),
        ]),
        onLongPress: () => _revokeAttachment(deviceId, a, name),
      ),
    );
  }

  String _gbS(dynamic b) => ((num.tryParse('$b') ?? 0) / 1073741824).toStringAsFixed(1);
  String _galuS(dynamic v) => (num.tryParse('$v') ?? 0).toStringAsFixed(2);

  /// Odłączenie przystawki = odebranie jej tokenu. Token właściciela, gdy jest w magazynie
  /// (portfel zostaje zamknięty); inaczej podpis portfela.
  Future<void> _revokeAttachment(String deviceId, Map<String, dynamic> a, String name) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.card,
      title: Text(tr('Odłączyć %s?', [name]), style: const TextStyle(color: AppTheme.text)),
      content: Text(tr('Token przystawki zostanie odebrany, agent natychmiast traci dostęp.'),
          style: const TextStyle(color: AppTheme.muted)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anuluj'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF6666)), child: Text(tr('Odłącz'))),
      ]));
    if (ok != true || !mounted) return;
    try {
      final owner = context.read<CoreBloc>().state.wallet?.address;
      if (owner == null) throw Exception(tr('Brak portfela'));
      final wallet = context.read<WalletService>();
      final body = <String, dynamic>{};
      final tok = await OwnerTokenService().cached(owner);
      if (tok != null) {
        body['owner_token'] = tok;
      } else {
        final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        body['ts'] = ts;
        body['sig'] = await wallet.signMessage('sensmos:attachment:revoke:${a['id']}:$ts');
      }
      final res = await http.delete(Uri.parse('${Config.beUrl}/v1/nodes/$deviceId/attachments/${a['id']}'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode(body)).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw Exception(jsonDecode(res.body)['error'] ?? res.statusCode);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Odłączono'))));
      _fetchBeData(deviceId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: const Color(0xFFFF4444)));
    }
  }

  // ── Storage (na portfel) ──
  Widget _gatewayCard(Map<String, dynamic> g) {
    final id = g['device_id'].toString();
    final eui = (g['gw_eui'] ?? '').toString().toUpperCase();
    final name = (g['gw_name'] ?? '').toString();
    final secs = _beSecs(g);
    final online = g['status'] == 'online';
    final geo = g['geo_state'];
    final st = g['gw_stats'] is Map ? Map<String, dynamic>.from(g['gw_stats']) : null;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.cell_tower, color: AppTheme.teal, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(name.isNotEmpty ? name : eui,
                style: const TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600))),
            Text(online ? tr('online') : (secs == null ? tr('offline') : _ago(secs)),
                style: TextStyle(color: online ? const Color(0xFF2ECC71) : AppTheme.muted, fontSize: 12)),
          ]),
          const SizedBox(height: 4),
          Text('${tr('Brama LoRaWAN')} · $eui · ${id.substring(0, 8)}',
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          const SizedBox(height: 8),
          _gwStat(Icons.place_outlined,
              geo == 'gps' ? tr('Pozycja: wpisana')
                  : geo == 'geoip' ? tr('Pozycja: przybliżona z łącza bramy')
                  : tr('Bez pozycji — brama nie zarabia.'),
              warn: geo != 'gps' && geo != 'geoip'),
          if (st != null) ...[
            _gwStat(Icons.hearing, tr('Słyszy nodów: %s · słyszą ją: %s (24 h)',
                ['${st['hears'] ?? 0}', '${st['heard_by'] ?? 0}'])),
            _gwStat(Icons.graphic_eq, tr('Ramki Sensmos (24 h): %s', ['${st['frames_24h'] ?? 0}'])),
            _gwStat(Icons.wifi_tethering, _beaconLine(st)),
          ],
          _gwStat(Icons.savings_outlined, tr('Zarobek: %s GALU',
              [(double.tryParse('${g['earned_total']}') ?? 0).toStringAsFixed(2)])),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: () async {
                await Navigator.push(context,
                    MaterialPageRoute(builder: (_) => GatewayScreen(existing: g)));
                if (mounted) _fetchMyBeNodes();
              },
              icon: const Icon(Icons.edit_location_alt_outlined, size: 16),
              label: FittedBox(fit: BoxFit.scaleDown, child: Text(tr('Nazwa i pozycja'), maxLines: 1)),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              onPressed: () => _deleteFromNetwork(id),
              icon: const Icon(Icons.link_off, size: 16),
              label: FittedBox(fit: BoxFit.scaleDown, child: Text(tr('Odepnij bramę'), maxLines: 1)),
              style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFFF6666),
                  side: const BorderSide(color: Color(0x55FF6666))),
            )),
          ]),
        ]),
      ),
    );
  }

  Widget _gwStat(IconData icon, String text, {bool warn = false}) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(children: [
          Icon(icon, size: 14, color: warn ? const Color(0xFFFFB020) : AppTheme.muted),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: TextStyle(
              color: warn ? const Color(0xFFFFB020) : AppTheme.muted, fontSize: 12))),
        ]),
      );

  // Ostatni beacon z RAM serwera (po restarcie BE licznik startuje od zera — dlatego czas, nie liczba).
  String _beaconLine(Map<String, dynamic> st) {
    final s = st['last_beacon_s'];
    if (s == null) return tr('Beacon: jeszcze nie nadany');
    final n = num.tryParse('$s') ?? 0;
    var line = n < 60 ? tr('Beacon: przed chwilą') : tr('Beacon: %s temu', [_ago(n)]);
    final ack = st['tx_ack'];
    if (ack != null && ack != 'NONE') line += ' · ${tr('brama odrzuciła (%s)', ['$ack'])}';
    return line;
  }

  Widget _storageCard() {
    final p = _storePkg;
    final has = p?['has_package'] == true;
    final limit = num.tryParse('${p?['limit_b']}') ?? 0, used = num.tryParse('${p?['used_b']}') ?? 0;
    final unpaid = (num.tryParse('${p?['unpaid_days']}') ?? 0).toInt();
    // Cały kafel jest przyciskiem i ZAWSZE prowadzi na ekran — z pakietem do plików, bez pakietu
    // do strony usługi. Wcześniej pytał tu o zakup zanim ktokolwiek zobaczył, czym to jest;
    // decyzja o wydaniu pieniędzy zapada teraz tam, gdzie widać, za co się płaci.
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
      color: AppTheme.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: _openStore,
        borderRadius: BorderRadius.circular(12),
        child: Container(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.sd_storage_outlined, color: AppTheme.teal, size: 20),
          const SizedBox(width: 8),
          const Expanded(child: Text('Storage', style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600))),
          const Icon(Icons.chevron_right, color: AppTheme.muted, size: 20),
          IconButton(icon: const Icon(Icons.close, size: 18, color: AppTheme.muted), tooltip: tr('Ukryj kartę'),
              visualDensity: VisualDensity.compact, onPressed: _hideStoreCard),
        ]),
        if (!has) ...[
          Text(tr('Zobacz, ile miejsca ma sieć'), style: const TextStyle(color: AppTheme.teal, fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text(tr('Miejsce na pliki u innych właścicieli nodów, szyfrowane w telefonie.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
        ] else ...[
          Text(tr('Pakiet %s GB · zajęte %s GB', [_gbS(limit), _gbS(used)]), style: const TextStyle(color: AppTheme.text, fontSize: 13)),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: limit > 0 ? (used / limit).clamp(0, 1).toDouble() : 0,
              color: AppTheme.teal, backgroundColor: AppTheme.surface),
          const SizedBox(height: 6),
          Text(tr('plików: %s · %s GALU na dobę', [p?['files'] ?? 0, _galuS(p?['daily'])]),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          if (unpaid > 0) Padding(padding: const EdgeInsets.only(top: 4),
              child: Text(tr('Zaległość: %s dni — wysyłki wstrzymane, doładuj GALU', [unpaid]),
                  style: const TextStyle(color: AppTheme.amber, fontSize: 12))),
        ],
      ]),
        ),
      ),
      ),
    );
  }

  // Dwa szybkie tapnięcia w kartę otwierały DWA ekrany plików naraz (dwa przyciski „Dodaj plik"
  // z tym samym znacznikiem hero → wyjątek przy animacji, drugi ekran zakładał pakiet od nowa).
  bool _storeOpen = false;
  Future<void> _openStore() async {
    if (_storeOpen) return;
    _storeOpen = true;
    try { await Navigator.push(context, MaterialPageRoute(builder: (_) => const StoreScreen())); }
    finally { _storeOpen = false; }
    _fetchStorePkg();
  }

  /// Zakup dopiero po pytaniu z ceną — samo wejście na ekran plików zakłada pakiet, więc bez
  /// tego pytania tap w kafel kupowałby bez słowa. Cena i wolne miejsce z /v1/store/capacity.
  Future<void> _hideStoreCard() async {
    await StoreCardPref.set(true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Karta ukryta — włączysz ją w Ustawieniach'))));
  }

  Widget _reachBadge(bool localReachable, bool hasLocal) {
    final label = localReachable ? tr('W tej sieci') : tr('Zdalnie');
    final color = localReachable ? AppTheme.teal : AppTheme.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(localReachable ? Icons.wifi : Icons.public, size: 12, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: color)),
      ]),
    );
  }

  // Nagłówek sekcji zawija się zamiast uciekać poza kartę — „SIEĆ LOKALNA (TYLKO W SIECI
  // NODA)" po angielsku jest długie i na wąskim ekranie nie mieści się w jednej linii.
  Widget _groupLabel(IconData icon, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 13, color: AppTheme.muted)),
          const SizedBox(width: 6),
          Expanded(child: Text(text.toUpperCase(),
              style: const TextStyle(color: AppTheme.muted, fontSize: 10.5, letterSpacing: 0.6, fontWeight: FontWeight.w600))),
        ]);

  Widget _localLocked(bool hasLocal, [String? id]) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: AppTheme.muted.withOpacity(0.08), borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.wifi_off, size: 16, color: AppTheme.muted),
            const SizedBox(width: 8),
            Expanded(child: Text(
              hasLocal
                  ? tr('Połącz telefon z siecią WiFi noda, żeby zobaczyć encje i zmienić ustawienia.')
                  : tr('Ten node nie ma zapisanego adresu IP — apka zna go tylko z chmury. '
                       'Połącz telefon z siecią noda i wyszukaj go lokalnie.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12))),
          ]),
          // Typowy przypadek: atestacja poszła po LTE, więc telefon nigdy nie widział
          // noda w LAN i nie było czego zapisać. Sam powrót na WiFi tego nie naprawia —
          // trzeba go raz odnaleźć po mDNS.
          if (!hasLocal && id != null) ...[
            const SizedBox(height: 6),
            SizedBox(width: double.infinity, child: TextButton.icon(
              onPressed: _searching == id ? null : () => _findLocally(id),
              icon: _searching == id
                  ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.teal))
                  : const Icon(Icons.travel_explore, size: 18),
              label: Text(_searching == id
                  ? tr('Szukam w sieci...')
                  : tr('Wyszukaj noda w tej sieci')),
              style: TextButton.styleFrom(foregroundColor: AppTheme.teal),
            )),
          ],
        ]),
      );

  // ── Statystyki globalne ──
  Widget _buildGlobalStats() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppTheme.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: Row(children: [
        _globalStat(Icons.sensors, '$_reportingCount/$_totalNodes', tr('Online')),
        _divider(),
        _globalStat(Icons.location_on_outlined,
            '${_myBeNodes.where((n) => n['located'] == true).length}', tr('Z lokalizacją')),
        _divider(),
        context.read<CoreBloc>().state.wallet == null
            ? _importWalletStat()
            : _globalStat(Icons.account_balance_wallet_outlined,
                _balance ?? _beData.values.firstOrNull?['balance'] ?? '—', tr('GALU saldo'),
                valueColor: const Color(0xFFE89B3F)),
      ]),
    );
  }

  Widget _importWalletStat() => Expanded(child: Column(children: [
        const Icon(Icons.account_balance_wallet_outlined, color: AppTheme.muted, size: 20),
        const SizedBox(height: 4),
        const Text('—', style: TextStyle(color: AppTheme.muted, fontSize: 16, fontWeight: FontWeight.bold)),
        Text(tr('brak portfela'), style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
      ]));

  Widget _noWalletBanner() => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFF4444).withOpacity(0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFF4444).withOpacity(0.35)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.error_outline, color: Color(0xFFFF4444), size: 20),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Aplikacja nie ma przypisanego portfela'),
                style: const TextStyle(color: Color(0xFFFF4444), fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(tr('Zaimportuj go z klucza (zakładka Portfel) albo z noda '
                    '(rozwiń swój node poniżej → Importuj portfel z noda).'),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12.5, height: 1.35)),
          ])),
        ]),
      );

  Widget _globalStat(IconData icon, String value, String label, {Color? valueColor}) =>
      Expanded(child: Column(children: [
        Icon(icon, color: AppTheme.teal, size: 20),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(color: valueColor ?? AppTheme.text, fontSize: 16, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
      ]));

  Widget _divider() => Container(width: 1, height: 40, color: AppTheme.border, margin: const EdgeInsets.symmetric(horizontal: 8));

  Widget _stat(String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
        const SizedBox(height: 2),
        // scaleDown zamiast ucinania: „200.0 km" ma się zmieścić, a nie zamienić w „200…"
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
          child: Text(value, maxLines: 1,
              style: const TextStyle(color: AppTheme.text, fontSize: 14, fontWeight: FontWeight.w500))),
      ]);

  /// Pusty ekran ma DWIE drogi, nie jedną. Sam przycisk „Dodaj node" był ślepym zaułkiem dla
  /// kogoś, kto świadomie wybrał konto bez sprzętu — a od 2026-09-09 taki ktoś może kupić miejsce
  /// na sam adres portfela. Lista jest przewijalna, bo karta Storage z pakietem bywa wysoka.
  ///
  /// A gdy pakiet JUŻ JEST, znika i to: człowiek używa apki do plików, więc „Brak nodów" byłoby
  /// wyrzutem sumienia za decyzję, którą świadomie podjął. Droga do sprzętu nie ginie — „+"
  /// w górnym pasku otwiera dodawanie noda niezależnie od treści ekranu.
  Widget _buildEmpty() {
    if (_storePkg?['has_package'] == true) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [const SizedBox(height: 8), _storageCard()],
      );
    }
    return _buildEmptyChoice();
  }

  Widget _buildEmptyChoice() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 48),
          const Icon(Icons.sensors_off, color: AppTheme.muted, size: 48),
          const SizedBox(height: 16),
          Center(child: Text(tr('Brak nodów'), style: const TextStyle(color: AppTheme.text, fontSize: 16))),
          const SizedBox(height: 8),
          Center(child: Text(tr('Dodaj node przez BLE'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 13))),
          const SizedBox(height: 24),
          Center(child: FilledButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SetupScreen())),
            icon: const Icon(Icons.add),
            label: Text(tr('Dodaj node')),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.teal, foregroundColor: AppTheme.bg),
          )),
          if (!StoreCardPref.hidden.value &&
              context.read<CoreBloc>().state.wallet != null) ...[
            const SizedBox(height: 28),
            Row(children: [
              const Expanded(child: Divider(color: AppTheme.border)),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(tr('albo bez własnego sprzętu'),
                      style: const TextStyle(color: AppTheme.muted, fontSize: 12))),
              const Expanded(child: Divider(color: AppTheme.border)),
            ]),
            _storageCard(),
          ],
        ],
      );
}

class _UnifiedNode {
  final String id;
  final Map<String, dynamic>? be;
  final SavedNode? saved;
  _UnifiedNode({required this.id, this.be, this.saved});
}
