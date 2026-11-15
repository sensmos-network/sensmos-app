import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import '../../config.dart';
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/node_service.dart';
import '../../services/owner_token_service.dart';
import '../../services/wallet_service.dart';
import 'lora_add_sensor_screen.dart';
import 'lora_emerg_screen.dart';

/// LoRa — jeden ekran wszystkich ustawień radia noda (standaryzacja 2026-09-01):
/// Awaryjne (link do istniejącego ekranu), Odbiór ramek (klucz-fraza + opt-in jawnych),
/// Wyślij (tester ramki DATA), Inbox (frames+cmds z GET /lora/inbox).
/// Chipy cen przy płatnych funkcjach — świadoma zgoda (cennik 2026-09-01).
class LoraScreen extends StatefulWidget {
  final SavedNode node;
  final String pin;
  const LoraScreen({super.key, required this.node, required this.pin});

  @override
  State<LoraScreen> createState() => _LoraScreenState();
}

class _LoraScreenState extends State<LoraScreen> {
  bool _loading = true;
  bool _noRadio = false;
  bool _keySet = false;
  bool _open = false;
  bool _busy = false;
  final _keyCtrl = TextEditingController();
  final _dstCtrl = TextEditingController();
  final _subCtrl = TextEditingController(text: '0');
  final _payloadCtrl = TextEditingController();
  bool _sendAes = true;
  String? _sendResult;
  Map<String, dynamic>? _inbox;
  // Tryb odbioru z serwera (GET/POST /v1/nodes/:id/lora_role): 'point' = stale na kanale domowym,
  // 'scan' = rotacja kanałów (czujniki słyszane tylko część godziny). null = brak planu/offline.
  String? _role;
  bool _roleBusy = false;

  Map<String, String> get _auth => {'Authorization': 'Bearer ${widget.pin}'};
  Uri _u(String path) => Uri.parse('http://${widget.node.ip}$path');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _dstCtrl.dispose();
    _subCtrl.dispose();
    _payloadCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await http.get(_u('/node/lora_rx'), headers: _auth)
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 404) {
        if (mounted) setState(() { _loading = false; _noRadio = true; });
        return;
      }
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        _keySet = j['key_set'] == true;
        _open = j['open'] == true;
      }
      await _loadInbox();
      await _loadRole();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addSensor() async {
    final frames = ((_inbox?['frames'] as Map<String, dynamic>?)?['items'] as List?) ?? const [];
    final used = <int>{for (final f in frames) if (f is Map && f['sub'] is int) f['sub'] as int};
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => LoraAddSensorScreen(node: widget.node, pin: widget.pin, keySet: _keySet, usedSubs: used)));
    if (mounted) _load();
  }

  Future<void> _loadRole() async {
    try {
      final owner = (await context.read<WalletService>().load())?.address;
      if (owner == null) return;
      final r = await http.get(Uri.parse(
              '${Config.beUrl}/v1/nodes/${widget.node.id}/lora_role?owner=${owner.toLowerCase()}'))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        _role = j['has_plan'] == true ? j['role'] as String? : null;
      }
    } catch (_) {}
  }

  Future<void> _setRole(bool point) async {
    final role = point ? 'point' : 'scan';
    final wallet = context.read<WalletService>();
    setState(() => _roleBusy = true);
    String? err;
    try {
      final owner = (await wallet.load())?.address;
      if (owner == null) throw tr('Brak portfela');
      final body = <String, dynamic>{'role': role};
      final tok = await OwnerTokenService().cached(owner);
      if (tok != null) {
        body['owner_token'] = tok;
      } else {
        if (!await wallet.isUnlocked()) throw tr('Odblokuj portfel, aby podpisać');
        final ts = (DateTime.now().millisecondsSinceEpoch / 1000).round();
        body['owner'] = owner;
        body['ts'] = ts;
        body['sig'] = await wallet.signMessage('sensmos:lorarole:${widget.node.id}:$role:$ts');
      }
      final r = await http.post(Uri.parse('${Config.beUrl}/v1/nodes/${widget.node.id}/lora_role'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 12));
      if (r.statusCode == 200) {
        _role = role;
      } else if (r.statusCode == 409) {
        err = tr('Node jest offline — spróbuj, gdy wróci do sieci');
      } else {
        try { err = '${(jsonDecode(r.body) as Map)['error'] ?? r.statusCode}'; } catch (_) { err = '${r.statusCode}'; }
      }
    } catch (e) {
      err = '$e';
    }
    if (!mounted) return;
    setState(() => _roleBusy = false);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _loadInbox() async {
    try {
      final r = await http.get(_u('/lora/inbox'), headers: _auth)
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        _inbox = jsonDecode(r.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _saveRx({String? key, bool? open}) async {
    setState(() => _busy = true);
    try {
      final body = <String, dynamic>{};
      if (key != null) body['key'] = key;
      if (open != null) body['open'] = open;
      final r = await http.post(_u('/node/lora_rx'),
              headers: {..._auth, 'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        _keySet = j['key_set'] == true;
        _open = j['open'] == true;
        if (key != null) _keyCtrl.clear();
      }
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _send() async {
    if (_busy) return;
    final dst = _dstCtrl.text.trim().toLowerCase();
    final payload = _payloadCtrl.text;
    if (dst.length != 8 || payload.isEmpty) {
      setState(() => _sendResult = tr('Podaj dst (8 hex) i treść'));
      return;
    }
    setState(() { _busy = true; _sendResult = null; });
    try {
      final r = await http.post(_u('/node/lorasend'),
              headers: {..._auth, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'dst': dst,
                'sub': int.tryParse(_subCtrl.text) ?? 0,
                'payload': payload,
                'aes': _sendAes,
              }))
          .timeout(const Duration(seconds: 5));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      _sendResult = r.statusCode == 200
          ? tr('Zakolejkowane — nadanie w ciągu kilku(nastu) sekund')
          : '${j['error']}';
      if (r.statusCode == 200) _payloadCtrl.clear();
    } catch (e) {
      _sendResult = e.toString();
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _priceChip(String price) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.amber.shade800, width: 0.5),
        ),
        child: Text(price,
            style: TextStyle(
                color: Colors.amber.shade600,
                fontSize: 10,
                fontFamily: 'monospace')),
      );

  Widget _card({required String title, Widget? trailing, required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(title,
                style: const TextStyle(
                    color: AppTheme.text, fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          if (trailing != null) trailing,
        ]),
        const SizedBox(height: 10),
        ...children,
      ]),
    );
  }

  String _ago(int ts) {
    final s = DateTime.now().millisecondsSinceEpoch ~/ 1000 - ts;
    if (s < 0) return '';
    if (s < 60) return '${s}s';
    if (s < 3600) return '${s ~/ 60}m';
    return '${s ~/ 3600}h';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('LoRa — ${widget.node.label}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _noRadio
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(tr('Ten node nie ma radia LoRa (albo firmware bez LoRa).'),
                        style: const TextStyle(color: AppTheme.muted), textAlign: TextAlign.center),
                  ))
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    // ── Awaryjne ──
                    _card(
                      title: tr('LoRa awaryjne'),
                      children: [
                        Text(tr('Encje nadawane beaconem przy padzie internetu + komendy z Panelu Emergency.'),
                            style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) =>
                                        LoraEmergScreen(node: widget.node, pin: widget.pin))),
                            child: Text(tr('Konfiguruj')),
                          ),
                        ),
                      ],
                    ),
                    // ── Odbiór ramek ──
                    _card(
                      title: tr('Odbiór ramek (czujniki LoRa)'),
                      trailing: _priceChip('0.7 GALU/${tr('dzień użycia')}'),
                      children: [
                        Text(
                            tr('Fraza-klucz zostaje TYLKO na nodzie — tę samą wpisz w swoje czujniki. Serwer przekazuje ramki na ślepo.'),
                            style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _busy ? null : _addSensor,
                            icon: const Icon(Icons.add_circle_outline, size: 16),
                            label: Text(tr('Dodaj czujnik LoRa')),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(children: [
                          Expanded(
                            child: TextField(
                              controller: _keyCtrl,
                              style: const TextStyle(fontSize: 13),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: _keySet ? tr('klucz ustawiony — wpisz, by zmienić') : tr('fraza-klucz'),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: _busy ? null : () => _saveRx(key: _keyCtrl.text),
                            child: Text(tr('Zapisz')),
                          ),
                        ]),
                        const SizedBox(height: 10),
                        Row(children: [
                          Icon(_keySet ? Icons.key : Icons.key_off,
                              size: 14, color: _keySet ? AppTheme.teal : AppTheme.muted),
                          const SizedBox(width: 6),
                          Text(_keySet ? tr('klucz ustawiony') : tr('brak klucza'),
                              style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                          const Spacer(),
                          if (_keySet)
                            TextButton(
                              onPressed: _busy ? null : () => _saveRx(key: ''),
                              child: Text(tr('Usuń'),
                                  style: const TextStyle(fontSize: 11, color: AppTheme.muted)),
                            ),
                        ]),
                        const Divider(color: AppTheme.border, height: 18),
                        Row(children: [
                          Expanded(
                            child: Text(tr('Przyjmuj ramki jawne (bez szyfrowania)'),
                                style: const TextStyle(color: AppTheme.text, fontSize: 13)),
                          ),
                          _priceChip('0.5 GALU/${tr('dzień użycia')}'),
                          Switch(
                            value: _open,
                            onChanged: _busy ? null : (v) => _saveRx(open: v),
                          ),
                        ]),
                        Text(tr('Uwaga: jawną ramkę może nadać każdy, kto zna adres noda.'),
                            style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                        if (_role != null) ...[
                          const Divider(color: AppTheme.border, height: 18),
                          Row(children: [
                            Expanded(
                              child: Text(tr('Słuchaj czujników stale (tryb Punkt)'),
                                  style: const TextStyle(color: AppTheme.text, fontSize: 13)),
                            ),
                            Switch(
                              value: _role == 'point',
                              onChanged: _roleBusy ? null : (v) => _setRole(v),
                            ),
                          ]),
                          Text(
                              _role == 'point'
                                  ? tr('Node stoi na kanale domowym i słyszy czujniki oraz komunikator cały czas.')
                                  : tr('Skaner zmienia kanał co 10 min, więc czujniki słyszy tylko przez część godziny. Włącz, jeśli ten node odbiera Twoje czujniki.'),
                              style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                        ],
                      ],
                    ),
                    // ── Wyślij ──
                    _card(
                      title: tr('Wyślij ramkę'),
                      trailing: _priceChip('0.8 GALU/${tr('dzień użycia')}'),
                      children: [
                        Row(children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _dstCtrl,
                              maxLength: 8,
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')),
                              ],
                              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                              decoration: InputDecoration(
                                  isDense: true, counterText: '', hintText: tr('adresat (id8)')),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _subCtrl,
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              style: const TextStyle(fontSize: 13),
                              decoration: const InputDecoration(isDense: true, hintText: 'sub'),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _payloadCtrl,
                          maxLength: 128,
                          style: const TextStyle(fontSize: 13),
                          decoration: InputDecoration(
                              isDense: true, counterText: '', hintText: tr('treść (do 128 B)')),
                        ),
                        const SizedBox(height: 12),
                        Row(children: [
                          Checkbox(
                            value: _sendAes,
                            onChanged: (v) => setState(() => _sendAes = v ?? true),
                          ),
                          Text('AES', style: const TextStyle(color: AppTheme.text, fontSize: 13)),
                          const Spacer(),
                          FilledButton(
                            onPressed: _busy ? null : _send,
                            child: Text(tr('Wyślij')),
                          ),
                        ]),
                        if (_sendResult != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(_sendResult!,
                                style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                          ),
                      ],
                    ),
                    // ── Inbox ──
                    _card(
                      title: tr('Inbox LoRa'),
                      trailing: IconButton(
                        icon: const Icon(Icons.refresh, size: 18, color: AppTheme.muted),
                        onPressed: _loadInbox,
                      ),
                      children: [
                        ..._inboxRows(),
                      ],
                    ),
                  ],
                ),
    );
  }

  List<Widget> _inboxRows() {
    final frames = ((_inbox?['frames'] as Map<String, dynamic>?)?['items'] as List?) ?? const [];
    final cmds = ((_inbox?['cmds'] as Map<String, dynamic>?)?['items'] as List?) ?? const [];
    if (frames.isEmpty && cmds.isEmpty) {
      return [
        Text(tr('Pusto — ramki i komendy odebrane przez LoRa pojawią się tutaj.'),
            style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
      ];
    }
    Widget chip(String t, Color c) => Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
              color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
          child: Text(t, style: TextStyle(color: c, fontSize: 9, fontFamily: 'monospace')),
        );
    final rows = <Widget>[];
    for (final f in frames.reversed) {
      final m = f as Map<String, dynamic>;
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          chip(m['via'] == 'ws' ? 'WS' : 'RF',
              m['via'] == 'ws' ? Colors.blueAccent : AppTheme.teal),
          if (m['enc'] == true) chip('AES', Colors.amber.shade600),
          if ((m['sub'] ?? 0) != 0) chip('sub ${m['sub']}', AppTheme.muted),
          Expanded(
            child: Text((m['text'] ?? m['hex'] ?? '').toString(),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppTheme.text, fontSize: 12)),
          ),
          Text(_ago((m['ts'] ?? 0) as int),
              style: const TextStyle(color: AppTheme.muted, fontSize: 10)),
        ]),
      ));
    }
    for (final c in cmds.reversed) {
      final m = c as Map<String, dynamic>;
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          chip('CMD', Colors.redAccent),
          Expanded(
            child: Text((m['payload'] ?? '').toString(),
                style: const TextStyle(color: AppTheme.text, fontSize: 12)),
          ),
          Text(_ago((m['ts'] ?? 0) as int),
              style: const TextStyle(color: AppTheme.muted, fontSize: 10)),
        ]),
      ));
    }
    return rows;
  }
}
