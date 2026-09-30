import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/kom_ble.dart';
import '../../services/kom_chat.dart';

String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Zakładka „Rozmowy”: kontakty z ostatnią wiadomością i „Dodaj kontakt”. Działa bez komunikatora
/// (internet) i z nim (radio).
class KomChatsTab extends StatelessWidget {
  final KomBle kom;
  const KomChatsTab({super.key, required this.kom});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: KomChat.instance,
        builder: (_, __) {
          final chat = KomChat.instance;
          final list = chat.contacts.values.toList()
            ..sort((a, b) => (chat.lastAt('c:${b.id8}') ?? DateTime(0)).compareTo(chat.lastAt('c:${a.id8}') ?? DateTime(0)));
          return ListView(padding: const EdgeInsets.all(16), children: [
            if (chat.me != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(children: [
                  Expanded(child: Text(tr('Twoje ID: %s', [chat.me!.id8]),
                      style: const TextStyle(color: AppTheme.muted, fontSize: 12, fontFamily: 'monospace'))),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16, color: AppTheme.muted),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: chat.me!.id8));
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Skopiowano %s', [chat.me!.id8]))));
                    },
                  ),
                ]),
              ),
            if (chat.me != null)
              Card(child: ListTile(
                leading: const Icon(Icons.badge_outlined, color: AppTheme.teal),
                title: Text(chat.myName.isNotEmpty ? chat.myName : tr('Ustaw swoją nazwę'),
                    style: TextStyle(color: chat.myName.isNotEmpty ? AppTheme.text : AppTheme.amber)),
                subtitle: Text(tr('Moja nazwa — widzą ją inni przy Twoich wiadomościach'),
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                trailing: const Icon(Icons.edit_outlined, size: 18, color: AppTheme.muted),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const KomNameScreen())),
              )),
            if (chat.me != null) const SizedBox(height: 8),
            if (chat.error == 'wallet')
              Text(tr('Odblokuj portfel, żeby uruchomić rozmowy.'), style: const TextStyle(color: AppTheme.amber)),
            if (list.isEmpty && chat.me != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(tr('Brak rozmów. Dodaj kontakt po jego ID albo z listy „W pobliżu”.'),
                    textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.muted, height: 1.4)),
              ),
            for (final c in list) _tile(context, c),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: chat.me == null
                  ? null
                  : () => Navigator.push(context, MaterialPageRoute(builder: (_) => KomContactAdd(kom: kom))),
              icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
              label: Text(tr('Dodaj kontakt'), style: const TextStyle(fontWeight: FontWeight.bold)),
              style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.teal, foregroundColor: AppTheme.bg,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
          ]);
        },
      );

  Widget _tile(BuildContext context, KomContact c) {
    final chat = KomChat.instance;
    final msgs = chat.messages('c:${c.id8}');
    final last = msgs.isEmpty ? null : msgs.last;
    return Card(child: ListTile(
      leading: const Icon(Icons.person_outline, color: AppTheme.teal),
      title: Text(chat.nameOf(c.id8), style: const TextStyle(color: AppTheme.text)),
      subtitle: Text(last == null ? c.id8 : '${last.out ? '› ' : ''}${last.text}',
          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
      trailing: last == null ? null : Text(_hhmm(last.at), style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
      onTap: () => komOpenChat(context, c.id8),
    ));
  }
}

/// Rozmowa z kontaktem; tytuł = jego nazwa (moja albo ta, którą sam sobie nadał).
void komOpenChat(BuildContext context, String id8) => Navigator.push(context, MaterialPageRoute(
    builder: (_) => ListenableBuilder(
          listenable: KomChat.instance,
          builder: (_, __) => KomConversation(conv: 'c:$id8', title: KomChat.instance.nameOf(id8)),
        )));

// Do 10 znaków (polska litera = jeden) i do 20 bajtów — tyle mieści ogłoszenie.
final _nameFmt = [
  FilteringTextInputFormatter.deny(RegExp(r'[\x00-\x1F\x7F-\x9F]')),
  TextInputFormatter.withFunction((o, n) => n.text.runes.length <= 10 && utf8.encode(n.text).length <= 20 ? n : o),
];

/// „Moja nazwa” na pełnym ekranie. Idzie radiem w wiadomościach (do potwierdzenia przez kontakt,
/// w grupie co najwyżej raz na godzinę) i w ogłoszeniu komunikatora.
class KomNameScreen extends StatefulWidget {
  const KomNameScreen({super.key});

  @override
  State<KomNameScreen> createState() => _KomNameScreenState();
}

class _KomNameScreenState extends State<KomNameScreen> {
  final _name = TextEditingController(text: KomChat.instance.myName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await KomChat.instance.setMyName(_name.text.trim());
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('Moja nazwa'))),
        body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
          ListenableBuilder(
            listenable: _name,
            builder: (_, __) => TextField(
              controller: _name,
              autofocus: true,
              style: const TextStyle(color: AppTheme.text),
              inputFormatters: _nameFmt,
              decoration: InputDecoration(
                  labelText: tr('Moja nazwa'), counterText: '${_name.text.runes.length}/10'),
              onSubmitted: (_) => _save(),
            ),
          ),
          const SizedBox(height: 8),
          Text(tr('Najwyżej 10 znaków. Inni widzą ją przy Twoich wiadomościach i na liście „W pobliżu”. Idzie też radiem, bez internetu.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.4)),
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

/// Dodanie kontaktu na pełnym ekranie: ID (8 znaków) → klucz z serwera → nazwa. Podpowiedzi z „W pobliżu”.
class KomContactAdd extends StatefulWidget {
  final KomBle kom;
  const KomContactAdd({super.key, required this.kom});

  @override
  State<KomContactAdd> createState() => _KomContactAddState();
}

class _KomContactAddState extends State<KomContactAdd> {
  final _id = TextEditingController();
  final _name = TextEditingController();
  List<Map<String, dynamic>> _near = [];
  Map<String, dynamic>? _found;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.kom.link.value == KomLink.ready) {
      widget.kom.near().then((l) {
        KomChat.instance.learnNear(l);
        final me = KomChat.instance.me?.id8;
        if (mounted) setState(() => _near = l.where((e) => e['kind'] == 'kom' && e['pub'] is String && e['id8'] != me).toList());
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    final id8 = _id.text.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{8}$').hasMatch(id8)) {
      setState(() => _error = tr('ID to 8 znaków: cyfry 0–9 i litery a–f.'));
      return;
    }
    setState(() { _busy = true; _error = null; _found = null; });
    final r = await KomChat.instance.lookup(id8);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _found = r;
      if (r == null) _error = tr('Nie znaleziono. To ID musi być choć raz w sieci i mieć widoczność „W pobliżu” lub „Na mapie”.');
      if (r != null && _name.text.isEmpty) _name.text = '${r['name'] ?? ''}';
    });
  }

  Future<void> _add() async {
    final f = _found!;
    final own = '${f['name'] ?? ''}', n = _name.text.trim();
    // Nazwa taka sama jak ta, którą ktoś sam sobie nadał, nie jest „moja” — pójdzie za jego zmianą.
    await KomChat.instance.learnName('${f['id8']}', own);
    await KomChat.instance.addContact('${f['id8']}', '${f['pub']}', n == own ? '' : n);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('Dodaj kontakt'))),
        body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            Expanded(child: TextField(
              controller: _id,
              enabled: !_busy,
              style: const TextStyle(color: AppTheme.text, fontFamily: 'monospace'),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')), LengthLimitingTextInputFormatter(8)],
              decoration: InputDecoration(labelText: tr('ID komunikatora'), errorText: _error),
              onSubmitted: (_) => _find(),
            )),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _busy ? null : _find,
              style: FilledButton.styleFrom(backgroundColor: AppTheme.teal, foregroundColor: AppTheme.bg),
              child: Text(tr('Znajdź')),
            ),
          ]),
          if (_near.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(tr('W pobliżu'), style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in _near)
                ActionChip(
                  label: Text('${e['name'] ?? ''}'.isNotEmpty ? '${e['name']} · ${e['id8']}' : '${e['id8']}'),
                  // Klucz przyszedł radiem w ogłoszeniu — serwer niepotrzebny.
                  onPressed: () => setState(() {
                    _id.text = '${e['id8']}';
                    _error = null;
                    _found = e;
                    _name.text = '${e['name'] ?? ''}';
                  }),
                ),
            ]),
          ],
          if (_found != null) ...[
            const SizedBox(height: 24),
            TextField(
              controller: _name,
              style: const TextStyle(color: AppTheme.text),
              inputFormatters: [TextInputFormatter.withFunction((o, n) => utf8.encode(n.text).length <= 32 ? n : o)],
              decoration: InputDecoration(labelText: tr('Nazwa kontaktu')),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _add,
              style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.teal, foregroundColor: AppTheme.bg,
                  padding: const EdgeInsets.symmetric(vertical: 16)),
              child: Text(tr('Dodaj'), style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ])),
      );
}

/// Rozmowa z kontaktem ('c:<id8>') albo w grupie ('g:<gid8>'). Przy każdej wiadomości: 📶 internet
/// albo 📻 radio (ramka przez komunikator), a przy wysłanych do kontaktu: ✓ wysłana, ✓✓ doręczona.
class KomConversation extends StatefulWidget {
  final String conv, title;
  final List<Widget> actions;
  const KomConversation({super.key, required this.conv, required this.title, this.actions = const []});

  @override
  State<KomConversation> createState() => _KomConversationState();
}

class _KomConversationState extends State<KomConversation> {
  static const _maxBytes = 100;
  final _text = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _busy) return;
    setState(() { _busy = true; _error = null; });
    final err = await KomChat.instance.send(widget.conv, t);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      if (err == null) _text.clear();
    });
  }

  // Przy „Zawsze radiem” widać od razu, że komunikator nie jest podłączony — zanim coś się wyśle.
  Widget _radioBar() {
    final chat = KomChat.instance, k = chat.ble;
    if (k == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([chat, k.link]),
      builder: (_, __) => !chat.radioOnly || k.link.value == KomLink.ready
          ? const SizedBox.shrink()
          : Container(
              width: double.infinity,
              color: AppTheme.amber.withValues(alpha: 0.15),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(tr('„Zawsze radiem” — komunikator nie jest podłączony.'),
                  style: const TextStyle(color: AppTheme.amber, fontSize: 13)),
            ),
    );
  }

  Widget _bubble(KomChatMsg m) {
    final chat = KomChat.instance;
    final via = m.via == 'radio'
        ? const Icon(Icons.cell_tower, size: 12, color: AppTheme.muted)
        : const Icon(Icons.wifi, size: 12, color: AppTheme.muted);
    return Align(
      alignment: m.out ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: m.out ? AppTheme.teal.withValues(alpha: 0.10) : AppTheme.card,
          borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(12), topRight: const Radius.circular(12),
              bottomLeft: Radius.circular(m.out ? 12 : 3), bottomRight: Radius.circular(m.out ? 3 : 12)),
          border: Border.all(color: m.out ? AppTheme.teal.withValues(alpha: 0.35) : AppTheme.border),
        ),
        child: Column(
            crossAxisAlignment: m.out ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!m.out && m.from != null)
                Text(chat.nameOf(m.from!), style: const TextStyle(color: AppTheme.teal, fontSize: 11)),
              Text(m.text, style: const TextStyle(color: AppTheme.text, fontSize: 14, height: 1.35)),
              const SizedBox(height: 4),
              Row(mainAxisSize: MainAxisSize.min, children: [
                via,
                const SizedBox(width: 4),
                Text(_hhmm(m.at), style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                if (m.out && widget.conv.startsWith('c:')) ...[
                  const SizedBox(width: 4),
                  Icon(m.status == 'delivered' ? Icons.done_all : Icons.done,
                      size: 13, color: m.status == 'delivered' ? AppTheme.teal : AppTheme.muted),
                ],
              ]),
            ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title), actions: widget.actions),
        body: Column(children: [
          _radioBar(),
          Expanded(child: ListenableBuilder(
            listenable: KomChat.instance,
            builder: (_, __) {
              final list = KomChat.instance.messages(widget.conv).reversed.toList();
              return list.isEmpty
                  ? Center(child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(tr('Brak wiadomości.'), style: const TextStyle(color: AppTheme.muted))))
                  : ListView.builder(
                      reverse: true,
                      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      itemCount: list.length,
                      itemBuilder: (_, i) => _bubble(list[i]),
                    );
            },
          )),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(_error!, style: const TextStyle(color: AppTheme.red, fontSize: 13)),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
            decoration: const BoxDecoration(color: AppTheme.surface, border: Border(top: BorderSide(color: AppTheme.border))),
            child: Row(children: [
              Expanded(child: TextField(
                controller: _text,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _send(),
                inputFormatters: [
                  FilteringTextInputFormatter.deny(RegExp(r'[\x00-\x1F\x7F-\x9F]')),
                  TextInputFormatter.withFunction((old, nw) => utf8.encode(nw.text).length <= _maxBytes ? nw : old),
                ],
                style: const TextStyle(color: AppTheme.text),
                decoration: InputDecoration(
                  hintText: tr('Wiadomość'),
                  counterText: '${utf8.encode(_text.text).length}/$_maxBytes',
                  isDense: true,
                  filled: true,
                  fillColor: AppTheme.card,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppTheme.border)),
                ),
              )),
              IconButton(
                onPressed: !_busy && _text.text.trim().isNotEmpty ? _send : null,
                color: AppTheme.teal,
                icon: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send),
              ),
            ]),
          ),
        ]),
      );
}
