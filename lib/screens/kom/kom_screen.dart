import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import '../../theme.dart';
import '../../config.dart';
import '../../l10n.dart';
import '../../log.dart';
import '../../app_shell.dart';
import '../../core/core_bloc.dart';
import '../../services/kom_ble.dart';
import '../../services/kom_chat.dart';
import '../../services/wallet_service.dart';
import '../nodes/ldev_chat_screen.dart';
import 'kom_add_screen.dart';
import 'kom_chats.dart';
import 'kom_device.dart';
import 'kom_groups.dart';
import 'kom_near.dart';
import 'kom_pin_screen.dart';

/// Zakładka „Komunikator”: Rozmowy, Grupy, W pobliżu, Urządzenie. Rozmowy i grupy działają przez
/// internet także bez komunikatora; podłączony komunikator (BLE) dokłada radio.
class KomScreen extends StatefulWidget {
  const KomScreen({super.key});

  @override
  State<KomScreen> createState() => _KomScreenState();
}

class _KomScreenState extends State<KomScreen> {
  final _kom = KomBle();
  List<Map<String, dynamic>> _ldevs = [];
  bool _ldevBusy = false;
  String? _confirm;                       // id8, przy którym „Odepnij” czeka na drugie stuknięcie
  Timer? _confirmT;

  @override
  void initState() {
    super.initState();
    _kom.load();
    _fetchLdevs();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) KomChat.instance.start(context.read<WalletService>(), _kom);
    });
  }

  @override
  void dispose() {
    _confirmT?.cancel();
    _kom.dispose();
    super.dispose();
  }

  Future<void> _unpin(String id8) async {
    if (_confirm != id8) {
      _confirmT?.cancel();
      setState(() => _confirm = id8);
      _confirmT = Timer(const Duration(seconds: 4), () { if (mounted) setState(() => _confirm = null); });
      return;
    }
    _confirmT?.cancel();
    setState(() => _confirm = null);
    final err = await komUnpin(context, id8);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    await _fetchLdevs();
  }

  // Lista wymaga podpisu, więc tylko przy starcie i odświeżeniu, bez pollingu. Portfel
  // zablokowany albo błąd → zostaje to, co było (na starcie pusto, sekcji nie widać).
  Future<void> _fetchLdevs() async {
    final owner = context.read<CoreBloc>().state.wallet?.address.toLowerCase();
    if (owner == null || _ldevBusy) return;
    final wallet = context.read<WalletService>();
    _ldevBusy = true;
    try {
      if (!await wallet.isUnlocked()) return;
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final sig = await wallet.signMessage('sensmos:ownertoken:ldev_mine:$ts');
      final res = await http.post(
        Uri.parse('${Config.beUrl}/v1/ldev/mine'),
        headers: const {'Content-Type': 'application/json', 'X-App-Key': Config.appKey},
        body: jsonEncode({'owner': owner, 'ts': ts, 'sig': sig}),
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final list = List<Map<String, dynamic>>.from(j['devices'] ?? []);
      if (mounted) setState(() => _ldevs = list);
    } catch (e) {
      Log.w('kom', 'ldev/mine: $e');
    } finally {
      _ldevBusy = false;
    }
  }

  Future<void> _refresh() async {
    await Future.wait([
      _fetchLdevs(),
      if (_kom.link.value == KomLink.ready) _kom.refreshInfo().catchError((_) {}),
    ]);
  }

  Widget _ldevCard(Map<String, dynamic> d) {
    final id8 = '${d['id8']}';
    final name = (d['name'] ?? '').toString().trim();
    final heard = ((d['heard'] as List?) ?? const []).map((e) => '$e').toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: const Icon(Icons.sensors, color: AppTheme.teal),
        title: Text(name.isNotEmpty ? name : id8,
            style: const TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600)),
        subtitle: Text('${tr('Urządzenie LoRa')} · $id8 · ${tr('słyszą: %s',
                [heard.isEmpty ? tr('nikt w ostatnich 6 h') : heard.join(', ')])}',
            style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
        trailing: TextButton(
          onPressed: () => _unpin(id8),
          child: Text(_confirm == id8 ? tr('Na pewno?') : tr('Odepnij'),
              style: TextStyle(color: _confirm == id8 ? AppTheme.red : AppTheme.muted, fontSize: 12)),
        ),
        onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => LdevChatScreen(id8: id8, name: name.isNotEmpty ? name : null))),
      ),
    );
  }

  Widget _internet() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_ldevs.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text(tr('Na koncie'),
                style: const TextStyle(color: AppTheme.text, fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          ..._ldevs.map(_ldevCard),
        ],
      ]);

  AppBar _appBar({PreferredSizeWidget? bottom}) => AppBar(
        title: Text(tr('Komunikator')),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh, tooltip: tr('Odśwież')),
          const InboxBellSlot(),
        ],
        bottom: bottom,
      );

  Widget _addView() => RefreshIndicator(
          onRefresh: _refresh,
          color: AppTheme.teal,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const SizedBox(height: 16),
            const Icon(Icons.forum_outlined, size: 56, color: AppTheme.teal),
            const SizedBox(height: 16),
            Text(tr('Dodaj swój komunikator'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.text, fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Text(tr('Komunikator łączy się z telefonem przez Bluetooth. Telefon jest ekranem i klawiaturą, a komunikator wysyła i odbiera wiadomości radiem.'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.4)),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => KomAddScreen(kom: _kom))),
              icon: const Icon(Icons.bluetooth_searching, size: 18),
              label: Text(tr('Dodaj komunikator'), style: const TextStyle(fontWeight: FontWeight.bold)),
              style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.teal,
                  foregroundColor: AppTheme.bg,
                  padding: const EdgeInsets.symmetric(vertical: 16)),
            ),
            const SizedBox(height: 24),
            _internet(),
          ]),
        );

  Widget _linkBar(KomSaved s) => ValueListenableBuilder<KomLink>(
        valueListenable: _kom.link,
        builder: (_, l, __) {
          final (text, color) = switch (l) {
            KomLink.ready      => (tr('Podłączony'), AppTheme.teal),
            KomLink.connecting => (tr('Łączę z komunikatorem…'), AppTheme.muted),
            KomLink.pin        => (tr('Podaj PIN ›'), AppTheme.amber),
            _                  => (tr('Brak połączenia — łączę ponownie…'), AppTheme.amber),
          };
          final bar = Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            decoration: const BoxDecoration(
                color: AppTheme.surface, border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: Row(children: [
              Icon(l == KomLink.ready ? Icons.bluetooth_connected : Icons.bluetooth_disabled, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(s.name.isNotEmpty ? s.name : s.id8,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600))),
              Text(text, style: TextStyle(color: color, fontSize: 12)),
            ]),
          );
          return l != KomLink.pin
              ? bar
              : InkWell(
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => KomPinScreen(kom: _kom))),
                  child: bar);
        },
      );

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<KomSaved?>(
        valueListenable: _kom.saved,
        builder: (_, s, __) => DefaultTabController(
          length: 4,
          child: Scaffold(
            appBar: _appBar(bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
              Tab(text: tr('Rozmowy')), Tab(text: tr('Grupy')), Tab(text: tr('W pobliżu')), Tab(text: tr('Urządzenie')),
            ])),
            body: Column(children: [
              if (s != null) _linkBar(s),
              Expanded(child: TabBarView(children: [
                KomChatsTab(kom: _kom),
                const KomGroupsTab(),
                KomNearList(kom: _kom),
                s == null ? _addView() : KomDevice(kom: _kom, onPaired: _fetchLdevs, footer: _internet()),
              ])),
            ]),
          ),
        ),
      );
}
