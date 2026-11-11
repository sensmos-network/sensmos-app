import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import '../../config.dart';
import '../../l10n.dart';
import '../../theme.dart';
import '../../services/node_service.dart';
import '../../services/owner_token_service.dart';
import '../../services/wallet_service.dart';

/// Udostępnienie noda instalatorowi PV (panel sensmos.com/installer): instalator po adresie portfela widzi
/// produkcję, baterię, sieć i alarmy tej instalacji. Tylko odczyt, odwołanie w każdej chwili.
class InstallerShareScreen extends StatefulWidget {
  final SavedNode node;
  /// Z zaproszenia (link z panelu instalatora): adres wpisany w pole, nazwa firmy do pokazania.
  /// Nic nie jest udostępniane samo — właściciel i tak klika „Udostępnij” i podpisuje.
  final String? inviteAddress, inviteName;
  const InstallerShareScreen({super.key, required this.node, this.inviteAddress, this.inviteName});

  @override
  State<InstallerShareScreen> createState() => _InstallerShareScreenState();
}

class _InstallerShareScreenState extends State<InstallerShareScreen> {
  final _addr = TextEditingController(), _label = TextEditingController();
  bool _busy = false, _loading = true;
  List<Map<String, dynamic>> _grants = [];
  WalletService get _wallet => context.read<WalletService>();

  @override
  void initState() {
    super.initState();
    if (widget.inviteAddress != null) _addr.text = widget.inviteAddress!;
    _load();
  }

  Future<Map<String, dynamic>?> _auth(String action) async {
    final owner = (await _wallet.load())?.address;
    if (owner == null) { _snack(tr('Brak portfela'), error: true); return null; }
    final tok = await OwnerTokenService().cached(owner);
    if (tok != null) return {'owner_token': tok};
    if (!await _wallet.isUnlocked()) { _snack(tr('Odblokuj portfel, aby podpisać'), error: true); return null; }
    final ts = (DateTime.now().millisecondsSinceEpoch / 1000).round();
    try { return {'owner': owner, 'ts': ts, 'sig': await _wallet.signMessage('sensmos:$action:$ts')}; }
    catch (_) { _snack(tr('Odblokuj portfel, aby podpisać'), error: true); return null; }
  }

  Future<Map<String, dynamic>?> _post(String path, Map<String, dynamic> body) async {
    try {
      final r = await http.post(Uri.parse('${Config.beUrl}/v1/installer$path'), headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body)).timeout(const Duration(seconds: 12));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) { _snack('${j['error'] ?? r.statusCode}', error: true); return null; }
      return j;
    } catch (_) { _snack(tr('Brak połączenia z serwerem'), error: true); return null; }
  }

  Future<void> _load() async {
    final a = await _auth('installer-grants');
    final j = a == null ? null : await _post('/grants', a);
    if (!mounted) return;
    setState(() {
      _grants = ((j?['grants'] as List?) ?? []).cast<Map<String, dynamic>>().where((g) => g['device_id'] == widget.node.id).toList();
      _loading = false;
    });
  }

  Future<void> _share() async {
    final addr = _addr.text.trim().toLowerCase();
    if (!RegExp(r'^0x[0-9a-f]{40}$').hasMatch(addr)) { _snack(tr('Podaj adres portfela instalatora (0x…)'), error: true); return; }
    setState(() => _busy = true);
    final a = await _auth('installer-grant');
    if (a != null) {
      final j = await _post('/grant', {...a, 'device_id': widget.node.id, 'installer': addr, if (_label.text.trim().isNotEmpty) 'label': _label.text.trim()});
      if (j != null) { _addr.clear(); _label.clear(); _snack(tr('Udostępniono instalatorowi')); await _load(); }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _revoke(int id) async {
    setState(() => _busy = true);
    final a = await _auth('installer-revoke');
    if (a != null && await _post('/revoke', {...a, 'id': id}) != null) await _load();
    if (mounted) setState(() => _busy = false);
  }

  void _snack(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: error ? AppTheme.red : null));
  }

  InputDecoration _dec(String l) => InputDecoration(labelText: l, labelStyle: const TextStyle(color: AppTheme.muted),
      enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.border)),
      focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.teal)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Udostępnij instalatorowi'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(tr('Twój instalator PV zobaczy na sensmos.com/installer produkcję, baterię, sieć i alarmy tego noda. Tylko podgląd, bez sterowania. Możesz odebrać dostęp w każdej chwili.'),
            style: const TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.35)),
        if (widget.inviteAddress != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(border: Border.all(color: AppTheme.teal), borderRadius: BorderRadius.circular(8)),
            child: Text(
              tr('Zaproszenie od: %s. Sprawdź, czy to Twój instalator i czy adres zgadza się z tym, który Ci podał.',
                  [(widget.inviteName ?? '').isNotEmpty ? widget.inviteName! : tr('instalator bez nazwy')]),
              style: const TextStyle(color: AppTheme.text, fontSize: 13, height: 1.35)),
          ),
        ],
        const SizedBox(height: 16),
        TextField(controller: _addr, style: const TextStyle(color: AppTheme.text), decoration: _dec(tr('Adres portfela instalatora (0x…)')).copyWith(
            suffixIcon: IconButton(icon: const Icon(Icons.paste, size: 18), onPressed: () async {
              final d = await Clipboard.getData('text/plain'); if (d?.text != null) _addr.text = d!.text!.trim();
            }))),
        const SizedBox(height: 10),
        TextField(controller: _label, maxLength: 64, style: const TextStyle(color: AppTheme.text), decoration: _dec(tr('Nazwa instalacji dla instalatora (opcjonalnie)'))),
        SizedBox(width: double.infinity, child: FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.teal, foregroundColor: Colors.black),
          onPressed: _busy ? null : _share, child: Text(tr('Udostępnij')))),
        const SizedBox(height: 20),
        if (_loading) const Center(child: CircularProgressIndicator(color: AppTheme.teal))
        else if (_grants.isEmpty) Text(tr('Ten nod nie jest nikomu udostępniony.'), style: const TextStyle(color: AppTheme.muted, fontSize: 13))
        else ..._grants.map((g) => Card(child: ListTile(
            title: Text('${g['installer_address']}'.replaceRange(8, 38, '…'), style: const TextStyle(color: AppTheme.text, fontSize: 13)),
            subtitle: g['label'] != null ? Text('${g['label']}', style: const TextStyle(color: AppTheme.muted, fontSize: 12)) : null,
            trailing: TextButton(onPressed: _busy ? null : () => _revoke((g['id'] is int) ? g['id'] as int : int.parse('${g['id']}')),
                child: Text(tr('Odbierz dostęp'), style: const TextStyle(color: AppTheme.red)))))),
      ]),
    );
  }
}
