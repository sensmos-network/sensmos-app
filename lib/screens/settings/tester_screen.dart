import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../config.dart';
import '../../l10n.dart';
import '../../log.dart';
import '../../theme.dart';
import '../../services/node_service.dart';
import '../../services/owner_token_service.dart';
import '../../services/wallet_service.dart';

/// Program testów społeczności: zapis (portfel + nick + sprzęt), tryb testera i „Wyślij raport"
/// (paczka diagnostyczna POST /v1/diag). Bez maila i danych osobowych — tylko adres portfela.
class TesterScreen extends StatefulWidget {
  const TesterScreen({super.key});
  @override
  State<TesterScreen> createState() => _TesterScreenState();
}

class _TesterScreenState extends State<TesterScreen> {
  static const _kMode = 'tester_mode';
  static const _kScenario = 'tester_scenario';
  final _nick = TextEditingController();
  final _scenario = TextEditingController();
  final _note = TextEditingController();
  String _esp = '';
  bool _hub = false, _ha = false, _mode = false, _busy = false, _enrolled = false;
  int _packages = 0;
  String? _status;

  WalletService get _wallet => context.read<WalletService>();

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() { _mode = p.getBool(_kMode) ?? false; _scenario.text = p.getString(_kScenario) ?? ''; });
    });
    _loadMe();
  }

  @override
  void dispose() { _nick.dispose(); _scenario.dispose(); _note.dispose(); super.dispose(); }

  /// Auth jak przy pushach: token właściciela, a gdy go nie ma — podpis otwartego portfela.
  Future<Map<String, dynamic>?> _auth(String action) async {
    final owner = (await _wallet.load())?.address;
    if (owner == null) { _snack(tr('Brak portfela'), error: true); return null; }
    final tok = await OwnerTokenService().cached(owner);
    if (tok != null) return {'owner_token': tok};
    if (!await _wallet.isUnlocked()) { _snack(tr('Odblokuj portfel, aby podpisać'), error: true); return null; }
    final ts = (DateTime.now().millisecondsSinceEpoch / 1000).round();
    try {
      return {'owner': owner, 'ts': ts, 'sig': await _wallet.signMessage('sensmos:$action:$ts')};
    } catch (_) { _snack(tr('Odblokuj portfel, aby podpisać'), error: true); return null; }
  }

  Future<Map<String, dynamic>?> _post(String path, Map<String, dynamic> body) async {
    try {
      final res = await http.post(Uri.parse('${Config.beUrl}/v1/diag$path'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode(body)).timeout(const Duration(seconds: 15));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) { _snack('${j['error'] ?? res.statusCode}', error: true); return null; }
      return j;
    } catch (e) { _snack(tr('Brak połączenia z serwerem'), error: true); return null; }
  }

  Future<void> _loadMe() async {
    final a = await _auth('test-me');
    if (a == null) return;
    final j = await _post('/me', a);
    if (j == null || !mounted) return;
    setState(() {
      _enrolled = j['enrolled'] == true;
      _packages = (j['packages'] ?? 0) as int;
      if (_enrolled) {
        _nick.text = (j['nick'] ?? '').toString();
        final hw = (j['hardware'] ?? {}) as Map<String, dynamic>;
        _esp = (hw['esp32'] ?? '').toString();
        _hub = hw['hub'] == true; _ha = hw['ha'] == true;
      }
    });
  }

  Future<void> _enroll() async {
    setState(() => _busy = true);
    final a = await _auth('test-enroll');
    if (a != null) {
      final j = await _post('/enroll', {...a, 'nick': _nick.text.trim(), 'tester_mode': _mode,
        'hardware': {'esp32': _esp.isEmpty ? null : _esp, 'hub': _hub, 'ha': _ha, 'phone': Platform.isIOS ? 'ios' : 'android'}});
      if (j != null) { setState(() => _enrolled = true); _snack(tr('Zapisano do programu testów')); }
    }
    if (mounted) setState(() => _busy = false);
  }

  Map<String, dynamic> _package() {
    final entries = Log.entries.reversed.toList();
    return {
      'schema': 1, 'component': 'app', 'version': Config.appVersion,
      'build': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'scenario_id': _scenario.text.trim().isEmpty ? null : _scenario.text.trim(),
      'device': {'os': Platform.operatingSystem, 'os_version': Platform.operatingSystemVersion, 'locale': Platform.localeName},
      'config': {'lang': L10n.mode, 'nodes': context.read<NodeService>().nodes.length, 'tester_mode': _mode},
      'events': entries.map((e) => {'t': e.t.toIso8601String(), 'l': e.level, 'g': e.tag, 'm': e.msg}).toList(),
      'errors': entries.where((e) => e.level == 'E').map((e) => e.line).toList(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<void> _send(String? result) async {
    setState(() => _busy = true);
    final a = await _auth('diag');
    if (a != null) {
      final j = await _post('', {...a, 'package': _package(), if (result != null) 'result': result,
        if (_note.text.trim().isNotEmpty) 'note': _note.text.trim()});
      if (j != null) {
        setState(() { _packages++; _status = tr('Raport #%s wysłany', [j['id']]); });
        _note.clear();
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  // Logi noda (FW ≥ 1.12): serwer pyta nod przez WS, nod odsyła ostatnie linie z pamięci → paczka diag.
  Future<void> _sendNodeLogs() async {
    final nodes = context.read<NodeService>().nodes.where((n) => n.id.isNotEmpty).toList();
    if (nodes.isEmpty) { _snack(tr('Brak nodów w aplikacji'), error: true); return; }
    final node = nodes.length == 1 ? nodes.first : await showDialog<SavedNode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('Wybierz nod'), style: const TextStyle(color: AppTheme.text, fontSize: 17)),
        children: [for (final n in nodes) SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, n),
          child: Text('${n.label}  ${n.id.substring(0, n.id.length < 8 ? n.id.length : 8)}…', style: const TextStyle(color: AppTheme.text)))],
      ));
    if (node == null) return;
    setState(() { _busy = true; _status = tr('Pytam nod o logi…'); });
    final a = await _auth('node-logs');
    if (a != null) {
      try {
        final res = await http.post(Uri.parse('${Config.beUrl}/v1/diag/node-logs'),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode({...a, 'device_id': node.id})).timeout(const Duration(seconds: 25));
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        if (!mounted) return;
        setState(() => _status = res.statusCode == 200
            ? tr('Logi noda wysłane (paczka #%s, %s linii)', [j['id'], (j['lines'] as List?)?.length ?? 0])
            : res.statusCode == 404 ? tr('To nie jest nod z Twojego portfela')
            : tr('Nod nie odpowiedział: logi wymagają firmware 1.12 lub nowszego i noda online'));
      } catch (_) { if (mounted) setState(() => _status = tr('Brak połączenia z serwerem')); }
    } else if (mounted) { setState(() => _status = null); }
    if (mounted) setState(() => _busy = false);
  }

  void _snack(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: error ? Colors.red.shade800 : null));
  }

  InputDecoration _dec(String label) => InputDecoration(labelText: label, labelStyle: const TextStyle(color: AppTheme.muted),
      enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.border)),
      focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.teal)));

  @override
  Widget build(BuildContext context) {
    const esp = ['', 'esp32', 'esp32s3', 'esp32s3-n16r8', 'esp32c3', 'esp32s3-lora'];
    return Scaffold(
      appBar: AppBar(title: Text(tr('Program testów'))),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text(tr('Testujesz nowe wersje apki, hubu i firmware według scenariuszy, a serwer zalicza je automatycznie. Nagrody w GALU z puli testów, co miesiąc według punktów. Bez maila: liczy się tylko portfel.'),
            style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
        const SizedBox(height: 16),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_enrolled ? tr('Jesteś w programie') : tr('Zapis do programu'),
              style: const TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          TextField(controller: _nick, maxLength: 32, style: const TextStyle(color: AppTheme.text), decoration: _dec(tr('Nick (opcjonalny, widoczny w rankingu)'))),
          DropdownButtonFormField<String>(
            initialValue: esp.contains(_esp) ? _esp : '',
            dropdownColor: AppTheme.card,
            decoration: _dec(tr('Płytka ESP32')),
            items: esp.map((e) => DropdownMenuItem(value: e, child: Text(e.isEmpty ? tr('brak') : e, style: const TextStyle(color: AppTheme.text)))).toList(),
            onChanged: (v) => setState(() => _esp = v ?? ''),
          ),
          SwitchListTile(value: _hub, onChanged: (v) => setState(() => _hub = v), contentPadding: EdgeInsets.zero,
              title: Text(tr('Mam Sensmos Hub (Docker)'), style: const TextStyle(color: AppTheme.text))),
          SwitchListTile(value: _ha, onChanged: (v) => setState(() => _ha = v), contentPadding: EdgeInsets.zero,
              title: Text(tr('Mam Home Assistant'), style: const TextStyle(color: AppTheme.text))),
          SwitchListTile(value: _mode, contentPadding: EdgeInsets.zero,
              title: Text(tr('Tryb testera'), style: const TextStyle(color: AppTheme.text)),
              subtitle: Text(tr('więcej logów, raporty oznaczone scenariuszem, wersje beta apki w „Sprawdź aktualizację”'), style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
              onChanged: (v) async { setState(() => _mode = v); (await SharedPreferences.getInstance()).setBool(_kMode, v); }),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.teal, foregroundColor: Colors.black),
            onPressed: _busy ? null : _enroll,
            child: Text(_enrolled ? tr('Zapisz zmiany') : tr('Zapisz się')))),
        ]))),
        const SizedBox(height: 16),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Wyślij raport'), style: const TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(tr('Paczka diagnostyczna: wersja, urządzenie, logi apki bez tokenów i kluczy. Serwer dodatkowo wycina sekrety.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          const SizedBox(height: 12),
          TextField(controller: _scenario, style: const TextStyle(color: AppTheme.text), decoration: _dec(tr('Scenariusz (id, opcjonalnie)')),
              onChanged: (v) async => (await SharedPreferences.getInstance()).setString(_kScenario, v.trim())),
          const SizedBox(height: 10),
          TextField(controller: _note, maxLines: 3, maxLength: 500, style: const TextStyle(color: AppTheme.text), decoration: _dec(tr('Co się stało (opcjonalnie)'))),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _send('ok'), child: Text(tr('Działa')))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _send('fail'), child: Text(tr('Nie działa')))),
            const SizedBox(width: 8),
            Expanded(child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.teal, foregroundColor: Colors.black),
              onPressed: _busy ? null : () => _send(null), child: Text(tr('Wyślij')))),
          ]),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(
            onPressed: _busy ? null : _sendNodeLogs,
            icon: const Icon(Icons.receipt_long, size: 18),
            label: Text(tr('Wyślij logi noda')))),
          if (_status != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_status!, style: const TextStyle(color: AppTheme.teal, fontSize: 12))),
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(tr('Wysłane raporty: %s', [_packages]), style: const TextStyle(color: AppTheme.muted, fontSize: 12))),
        ]))),
      ]),
    );
  }
}
