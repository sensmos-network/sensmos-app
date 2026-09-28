import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../config.dart';
import '../../l10n.dart';
import '../../theme.dart';
import '../../core/core_bloc.dart';
import '../../services/owner_token_service.dart';
import '../../services/device_pairing.dart';
import '../../services/wallet_service.dart';

/// Urządzenia sparowane z kontem: co jest wpuszczone, w jakim zakresie i jak to odebrać.
///
/// Token jest kontowy, nie sklepowy — dlatego siedzi w Ustawieniach, a nie w Storage. Tym samym
/// ekranem jutro dasz komputerowi podgląd nodów.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  final _tokens = OwnerTokenService();
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final owner = context.read<CoreBloc>().state.wallet?.address;
    if (owner == null) { setState(() { _loading = false; _error = tr('Portfel wymagany'); }); return; }
    setState(() { _loading = true; _error = null; });
    try {
      final l = await _tokens.list(owner, context.read<WalletService>());
      // Token, ktory telefon wydaje SAM SOBIE, nie jest sparowanym urzadzeniem — pokazywanie go
      // tutaj pozwalalo odebrac dostep wlasnemu telefonowi, na dodatek pod nazwa funkcji.
      final tylkoUrzadzenia = l.where((t) => t['paired'] == true).toList();
      if (mounted) setState(() { _items = tylkoUrzadzenia; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = '$e'; });
    }
  }

  Future<void> _revoke(Map<String, dynamic> t) async {
    final name = (t['label'] as String?)?.trim();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.card,
      title: Text(tr('Odłączyć %s?', [name?.isNotEmpty == true ? name! : tr('to urządzenie')]),
          style: const TextStyle(color: AppTheme.text)),
      // Ten sam ekran pokazuje token, który wydał sobie ten telefon. Odebranie go niczego nie
      // psuje na stałe — apka wyrobi nowy przy najbliższej potrzebie — ale człowiek ma o tym
      // wiedzieć, zanim naciśnie, a nie potem.
      content: Text(tr('Dostęp znika natychmiast. Urządzenie nie wejdzie już na to konto, '
                       'dopóki nie sparujesz go od nowa.'),
          style: const TextStyle(color: AppTheme.muted)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anuluj'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF6666)),
            child: Text(tr('Odłącz'))),
      ]));
    if (ok != true || !mounted) return;
    final owner = context.read<CoreBloc>().state.wallet?.address;
    if (owner == null) return;
    await _tokens.revokeOne(owner, context.read<WalletService>(), t['id']);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Sparowane urządzenia')), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.teal, heroTag: null,
        onPressed: () async {
          final done = await Navigator.push<bool>(context,
              MaterialPageRoute(builder: (_) => const PairScreen()));
          if (done == true) _load();
        },
        icon: const Icon(Icons.add_link, color: Colors.black),
        label: Text(tr('Sparuj'), style: const TextStyle(color: Colors.black)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              Text(tr('Urządzenie sparowane z kontem wchodzi tokenem, nie portfelem. Portfel '
                      'zostaje w telefonie i nigdy go nie opuszcza.'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.35)),
              const SizedBox(height: 14),
              if (_error != null)
                Text(_error!, style: const TextStyle(color: AppTheme.amber, fontSize: 12)),
              if (_items.isEmpty && _error == null)
                Text(tr('Nic jeszcze nie sparowano.'),
                    style: const TextStyle(color: AppTheme.muted)),
              for (final t in _items) _tile(t),
              const SizedBox(height: 80),
            ]),
    );
  }

  Widget _tile(Map<String, dynamic> t) {
    final name = ((t['label'] as String?)?.trim().isNotEmpty ?? false)
        ? t['label'] as String : tr('bez nazwy');
    final scopes = ((t['scopes'] as List?) ?? const []).map((e) => '$e').toList();
    final used = DateTime.tryParse('${t['last_used_at']}')?.toLocal();
    return Card(
      color: AppTheme.surface, margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.devices_other, color: AppTheme.teal),
        title: Text(name, style: const TextStyle(color: AppTheme.text, fontSize: 14)),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 4),
          Wrap(spacing: 4, runSpacing: 4, children: [
            for (final s in scopes) Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                  border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(4)),
              child: Text(s, style: const TextStyle(color: AppTheme.muted, fontSize: 10)),
            ),
          ]),
          if (used != null) Padding(padding: const EdgeInsets.only(top: 4),
              child: Text(tr('ostatnio: %s', ['${used.day}.${used.month.toString().padLeft(2, '0')} '
                  '${used.hour.toString().padLeft(2, '0')}:${used.minute.toString().padLeft(2, '0')}']),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 11))),
        ]),
        trailing: IconButton(icon: const Icon(Icons.link_off, color: AppTheme.muted),
            tooltip: tr('Odłącz'), onPressed: () => _revoke(t)),
      ),
    );
  }
}

/// Ekran parowania. Pól jest więcej niż dwa, więc pełny ekran, nie okienko.
class PairScreen extends StatefulWidget {
  const PairScreen({super.key});
  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _code = TextEditingController();
  Map<String, dynamic>? _found;              // {name, pub} spod tego kodu
  Map<String, String> _scopes = {};          // klucz → opis, z serwera
  final _chosen = <String>{};
  bool _readFiles = false;
  String? _busy, _error;

  @override
  void initState() { super.initState(); _loadScopes(); }
  @override
  void dispose() { _code.dispose(); super.dispose(); }

  /// Listę zakresów bierzemy z serwera, żeby ekran nie trzymał własnej kopii i nie rozjechał się
  /// z tym, co backend naprawdę honoruje.
  Future<void> _loadScopes() async {
    try {
      final r = await http.get(Uri.parse('${Config.beUrl}/v1/nodes/owner-token/scopes'))
          .timeout(const Duration(seconds: 10));
      final m = (jsonDecode(r.body) as Map<String, dynamic>)['scopes'] as Map<String, dynamic>;
      if (mounted) setState(() => _scopes = m.map((k, v) => MapEntry(k, '$v')));
    } catch (_) {/* bez opisów da się żyć, przy zaznaczaniu i tak liczy się klucz */}
  }

  Future<void> _lookup() async {
    setState(() { _busy = tr('Szukam…'); _error = null; });
    try {
      final f = await DevicePairing.lookup(_code.text);
      if (mounted) setState(() {
        _found = f;
        _busy = null;
        // Zaznaczamy dokladnie to, o co program poprosil. Nie pokazujemy niczego wiecej — czego
        // nie widac, tego nikt nie zaznaczy „na wszelki wypadek".
        _chosen
          ..clear()
          ..addAll(((f['want'] as List?) ?? const []).map((e) => '$e'));
      });
    } catch (e) {
      if (mounted) setState(() { _busy = null; _error = '$e'; _found = null; });
    }
  }

  Future<void> _pair() async {
    final owner = context.read<CoreBloc>().state.wallet?.address;
    if (owner == null) { setState(() => _error = tr('Portfel wymagany')); return; }
    setState(() { _busy = tr('Paruję…'); _error = null; });
    try {
      await DevicePairing.pair(
        code: _code.text,
        owner: owner,
        wallet: context.read<WalletService>(),
        deviceName: '${_found?['name'] ?? 'device'}',
        scopes: _chosen.toList(),
        readFiles: _readFiles,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() { _busy = null; _error = '$e'; });
    }
  }

  Future<void> _scan() async {
    final code = await Navigator.push<String>(context,
        MaterialPageRoute(builder: (_) => const _ScanScreen()));
    if (code == null || !mounted) return;
    _code.text = code;
    await _lookup();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Sparuj urządzenie'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(tr('Na komputerze pojawi się kod. Przepisz go tutaj albo zeskanuj — to ten sam kod.'),
            style: const TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.35)),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [UpperCaseFormatter()],
            // Bez tego „Sprawdź kod" zostaje wyszarzony po wpisaniu kodu ręcznie (działał tylko skan).
            onChanged: (_) => setState(() {}),
            style: const TextStyle(color: AppTheme.text, letterSpacing: 2, fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: tr('Kod z komputera'),
              labelStyle: const TextStyle(color: AppTheme.muted),
              enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.border)),
              focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.teal)),
            ),
          )),
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.qr_code_scanner, color: AppTheme.teal),
              tooltip: tr('Zeskanuj'), onPressed: _busy == null ? _scan : null),
        ]),
        const SizedBox(height: 10),
        SizedBox(width: double.infinity, child: OutlinedButton(
            onPressed: _busy == null && _code.text.isNotEmpty ? _lookup : null,
            style: OutlinedButton.styleFrom(foregroundColor: AppTheme.teal),
            child: Text(tr('Sprawdź kod')))),

        if (_found != null) ...[
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppTheme.card, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('„%s" prosi o dostęp do konta', ['${_found!['name']}']),
                  style: const TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(tr('Zaznacz, co temu urządzeniu wolno. Możesz to odebrać w każdej chwili.'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
              const SizedBox(height: 8),
              for (final e in _scopes.entries.where((e) => _chosen.contains(e.key)))
                CheckboxListTile(
                  dense: true, contentPadding: EdgeInsets.zero,
                  activeColor: AppTheme.teal,
                  value: _chosen.contains(e.key),
                  // Zakresu, o ktory program poprosil, nie da sie tu odznaczyc — odmowa polega na
                  // nienacisnieciu „Sparuj", a nie na wydaniu tokenu, ktory i tak nie zadziala.
                  onChanged: null,
                  title: Text(e.key, style: const TextStyle(color: AppTheme.text, fontSize: 13)),
                  subtitle: Text(e.value, style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                ),
              if (_chosen.contains('store.use')) ...[
                const Divider(color: AppTheme.surface),
                SwitchListTile(
                  dense: true, contentPadding: EdgeInsets.zero, activeColor: AppTheme.teal,
                  value: _readFiles,
                  onChanged: (v) => setState(() => _readFiles = v),
                  title: Text(tr('Może czytać pliki'),
                      style: const TextStyle(color: AppTheme.text, fontSize: 13)),
                  subtitle: Text(tr('Bez tego urządzenie wyśle pliki i zobaczy listę, ale nie '
                                    'otworzy żadnego. Odłączenie odbiera dostęp do konta, ale NIE '
                                    'odbiera klucza, który już dostało.'),
                      style: const TextStyle(color: AppTheme.amber, fontSize: 11, height: 1.3)),
                ),
              ],
            ]),
          ),
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, child: FilledButton(
              onPressed: _busy == null && _chosen.isNotEmpty ? _pair : null,
              style: FilledButton.styleFrom(backgroundColor: AppTheme.teal),
              child: Text(tr('Sparuj'), style: const TextStyle(color: Colors.black)))),
        ],

        if (_busy != null) Padding(padding: const EdgeInsets.only(top: 14),
            child: Row(children: [
              const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.teal)),
              const SizedBox(width: 10),
              Text(_busy!, style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
            ])),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 14),
            child: Text(_error!, style: const TextStyle(color: AppTheme.amber, fontSize: 12))),
      ]),
    );
  }
}

/// Wielkie litery od razu przy pisaniu — kod jest z alfabetu bez znaków mylących, więc małe
/// litery i tak nic nie znaczą, a widok „jak na ekranie komputera" ułatwia porównanie.
class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue _, TextEditingValue n) =>
      n.copyWith(text: n.text.toUpperCase());
}

class _ScanScreen extends StatefulWidget {
  const _ScanScreen();
  @override
  State<_ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<_ScanScreen> {
  bool _done = false;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('Zeskanuj kod'))),
        body: MobileScanner(onDetect: (c) {
          if (_done) return;
          final v = c.barcodes.isNotEmpty ? c.barcodes.first.rawValue : null;
          if (v == null || v.isEmpty) return;
          _done = true;
          Navigator.pop(context, v);
        }),
      );
}
