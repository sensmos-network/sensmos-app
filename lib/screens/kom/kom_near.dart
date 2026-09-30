import 'dart:async';
import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/kom_ble.dart';
import '../../services/kom_chat.dart';
import 'kom_chats.dart';

/// „W pobliżu”: kogo komunikator słyszy na 869.525 — ludzi (komunikator ogłasza apkę, która się
/// z nim łączy: ID, klucz, nazwa; stuknięcie otwiera rozmowę), komunikatory bez właściciela oraz
/// bramy i nody Sensmos (rzadkie ogłoszenia z serwera). Odświeżane co 10 s.
class KomNearList extends StatefulWidget {
  final KomBle kom;
  const KomNearList({super.key, required this.kom});

  @override
  State<KomNearList> createState() => _KomNearListState();
}

class _KomNearListState extends State<KomNearList> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _items = [];
  bool _loaded = false;
  Timer? _t;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.kom.link.addListener(_load);
    _load();
    _t = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    widget.kom.link.removeListener(_load);
    _t?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.kom.link.value != KomLink.ready) return;
    try {
      final me = KomChat.instance.me?.id8;
      final list = (await widget.kom.near()).where((e) => e['id8'] != me).toList();
      KomChat.instance.learnNear(list);
      list.sort((a, b) => ((a['ago_s'] as num?) ?? 0).compareTo((b['ago_s'] as num?) ?? 0));
      if (mounted) setState(() { _items = list; _loaded = true; });
    } catch (_) {}
  }

  String _ago(num s) => s < 60
      ? tr('przed chwilą')
      : s < 3600 ? tr('%s min temu', [s ~/ 60]) : tr('%s h temu', [s ~/ 3600]);

  // Rozmowa od razu: klucz przyszedł radiem w ogłoszeniu, więc kontakt dodaje się bez serwera.
  Future<void> _open(String id8, String pub) async {
    final chat = KomChat.instance;
    if (!chat.contacts.containsKey(id8)) await chat.addContact(id8, pub, '');
    if (mounted) komOpenChat(context, id8);
  }

  Widget _tile(Map<String, dynamic> e) {
    final kind = '${e['kind']}', id8 = '${e['id8']}';
    final name = '${e['name'] ?? ''}';
    final pub = e['pub'];
    final person = kind == 'kom' && pub is String;
    final (icon, label) = switch (kind) {
      'gw'   => (Icons.cell_tower, tr('Brama Sensmos')),
      'node' => (Icons.sensors, tr('Nod Sensmos')),
      _      => person ? (Icons.person_outline, 'ID') : (Icons.forum_outlined, tr('Komunikator bez właściciela')),
    };
    return Card(child: ListTile(
      leading: Icon(icon, color: person ? AppTheme.teal : AppTheme.muted),
      title: Text(person ? KomChat.instance.nameOf(id8) : name.isNotEmpty ? name : id8,
          style: const TextStyle(color: AppTheme.text)),
      subtitle: Text('$label $id8 · ${e['rssi']} dBm · ${_ago((e['ago_s'] as num?) ?? 0)}',
          style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
      trailing: person ? const Icon(Icons.chat_bubble_outline, size: 18, color: AppTheme.teal) : null,
      onTap: person ? () => _open(id8, pub) : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return RefreshIndicator(
      onRefresh: _load,
      color: AppTheme.teal,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        if (_items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
                widget.kom.link.value != KomLink.ready
                    ? tr('Podłącz komunikator, żeby zobaczyć, kto jest w pobliżu.')
                    : _loaded
                        ? tr('Na razie nikogo. Komunikatory ogłaszają się co kilkanaście minut, bramy i nody co pół godziny.')
                        : tr('Łączę z komunikatorem…'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.muted, height: 1.4)),
          ),
        ..._items.map(_tile),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: widget.kom.link.value == KomLink.ready
              ? () => widget.kom.request('hello').catchError((_) => <String, dynamic>{})
              : null,
          icon: const Icon(Icons.campaign_outlined, size: 18),
          label: Text(tr('Ogłoś się teraz')),
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
        ),
      ]),
    );
  }
}
