import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointycastle/export.dart' show HMac, PBKDF2KeyDerivator, Pbkdf2Parameters, SHA256Digest;
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/kom_chat.dart';
import 'kom_chats.dart';

/// Klucz grupy: wylosowany („sg1.” + 32 B base64url) albo dowolne hasło (PBKDF2, 100 000 rund —
/// ten sam tekst daje ten sam klucz na każdym telefonie). Klucz zna tylko apka (i ludzie, którym
/// go dałeś); serwer dostaje odcisk.
String komGroupKeyNew() {
  final r = Random.secure();
  return 'sg1.${base64Url.encode(List.generate(32, (_) => r.nextInt(256))).replaceAll('=', '')}';
}

Uint8List _pbkdf2(String phrase) {
  final d = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(Uint8List.fromList(utf8.encode('sensmos-grp-v1')), 100000, 32));
  return d.process(Uint8List.fromList(utf8.encode(phrase)));
}

Future<Uint8List> komGroupKey(String text) async {
  final t = text.trim();
  if (t.startsWith('sg1.')) {
    try {
      final b = base64Url.decode(base64Url.normalize(t.substring(4)));
      if (b.length == 32) return Uint8List.fromList(b);
    } catch (_) {}
  }
  return compute(_pbkdf2, t);
}

/// Zakładka „Grupy”: grupy tej apki (do 8). Działają przez internet i przez podłączony komunikator.
class KomGroupsTab extends StatelessWidget {
  const KomGroupsTab({super.key});

  static const max = 8;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: KomChat.instance,
        builder: (_, __) {
          final chat = KomChat.instance;
          final list = chat.groups.values.toList();
          return ListView(padding: const EdgeInsets.all(16), children: [
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                    tr('Brak grup. Grupa to wspólny klucz: kto go ma, pisze i czyta. Klucz przekazujesz sam — domownikom, znajomym, na Discordzie.'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppTheme.muted, height: 1.4)),
              ),
            for (final g in list)
              Card(child: ListTile(
                leading: const Icon(Icons.groups_outlined, color: AppTheme.teal),
                title: Text(g.name.isNotEmpty ? g.name : tr('Grupa'), style: const TextStyle(color: AppTheme.text)),
                subtitle: Text('${tr('odcisk')} ${g.gid8}', style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                trailing: const Icon(Icons.chevron_right, color: AppTheme.muted),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => KomGroupChat(group: g))),
              )),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: chat.me != null && list.length < max
                  ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => const KomGroupNew()))
                  : null,
              icon: const Icon(Icons.group_add_outlined, size: 18),
              label: Text(list.length < max ? tr('Nowa grupa') : tr('Masz już %s grup', [max]),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.teal, foregroundColor: AppTheme.bg,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
          ]);
        },
      );
}

/// Nowa grupa na pełnym ekranie: nazwa (tylko dla Ciebie) i klucz — wylosowany albo wklejony.
class KomGroupNew extends StatefulWidget {
  const KomGroupNew({super.key});

  @override
  State<KomGroupNew> createState() => _KomGroupNewState();
}

class _KomGroupNewState extends State<KomGroupNew> {
  final _name = TextEditingController();
  final _key = TextEditingController(text: komGroupKeyNew());
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final k = _key.text.trim();
    if (k.length < 8) {
      setState(() => _error = tr('Klucz musi mieć co najmniej 8 znaków. Najlepiej wylosuj go.'));
      return;
    }
    setState(() { _busy = true; _error = null; });
    await KomChat.instance.addGroup(await komGroupKey(k), k, _name.text.trim());
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('Nowa grupa'))),
        body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            controller: _name,
            enabled: !_busy,
            style: const TextStyle(color: AppTheme.text),
            inputFormatters: _groupNameFmt,
            decoration: InputDecoration(labelText: tr('Nazwa (widzisz ją tylko Ty)')),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _key,
            enabled: !_busy,
            style: const TextStyle(color: AppTheme.text, fontFamily: 'monospace', fontSize: 13),
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(labelText: tr('Klucz grupy'), errorText: _error),
          ),
          const SizedBox(height: 8),
          Row(children: [
            TextButton.icon(
              onPressed: _busy ? null : () => setState(() => _key.text = komGroupKeyNew()),
              icon: const Icon(Icons.casino_outlined, size: 18),
              label: Text(tr('Wylosuj')),
            ),
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _key.text.trim()));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Klucz skopiowany'))));
              },
              icon: const Icon(Icons.copy, size: 18),
              label: Text(tr('Kopiuj')),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
              tr('Kto ma ten sam klucz, jest w tej grupie — przekaż go sam (domownikom, znajomym, na Discordzie). Możesz też wkleić klucz, który ktoś Ci dał. Serwer Sensmos dostaje tylko odcisk klucza, nie klucz.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.4)),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.teal, foregroundColor: AppTheme.bg,
                padding: const EdgeInsets.symmetric(vertical: 16)),
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(tr('Zapisz grupę'), style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ])),
      );
}

final _groupNameFmt = [
  FilteringTextInputFormatter.deny(RegExp(r'[\x00-\x1F\x7F-\x9F]')),
  TextInputFormatter.withFunction((old, nw) => utf8.encode(nw.text).length <= 32 ? nw : old),
];

/// Zmiana nazwy grupy na pełnym ekranie. Nazwa jest tylko w tym telefonie — klucz się nie zmienia.
class KomGroupRename extends StatefulWidget {
  final KomGroupDef group;
  const KomGroupRename({super.key, required this.group});

  @override
  State<KomGroupRename> createState() => _KomGroupRenameState();
}

class _KomGroupRenameState extends State<KomGroupRename> {
  late final _name = TextEditingController(text: widget.group.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await KomChat.instance.renameGroup(widget.group.gid8, _name.text.trim());
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('Zmień nazwę'))),
        body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            controller: _name,
            autofocus: true,
            style: const TextStyle(color: AppTheme.text),
            inputFormatters: _groupNameFmt,
            decoration: InputDecoration(labelText: tr('Nazwa (widzisz ją tylko Ty)')),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.teal, foregroundColor: AppTheme.bg,
                padding: const EdgeInsets.symmetric(vertical: 16)),
            child: Text(tr('Zapisz'), style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ])),
      );
}

/// Rozmowa w grupie + zmiana nazwy + klucz do ponownego przekazania + usunięcie (drugim stuknięciem).
class KomGroupChat extends StatefulWidget {
  final KomGroupDef group;
  const KomGroupChat({super.key, required this.group});

  @override
  State<KomGroupChat> createState() => _KomGroupChatState();
}

class _KomGroupChatState extends State<KomGroupChat> {
  bool _confirm = false;
  Timer? _t;

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _delete() async {
    if (!_confirm) {
      setState(() => _confirm = true);
      _t = Timer(const Duration(seconds: 4), () { if (mounted) setState(() => _confirm = false); });
      return;
    }
    _t?.cancel();
    await KomChat.instance.removeGroup(widget.group.gid8);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: KomChat.instance, builder: (_, __) => _chat());

  Widget _chat() {
    final g = widget.group;
    return KomConversation(
      conv: 'g:${g.gid8}',
      title: g.name.isNotEmpty ? g.name : tr('Grupa'),
      actions: [
        IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: tr('Zmień nazwę'),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => KomGroupRename(group: g))),
        ),
        IconButton(
          icon: const Icon(Icons.key_outlined),
          tooltip: tr('Kopiuj klucz grupy'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: g.keyText));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Klucz skopiowany'))));
          },
        ),
        TextButton(
          onPressed: _delete,
          child: Text(_confirm ? tr('Na pewno?') : tr('Usuń'),
              style: TextStyle(color: _confirm ? AppTheme.red : AppTheme.muted)),
        ),
      ],
    );
  }
}
