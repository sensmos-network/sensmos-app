import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'theme.dart';
import 'config.dart';
import 'l10n.dart';
import 'core/core_bloc.dart';
import 'services/push_service.dart';
import 'services/wallet_service.dart';
import 'util/owner_token_gate.dart';
import 'screens/nodes/nodes_screen.dart';
import 'screens/kom/kom_screen.dart';
import 'services/node_service.dart';
import 'screens/wallet/wallet_screen.dart';
import 'screens/settings/settings_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override State<AppShell> createState() => _AppShellState();
}

/// Czy dzwonek ze skrzynki jest teraz na ekranie. AppShell rysuje go jako overlay w prawym
/// górnym rogu — NAD paskiem każdej zakładki — więc paski muszą wiedzieć, kiedy zostawić mu
/// miejsce. Bez tego siadał na przyciskach paska i przykrył „+" dodawania noda.
final ValueNotifier<bool> inboxBellVisible = ValueNotifier(false);

/// Pusty slot na końcu `actions:` paska — szeroki tylko wtedy, gdy dzwonek jest widoczny.
class InboxBellSlot extends StatelessWidget {
  const InboxBellSlot({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
      valueListenable: inboxBellVisible,
      builder: (_, on, __) => SizedBox(width: on ? 44 : 0));
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _index = 0;
  StreamSubscription? _fcmSub;
  Timer? _refetch;
  // Skrzynka powiadomień — źródło prawdy w BE (2026-09-01): historia składana lokalnie
  // z FCM gubiła pushe odebrane w tle (Android oddaje je tylko do zasobnika systemu).
  // BE loguje każdą wysyłkę, apka pobiera GET-em; lokalnie tylko cache (offline),
  // znacznik „ostatnio widziane" (licznik) i „wyczyszczone przed" (przycisk Wyczyść).
  List<Map<String, dynamic>> _inbox = [];
  int _seenTs = 0;
  int _hideBefore = 0;

  int get _unread => _inbox.where((n) => ((n['ts'] ?? 0) as num) > _seenTs).length;

  /// Pushe mogłyby działać (jest token FCM), ale rejestracja w BE nie przeszła. Brak
  /// tokenu FCM to nie awaria, tylko telefon bez usług Google — nie ma czego naprawiać.
  bool get _pushBroken {
    final p = context.read<PushService>();
    return (p.token ?? '').isNotEmpty && !p.registered;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadLocal().then((_) => _fetchInbox());
    // Po wejściu do panelu zarejestruj token FCM w BE podpisem walleta (fire-and-forget).
    // Przebudowa 2026-08-24: tokeny mieszkają w BE, nie na nodach — dzięki temu BE umie
    // powiadomić także o MARTWYM nodzie (LoRa awaryjne), a rotacja tokenu nie wymaga LAN.
    final push = context.read<PushService>();
    final wallet = context.read<WalletService>();
    push.init().then((t) async {
      if (t == null) return;
      await push.registerToBackend(wallet);
      if (mounted) setState(() {});   // status w dzwonku zależy od wyniku
    });
    try {
      _fcmSub = FirebaseMessaging.onMessage.listen((_) => _fetchInbox());
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fcmSub?.cancel();
    _refetch?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _fetchInbox();
  }

  Future<void> _loadLocal() async {
    try {
      final p = await SharedPreferences.getInstance();
      _seenTs = p.getInt('push_seen_ts') ?? 0;
      _hideBefore = p.getInt('push_hide_before') ?? 0;
      final raw = p.getString('push_inbox_cache');
      if (raw != null) {
        _inbox = List<Map<String, dynamic>>.from(jsonDecode(raw));
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _saveLocal() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('push_seen_ts', _seenTs);
      await p.setInt('push_hide_before', _hideBefore);
      await p.setString('push_inbox_cache', jsonEncode(_inbox));
    } catch (_) {}
  }

  Future<void> _fetchInbox() async {
    final owner = context.read<CoreBloc>().state.wallet?.address;
    if (owner == null) return;
    try {
      final res = await http.get(
        Uri.parse('${Config.beUrl}/v1/nodes/push-inbox?owner=$owner'),
        headers: {'X-App-Key': Config.appKey},
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final items = List<Map<String, dynamic>>.from(
          (jsonDecode(res.body) as Map)['items'] ?? []);
      if (!mounted) return;
      setState(() {
        _inbox = items.where((n) => ((n['ts'] ?? 0) as num) > _hideBefore).toList();
      });
      _saveLocal();
    } catch (_) {}
  }

  String _agoTs(int ts) {
    final s = (DateTime.now().millisecondsSinceEpoch - ts) ~/ 1000;
    if (s < 60) return tr('przed chwilą');
    if (s < 3600) return '${s ~/ 60}m';
    if (s < 86400) return '${s ~/ 3600}h';
    return '${s ~/ 86400}d';
  }

  void _openInbox() {
    setState(() => _seenTs = DateTime.now().millisecondsSinceEpoch);
    _saveLocal();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
            child: Row(children: [
              const Icon(Icons.notifications, color: AppTheme.teal, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(tr('Powiadomienia'),
                    style: const TextStyle(
                        color: AppTheme.text, fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              if (_inbox.isNotEmpty)
                TextButton(
                  onPressed: () {
                    setState(() {
                      _hideBefore = DateTime.now().millisecondsSinceEpoch;
                      _inbox.clear();
                    });
                    _saveLocal();
                    Navigator.pop(ctx);
                  },
                  child: Text(tr('Wyczyść'),
                      style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                ),
            ]),
          ),
          if (_inbox.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(tr('Brak powiadomień'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                itemCount: _inbox.length,
                separatorBuilder: (_, __) => const Divider(color: AppTheme.border, height: 12),
                itemBuilder: (_, i) {
                  final n = _inbox[i];
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                        child: Text(n['t'] ?? '',
                            style: const TextStyle(
                                color: AppTheme.text, fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                      Text(_agoTs(n['ts'] ?? 0),
                          style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                    ]),
                    if ((n['b'] ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(n['b'],
                            style: const TextStyle(
                                color: AppTheme.muted, fontSize: 12, height: 1.4)),
                      ),
                  ]);
                },
              ),
            ),
          StatefulBuilder(builder: (_, setSheet) => _pushStatusRow(setSheet)),
        ]),
      ),
    );
  }

  /// Stan rejestracji pushy — jedyne miejsce w apce, gdzie to widać (osobny ekran w
  /// Ustawieniach wycięty 2026-09-04: rejestracja jest automatyczna, a kiedy padnie,
  /// informacja ma być tam, gdzie user szuka powiadomień, a nie w ustawieniach).
  Widget _pushStatusRow(StateSetter setSheet) {
    final push = context.read<PushService>();
    if ((push.token ?? '').isEmpty) return const SizedBox.shrink();
    final ok = push.registered;
    return InkWell(
      onTap: ok
          ? null
          : () async {
              final messenger = ScaffoldMessenger.of(context);
              final wallet = context.read<WalletService>();
              final w = await wallet.load();
              if (w == null || !mounted) return;
              // Pyta o hasło portfela najwyżej raz — potem token ownera wystarcza.
              await ensureOwnerToken(context, w.address, label: 'Ten telefon');
              final done = await push.registerToBackend(wallet);
              setSheet(() {});
              if (!mounted) return;
              setState(() {});
              if (!done) {
                messenger.showSnackBar(SnackBar(
                    content: Text(tr('Nie udało się włączyć powiadomień.'))));
              }
            },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              color: ok ? AppTheme.teal : AppTheme.amber, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                ok
                    ? tr('Powiadomienia aktywne')
                    : tr('Nieaktywne — dotknij, aby włączyć'),
                style: TextStyle(
                    color: ok ? AppTheme.muted : AppTheme.amber, fontSize: 12)),
          ),
        ]),
      ),
    );
  }

  final _screens = const [
    NodesScreen(),
    KomScreen(),
    WalletScreen(),
    SettingsScreen(),
  ];

  /// Pierwsza zakładka nazywa się „Nody" tylko wtedy, gdy jakieś są. Konto założone drogą
  /// „tylko portfel" ma tam wyłącznie Storage, a podpis obiecujący nody był po prostu nieprawdą.
  List<(IconData, IconData, String)> _items(bool hasNodes) => [
    hasNodes
        ? (Icons.sensors_outlined, Icons.sensors, 'Nody')
        : (Icons.home_outlined, Icons.home, 'Start'),
    (Icons.forum_outlined, Icons.forum, 'Komunikator'),
    (Icons.account_balance_wallet_outlined, Icons.account_balance_wallet, 'Portfel'),
    (Icons.settings_outlined, Icons.settings, 'Ustawienia'),
  ];

  @override
  Widget build(BuildContext context) {
    final bell = _unread > 0 || _inbox.isNotEmpty || _pushBroken;
    // Po klatce, bo paski zakładek słuchają tej wartości i przebudowa w trakcie budowania
    // wywala framework.
    if (inboxBellVisible.value != bell) {
      WidgetsBinding.instance.addPostFrameCallback((_) => inboxBellVisible.value = bell);
    }
    return Scaffold(
      body: Stack(children: [
        IndexedStack(index: _index, children: _screens),
        // Dzwoneczek na wierzchu — teal z licznikiem gdy są nieprzeczytane, przygaszony
        // gdy skrzynka ma tylko przeczytane; klik = skrzynka z treściami. Pokazujemy go
        // także przy zerwanej rejestracji, bo inaczej user z pustą skrzynką nie miałby
        // gdzie zobaczyć, że pushy nie ma (tak właśnie przepadły niezauważone).
        if (bell)
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 12,
            child: Material(
              color: AppTheme.card,
              shape: CircleBorder(side: BorderSide(
                  color: _unread > 0 ? AppTheme.teal : AppTheme.border, width: 1)),
              elevation: 6,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _openInbox,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Stack(clipBehavior: Clip.none, children: [
                    Icon(_unread > 0 ? Icons.notifications_active : Icons.notifications_none,
                        color: _unread > 0 ? AppTheme.teal : AppTheme.muted, size: 22),
                    if (_unread > 0)
                      Positioned(
                        right: -4, top: -4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                              color: AppTheme.red, borderRadius: BorderRadius.circular(8)),
                          child: Text('$_unread',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
          ),
      ]),
      // Własny pasek zamiast NavigationBar: tamten rysuje etykietę bez limitu linii i resetuje
      // DefaultTextStyle w swoim Material, więc „Communicator” łamał się na dwie linie. Tu etykieta
      // ma jedną linię z wielokropkiem, czcionka bez zmian; wygląd jak Material 3 (pastylka pod ikoną).
      bottomNavigationBar: _BottomBar(
        items: _items(context.watch<NodeService>().nodes.isNotEmpty),
        index: _index,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final List<(IconData, IconData, String)> items;
  final int index;
  final ValueChanged<int> onTap;
  const _BottomBar({required this.items, required this.index, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: AppTheme.surface,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 80,
            child: Row(children: [
              for (var i = 0; i < items.length; i++)
                Expanded(child: InkWell(
                  onTap: () => onTap(i),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 64, height: 32,
                      decoration: BoxDecoration(
                        color: i == index ? AppTheme.teal.withValues(alpha: 0.15) : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      alignment: Alignment.center,
                      child: Icon(i == index ? items[i].$2 : items[i].$1, color: i == index ? AppTheme.teal : AppTheme.muted),
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(tr(items[i].$3),
                          maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                              color: i == index ? AppTheme.text : AppTheme.muted)),
                    ),
                  ]),
                )),
            ]),
          ),
        ),
      );
}
