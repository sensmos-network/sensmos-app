import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import '../../theme.dart';
import '../../config.dart';
import '../../l10n.dart';
import '../../core/core_bloc.dart';
import '../../services/wallet_service.dart';

/// Wiadomość tekstowa do sparowanego urządzenia LoRa (komunikatora). BE kolejkuje ją i nadaje
/// przez bramę Sensmos, która słyszy urządzenie; apka tylko odpytuje stan doręczenia.
/// Lista żyje wyłącznie w tej sesji ekranu — odpowiedzi urządzenia trafiają do inboxu.
class LdevChatScreen extends StatefulWidget {
  final String id8;
  final String? name;
  const LdevChatScreen({super.key, required this.id8, this.name});

  @override
  State<LdevChatScreen> createState() => _LdevChatScreenState();
}

class _Msg {
  final String id, text;
  final DateTime at;
  String state = 'queued';
  _Msg(this.id, this.text, this.at);
}

class _LdevChatScreenState extends State<LdevChatScreen> {
  static const _headers = {'Content-Type': 'application/json', 'X-App-Key': Config.appKey};
  static const _maxBytes = 100;
  static const _pollFor = Duration(minutes: 10);
  static const _errColor = Color(0xFFFF6666);
  final _text = TextEditingController();
  final List<_Msg> _msgs = [];
  bool _busy = false, _polling = false;
  String? _error;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    _text.dispose();
    super.dispose();
  }

  bool _done(String s) => s == 'delivered' || s == 'failed';

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _busy) return;
    final owner = context.read<CoreBloc>().state.wallet?.address.toLowerCase();
    if (owner == null) { setState(() => _error = tr('Brak portfela')); return; }
    final wallet = context.read<WalletService>();
    setState(() { _busy = true; _error = null; });
    try {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final hash = sha256.convert(utf8.encode(text)).toString();
      final sig = await wallet.signMessage('sensmos:ownertoken:ldev_send:$ts:${widget.id8}:$hash');
      final res = await http.post(
        Uri.parse('${Config.beUrl}/v1/ldev/send'),
        headers: _headers,
        body: jsonEncode({'owner': owner, 'ts': ts, 'sig': sig, 'id8': widget.id8, 'text': text}),
      ).timeout(const Duration(seconds: 20));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200 || j['msg_id'] == null) {
        throw Exception(switch (j['error']) {
          'text'      => tr('Wiadomość jest pusta, dłuższa niż 100 bajtów albo zawiera niedozwolone znaki.'),
          'not_yours' => tr('To urządzenie nie jest sparowane z Twoim portfelem.'),
          final String e when e.startsWith('stale timestamp') =>
              tr('Zegar telefonu odbiega o ponad godzinę — włącz automatyczny czas i spróbuj ponownie.'),
          _ => tr('Nie udało się wysłać wiadomości (%s).', [j['error'] ?? res.statusCode]),
        });
      }
      if (!mounted) return;
      if (_text.text.trim() == text) _text.clear();
      _msgs.add(_Msg('${j['msg_id']}', text, DateTime.now()));
      _tick ??= Timer.periodic(const Duration(seconds: 3), (_) => _poll(owner));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _poll(String owner) async {
    if (_polling) return;
    final now = DateTime.now();
    final open = _msgs.where((m) => !_done(m.state) && now.difference(m.at) < _pollFor).toList();
    if (open.isEmpty) { _tick?.cancel(); _tick = null; return; }
    _polling = true;
    try {
      for (final m in open) {
        try {
          final res = await http.get(
            Uri.parse('${Config.beUrl}/v1/ldev/send/${m.id}').replace(queryParameters: {'owner': owner}),
            headers: _headers,
          ).timeout(const Duration(seconds: 8));
          if (!mounted) return;
          if (res.statusCode != 200) continue;
          final s = (jsonDecode(res.body) as Map<String, dynamic>)['state'];
          if (s is String && s != m.state) setState(() => m.state = s);
        } catch (_) {
          // chwilowy błąd sieci — kolejna próba za 3 s
        }
      }
    } finally {
      _polling = false;
    }
  }

  Widget _stateChip(String state) {
    final (label, color) = switch (state) {
      'delivered' => (tr('doręczono ✓'), const Color(0xFF2ECC71)),
      'sent'      => (tr('wysłano radiem'), AppTheme.amber),
      'failed'    => (tr('nie doręczono'), _errColor),
      _           => (tr('w kolejce'), AppTheme.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 11)),
    );
  }

  String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Widget _bubble(_Msg m) => Align(
    alignment: Alignment.centerRight,
    child: Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: AppTheme.teal.withValues(alpha: 0.10),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(12), topRight: Radius.circular(12),
          bottomLeft: Radius.circular(12), bottomRight: Radius.circular(3)),
        border: Border.all(color: AppTheme.teal.withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        Text(m.text, style: const TextStyle(color: AppTheme.text, fontSize: 14, height: 1.35)),
        const SizedBox(height: 6),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text(_hhmm(m.at), style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
          const SizedBox(width: 8),
          _stateChip(m.state),
        ]),
      ]),
    ),
  );

  Widget _composer() {
    final bytes = utf8.encode(_text.text).length;
    final canSend = !_busy && _text.text.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(top: BorderSide(color: AppTheme.border)),
      ),
      child: Row(children: [
        Expanded(child: TextField(
          controller: _text,
          minLines: 1,
          maxLines: 4,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.send,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) { if (canSend) _send(); },
          // BE odrzuca znaki sterujące (także \n) i tekst ponad 100 bajtów UTF-8
          inputFormatters: [
            FilteringTextInputFormatter.deny(RegExp(r'[\x00-\x1F\x7F-\x9F]')),
            TextInputFormatter.withFunction(
                (old, nw) => utf8.encode(nw.text).length <= _maxBytes ? nw : old),
          ],
          style: const TextStyle(color: AppTheme.text),
          decoration: InputDecoration(
            hintText: tr('Wiadomość do urządzenia'),
            hintStyle: const TextStyle(color: AppTheme.muted),
            counterText: '$bytes/$_maxBytes',
            counterStyle: TextStyle(color: bytes >= _maxBytes ? AppTheme.amber : AppTheme.muted, fontSize: 11),
            isDense: true,
            filled: true,
            fillColor: AppTheme.card,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.border)),
          ),
        )),
        IconButton(
          onPressed: canSend ? _send : null,
          tooltip: tr('Wyślij'),
          color: AppTheme.teal,
          icon: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.send),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.name?.trim() ?? '';
    return Scaffold(
      appBar: AppBar(title: Text(name.isNotEmpty ? name : widget.id8, overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              tr('Wiadomość idzie przez bramę Sensmos, która słyszy urządzenie. '
                 'Wiadomości z urządzenia przychodzą jako powiadomienia (dzwonek).'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.35),
            ),
          ),
          Expanded(child: ListView.builder(
            reverse: true,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            itemCount: _msgs.length,
            itemBuilder: (_, i) => _bubble(_msgs[_msgs.length - 1 - i]),
          )),
          if (_error != null) Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(_error!, style: const TextStyle(color: _errColor, fontSize: 13)),
          ),
          _composer(),
        ]),
      ),
    );
  }
}
