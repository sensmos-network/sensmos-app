import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/kom_ble.dart';

/// „Dom bez internetu” (komunikator 0.17-kom): wiadomość radiem prosto do noda w domu, bez serwera.
/// Nod (najlepiej w trybie Punkt) wkłada ją do skrzynki LoRa, a Home Assistant czyta ją w sieci domowej
/// (integracja Sensmos, zdarzenie sensmos_lora_frame). Potwierdzenie i odpowiedź nadaje nod radiem.
/// Fraza i id8 to te same, co w apce: nod → LoRa → Odbiór ramek (klucza nie da się odczytać z noda).
class KomHomeScreen extends StatefulWidget {
  final KomBle kom;
  const KomHomeScreen({super.key, required this.kom});

  @override
  State<KomHomeScreen> createState() => _KomHomeScreenState();
}

class _KomHomeScreenState extends State<KomHomeScreen> {
  final _id8 = TextEditingController(), _key = TextEditingController(), _sub = TextEditingController(text: '9');
  final _poll = TextEditingController(text: '10'), _msg = TextEditingController();
  bool _busy = false, _edit = false;
  String? _error, _sent;
  List<Map<String, dynamic>> _box = [];

  Map<String, dynamic> get _i => widget.kom.info.value ?? const {};
  bool get _set => _i['home_id8'] != null;

  @override
  void initState() {
    super.initState();
    _edit = !_set;
    if (_set) {
      _id8.text = '${_i['home_id8']}';
      _sub.text = '${_i['home_sub'] ?? 9}';
      _poll.text = '${_i['home_poll'] ?? 10}';
    }
    _loadBox();
  }

  @override
  void dispose() {
    for (final c in [_id8, _key, _sub, _poll, _msg]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadBox() async {
    try {
      final all = await widget.kom.messages();
      if (!mounted) return;
      setState(() => _box = all.where((m) => '${m['text']}'.contains('Dom')).toList().reversed.take(12).toList());
    } catch (_) {}
  }

  Future<void> _save() async {
    final id8 = _id8.text.trim().toLowerCase();
    final sub = int.tryParse(_sub.text) ?? 0, poll = int.tryParse(_poll.text) ?? -1;
    if (!RegExp(r'^[0-9a-f]{8}$').hasMatch(id8)) return setState(() => _error = tr('id noda to 8 znaków 0-9 a-f.'));
    if (_key.text.length < 8) return setState(() => _error = tr('Fraza musi mieć co najmniej 8 znaków'));
    if (sub < 1 || sub > 255) return setState(() => _error = tr('Numer czujnika 1–255.'));
    if (poll < 0 || poll > 120) return setState(() => _error = tr('Pytanie o odpowiedź: 0–120 minut.'));
    setState(() { _busy = true; _error = null; });
    try {
      await widget.kom.request('home', {'id8': id8, 'key': _key.text, 'sub': sub, 'poll': poll});
      await widget.kom.refreshInfo();
      _key.clear();
      if (mounted) setState(() => _edit = false);
    } catch (e) {
      if (mounted) setState(() => _error = komErrText(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _off() async {
    setState(() => _busy = true);
    try {
      await widget.kom.request('home', {'id8': ''});
      await widget.kom.refreshInfo();
      if (mounted) setState(() => _edit = true);
    } catch (e) {
      if (mounted) setState(() => _error = komErrText(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _send() async {
    final t = _msg.text.trim();
    if (t.isEmpty) return;
    setState(() { _busy = true; _error = null; _sent = null; });
    try {
      final r = await widget.kom.request('hsend', {'text': t});
      _msg.clear();
      _sent = tr('Wysłane jako #%s. Czekam na potwierdzenie z domu (do 3 minut).', [r['n']]);
      await widget.kom.refreshInfo();
    } catch (e) {
      final code = e is KomError ? e.code : '';
      _error = code == 'busy'
          ? tr('Poprzednia wiadomość jeszcze czeka na potwierdzenie.')
          : code == 'home'
              ? tr('Najpierw ustaw dom.')
              : komErrText(e);
    }
    if (mounted) setState(() => _busy = false);
    Future.delayed(const Duration(seconds: 40), () { if (mounted) _loadBox(); });
  }

  String _stateText(String? s) => switch (s) {
        'wait' => tr('czeka na potwierdzenie'),
        'ok' => tr('ostatnia dostarczona'),
        'fail' => tr('ostatnia bez potwierdzenia'),
        _ => tr('gotowy'),
      };

  @override
  Widget build(BuildContext context) {
    final fwOk = _i.containsKey('home_id8');
    return Scaffold(
      appBar: AppBar(title: Text(tr('Dom bez internetu'))),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text(
              tr('Wiadomość idzie radiem prosto do Twojego noda w domu, bez serwera i bez internetu. Home Assistant w domu dostaje ją z noda w sieci lokalnej, a nod odsyła potwierdzenie.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.4)),
          if (!fwOk)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(tr('Wymaga firmware komunikatora 0.17-kom lub nowszego.'),
                  style: const TextStyle(color: AppTheme.amber, fontSize: 13)),
            ),
          if (fwOk && !_edit) ...[
            const SizedBox(height: 16),
            Card(child: ListTile(
              leading: const Icon(Icons.home_outlined, color: AppTheme.teal),
              title: Text('${tr('Nod')} ${_i['home_id8']} · sub ${_i['home_sub']}', style: const TextStyle(color: AppTheme.text)),
              subtitle: Text(_stateText('${_i['home_state']}'), style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
              trailing: TextButton(onPressed: _busy ? null : () => setState(() => _edit = true), child: Text(tr('Zmień'))),
            )),
            const SizedBox(height: 12),
            TextField(
              controller: _msg,
              enabled: !_busy,
              maxLength: 90,
              style: const TextStyle(color: AppTheme.text),
              decoration: InputDecoration(hintText: tr('Wiadomość do domu')),
              onSubmitted: (_) => _send(),
            ),
            FilledButton.icon(
              onPressed: _busy ? null : _send,
              icon: const Icon(Icons.send, size: 18),
              label: Text(tr('Wyślij do domu')),
            ),
            if (_sent != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(_sent!, style: const TextStyle(color: AppTheme.teal, fontSize: 12))),
            const SizedBox(height: 16),
            for (final m in _box)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('${m['text']}',
                    style: TextStyle(color: m['dir'] == 'out' ? AppTheme.muted : AppTheme.text, fontSize: 13)),
              ),
          ],
          if (fwOk && _edit) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _id8,
              enabled: !_busy,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')), LengthLimitingTextInputFormatter(8)],
              style: const TextStyle(color: AppTheme.text, fontFamily: 'monospace'),
              decoration: InputDecoration(labelText: tr('id noda w domu (8 znaków)')),
            ),
            TextField(
              controller: _key,
              enabled: !_busy,
              obscureText: true,
              style: const TextStyle(color: AppTheme.text),
              decoration: InputDecoration(labelText: tr('Fraza-klucz noda')),
            ),
            Row(children: [
              Expanded(child: TextField(
                controller: _sub,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: AppTheme.text),
                decoration: InputDecoration(labelText: tr('Numer czujnika (sub)')),
              )),
              const SizedBox(width: 12),
              Expanded(child: TextField(
                controller: _poll,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: AppTheme.text),
                decoration: InputDecoration(labelText: tr('Pytaj o odpowiedź co (min)')),
              )),
            ]),
            const SizedBox(height: 8),
            Text(
                tr('id i frazę znajdziesz w apce: nod w domu → LoRa → Odbiór ramek. Ten nod ustaw w trybie Punkt, żeby słyszał komunikator cały czas.'),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.4)),
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _save, child: Text(tr('Zapisz'))),
            if (_set)
              TextButton(onPressed: _busy ? null : _off, child: Text(tr('Wyłącz dom'), style: const TextStyle(color: AppTheme.red))),
          ],
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: AppTheme.red, fontSize: 13))),
        ]),
      ),
    );
  }
}
