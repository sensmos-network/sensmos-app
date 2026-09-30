import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import '../../theme.dart';
import '../../core/core_bloc.dart';
import '../../core/core_event.dart';
import '../../core/core_state.dart';
import '../../services/ble_service.dart';
import '../../services/node_service.dart';
import '../setup/setup_screen.dart';
import '../../l10n.dart';
import '../nodes/gateway_screen.dart';

class NodeManagerScreen extends StatefulWidget {
  const NodeManagerScreen({super.key, this.popOnActivate = false,
      this.addOnly = false, this.existingOnly = false});
  final bool popOnActivate;
  final bool addOnly;       // 'Dodaj node' — tylko BLE onboarding (tworzy/odzyskuje portfel), bez zakladek
  final bool existingOnly;  // 'Wyszukaj moje nody' — istniejacy node: Szukaj + Recznie (bez BLE-add)
  @override State<NodeManagerScreen> createState() => _NodeManagerScreenState();
}

enum _Tab { add, search, manual }

class _FoundNode {
  final String ip, deviceId, firmware;
  final bool alreadySaved;
  _FoundNode({required this.ip, required this.deviceId, required this.firmware, this.alreadySaved = false});
}

class _NodeManagerScreenState extends State<NodeManagerScreen> {
  late _Tab _tab = widget.existingOnly ? _Tab.search : _Tab.add;
  bool    _busy    = false;
  String  _status  = '';
  String? _error;
  final   _found   = <_FoundNode>[];
  final   _onlineStatus = <String, bool>{};  // nodeId -> online
  final   _ipCtrl  = TextEditingController();

  @override
  void initState() {
    super.initState();
    _checkOnlineStatus();
  }

  Future<void> _checkOnlineStatus() async {
    final ns = context.read<NodeService>();
    for (final n in ns.nodes) {
      http.get(Uri.parse('http://${n.ip}/info'))
          .timeout(const Duration(seconds: 3))
          .then((_) {
            if (mounted) setState(() => _onlineStatus[n.id] = true);
          })
          .catchError((_) {
            if (mounted) setState(() => _onlineStatus[n.id] = false);
          });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(tr(widget.existingOnly ? 'Wyszukaj moje nody'
              : widget.addOnly ? 'Dodaj node' : 'Nody'))),
      body: Column(children: [
        if (!widget.addOnly) _buildTabs(),
        Expanded(child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: switch (_tab) {
            _Tab.add  => _buildNodes(),
            _Tab.search => _buildSearch(),
            _Tab.manual => _buildManual(),
          },
        )),
      ]),
    );
  }

  Widget _buildTabs() => Row(children: widget.existingOnly
    ? [
        _tabBtn(Icons.wifi_find,     tr('Szukaj'),  _Tab.search),
        _tabBtn(Icons.edit_outlined, tr('Ręcznie'), _Tab.manual),
      ]
    : [
        _tabBtn(Icons.add_circle_outline, tr('Dodaj'), _Tab.add),
        _tabBtn(Icons.wifi_find,     tr('Szukaj'),  _Tab.search),
        _tabBtn(Icons.edit_outlined, tr('Ręcznie'), _Tab.manual),
      ]);

  Widget _tabBtn(IconData icon, String label, _Tab t) => Expanded(
    child: GestureDetector(
      onTap: () => setState(() { _tab = t; _error = null; _status = ''; }),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(
          color: _tab == t ? AppTheme.teal : Colors.transparent, width: 2))),
        child: Column(children: [
          Icon(icon, size: 18, color: _tab == t ? AppTheme.teal : AppTheme.muted),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(fontSize: 11,
              color: _tab == t ? AppTheme.teal : AppTheme.muted)),
        ]),
      ),
    ),
  );

  // ── NODY ─────────────────────────────────────────────────
  Widget _buildNodes() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 8),
      // Instrukcja
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Jak dodać node?'),
              style: const TextStyle(color: AppTheme.text,
                  fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 12),
          _instruction(Icons.memory_outlined,
              tr('ESP32 musi być włączony i w trybie konfiguracji (świeci LED)')),
          _instruction(Icons.bluetooth,
              tr('Bluetooth musi być włączony na telefonie')),
          _instruction(Icons.wifi_outlined,
              tr('Telefon musi być połączony z siecią WiFi z dostępem do internetu')),
          _instruction(Icons.router_outlined,
              tr('WiFi, do której podłączysz node, musi być w zasięgu')),
          _instruction(Icons.lock_outlined,
              tr('Przygotuj nazwę sieci (SSID) i hasło WiFi')),
        ]),
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const SetupScreen())),
        icon: const Icon(Icons.add, size: 18),
        label: Text(tr('Dodaj nowy node przez BLE'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        style: FilledButton.styleFrom(
            backgroundColor: AppTheme.teal,
            foregroundColor: AppTheme.bg,
            padding: const EdgeInsets.symmetric(vertical: 16)),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const GatewayScreen())),
        icon: const Icon(Icons.cell_tower, size: 18),
        label: Text(tr('Dodaj bramę LoRaWAN (np. Crankk)')),
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
      ),
      if (_error != null) ...[const SizedBox(height: 12), _errorBox(_error!)],
    ]);
  }

  Widget _instruction(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: AppTheme.teal, size: 18),
      const SizedBox(width: 10),
      Expanded(child: Text(text,
          style: const TextStyle(color: AppTheme.muted, fontSize: 13))),
    ]),
  );

  Widget _buildSearch() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Text(tr('Szuka nodów SENSMOS w sieci WiFi.'),
        style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
    const SizedBox(height: 16),
    FilledButton.icon(
      onPressed: _busy ? null : _startSearch,
      icon: _busy
          ? const SizedBox(width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.bg))
          : const Icon(Icons.search, size: 16),
      label: Text(_busy ? _status : tr('Szukaj w sieci')),
      style: FilledButton.styleFrom(
          backgroundColor: AppTheme.teal, foregroundColor: AppTheme.bg),
    ),
    const SizedBox(height: 16),
    ..._found.map((n) => _foundCard(n)),
    if (_error != null) _errorBox(_error!),
  ]);

  Future<void> _startSearch() async {
    setState(() { _busy = true; _status = tr('Skanowanie...'); _found.clear(); _error = null; });
    try {
      final ble     = context.read<BleService>();
      final results = await ble.discoverAllNodes(timeout: const Duration(seconds: 12));
      if (!mounted) return;
      if (results.isNotEmpty) {
        final savedIps = context.read<NodeService>().nodes.map((n) => n.ip).toSet();
        for (final r in results) {
          final ip = r['ip']!;
          try {
            final res = await http.get(Uri.parse('http://$ip/info'))
                .timeout(const Duration(seconds: 3));
            final j = jsonDecode(res.body) as Map<String, dynamic>;
            final id = j['device_id'] ?? ip;
            // Oznacz czy już zapisany
            final alreadySaved = savedIps.contains(ip) ||
                context.read<NodeService>().nodes.any((n) => n.id == id);
            setState(() => _found.add(_FoundNode(
              ip: ip,
              deviceId: id,
              firmware: j['firmware'] ?? j['version'] ?? '?',
              alreadySaved: alreadySaved,
            )));
          } catch (_) {
            setState(() => _found.add(_FoundNode(ip: ip, deviceId: ip, firmware: '?')));
          }
        }
      } else {
        setState(() => _error = tr('Nie znaleziono nodów w sieci.'));
      }
    } catch (e) {
      if (mounted) setState(() => _error = tr('Błąd: %s', [e]));
    } finally {
      if (mounted) setState(() { _busy = false; _status = ''; });
    }
  }

  Widget _foundCard(_FoundNode n) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      leading: const Icon(Icons.sensors, color: AppTheme.teal),
      title: Text(n.deviceId.length > 12 ? '${n.deviceId.substring(0,12)}...' : n.deviceId,
          style: const TextStyle(color: AppTheme.text, fontSize: 13)),
      subtitle: Text(n.ip,
          style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
      trailing: n.alreadySaved
          ? Chip(
              label: Text(tr('Dodany'), style: const TextStyle(fontSize: 12)),
              backgroundColor: const Color(0xFF1E1E1E),
            )
          : FilledButton(
              onPressed: () => _connectFound(n),
              style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.teal, foregroundColor: AppTheme.bg,
                  padding: const EdgeInsets.symmetric(horizontal: 12)),
              child: Text(tr('Dodaj')),
            ),
    ),
  );

  Future<void> _connectFound(_FoundNode n) async {
    final pin = await _askPin();
    if (pin == null || !mounted) return;
    await _doConnect(n.ip, pin, n.deviceId);
  }

  // ── RĘCZNIE ───────────────────────────────────────────────
  Widget _buildManual() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Text(tr('Wpisz IP noda — PIN podasz, gdy urządzenie się odnajdzie.'),
        style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
    const SizedBox(height: 20),
    _field(tr('Adres IP noda'), Icons.router_outlined, _ipCtrl,
        type: TextInputType.number),
    const SizedBox(height: 16),
    if (_busy) ...[
      Row(children: [
        const SizedBox(width: 16, height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.teal)),
        const SizedBox(width: 10),
        Text(_status, style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
      ]),
      const SizedBox(height: 8),
    ],
    if (_error != null) ...[_errorBox(_error!), const SizedBox(height: 8)],
    FilledButton(
      onPressed: _busy ? null : _connectManual,
      style: FilledButton.styleFrom(
          backgroundColor: AppTheme.teal, foregroundColor: AppTheme.bg),
      child: Text(tr('Szukaj')),
    ),
  ]);

  Future<void> _connectManual() async {
    final ip = _ipCtrl.text.trim();
    if (ip.isEmpty) { setState(() => _error = tr('Wpisz adres IP')); return; }
    setState(() { _busy = true; _status = tr('Szukam noda...'); _error = null; });
    String deviceId;
    try {
      final res = await http.get(Uri.parse('http://$ip/info'))
          .timeout(const Duration(seconds: 5));
      deviceId = (jsonDecode(res.body) as Map<String, dynamic>)['device_id'] ?? '';
    } catch (_) {
      if (mounted) setState(() { _busy = false; _status = ''; _error = tr('Brak odpowiedzi z %s.', [ip]); });
      return;
    }
    if (!mounted) return;
    setState(() { _busy = false; _status = ''; });
    final pin = await _askPin();          // PIN dopiero po znalezieniu noda
    if (pin == null || !mounted) return;
    await _doConnect(ip, pin, deviceId);
  }

  Future<void> _doConnect(String ip, String pin, String deviceId) async {
    setState(() { _busy = true; _status = tr('Dodaję...'); });
    try {
      String finalId = deviceId;
      if (finalId.isEmpty || finalId == ip) {
        try {
          final res = await http.get(Uri.parse('http://$ip/info'))
              .timeout(const Duration(seconds: 5));
          final j = jsonDecode(res.body) as Map<String,dynamic>;
          if ((j['device_id'] as String?)?.isNotEmpty == true) {
            finalId = j['device_id'] as String;
          }
        } catch (_) {}
      }
      // Weryfikacja PINu: /config wymaga Bearer PIN — 200 = OK, inaczej zly PIN.
      setState(() => _status = tr('Sprawdzam PIN...'));
      try {
        final vr = await http.get(Uri.parse('http://$ip/config'),
            headers: {'Authorization': 'Bearer $pin'}).timeout(const Duration(seconds: 5));
        if (vr.statusCode != 200) {
          if (mounted) setState(() { _busy = false; _status = ''; _error = tr('Zły PIN'); });
          return;
        }
      } catch (_) {
        if (mounted) setState(() { _busy = false; _status = ''; _error = tr('Brak odpowiedzi z %s.', [ip]); });
        return;
      }
      if (!mounted) return;
      final ns        = context.read<NodeService>();
      final bloc      = context.read<CoreBloc>();
      final navigator = Navigator.of(context);
      final messenger = ScaffoldMessenger.of(context);
      await ns.addNode(ip, pin, finalId);
      messenger.showSnackBar(SnackBar(content: Text(tr('Node dodany'))));
      bloc.add(NodeConnected());          // przełącza na ekran główny (phase=ready)
      navigator.popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = tr('Błąd: %s', [e]); });
    }
  }

  Future<String?> _askPin() => showDialog<String>(context: context, builder: (_) {
    final c = TextEditingController(text: '123456');
    return AlertDialog(
      backgroundColor: AppTheme.card,
      title: Text(tr('PIN noda'), style: const TextStyle(color: AppTheme.text)),
      content: TextField(controller: c, keyboardType: TextInputType.number,
          style: const TextStyle(color: AppTheme.text),
          decoration: const InputDecoration(labelText: 'PIN'),
          autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
            child: Text(tr('Anuluj'))),
        TextButton(onPressed: () => Navigator.pop(context, c.text),
            child: const Text('OK', style: TextStyle(color: AppTheme.teal))),
      ],
    );
  });

  Widget _pill(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12)),
    child: Text(label, style: TextStyle(fontSize: 11, color: color)),
  );

  Widget _errorBox(String msg) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: AppTheme.red.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.red.withOpacity(0.3))),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.error_outline, color: AppTheme.red, size: 16),
      const SizedBox(width: 8),
      Expanded(child: Text(msg,
          style: const TextStyle(color: AppTheme.red, fontSize: 13))),
    ]),
  );

  TextField _field(String label, IconData icon, TextEditingController ctrl,
      {bool obscure = false, TextInputType? type}) =>
    TextField(
      controller: ctrl, obscureText: obscure, keyboardType: type,
      style: const TextStyle(color: AppTheme.text),
      decoration: InputDecoration(
        labelText: label, labelStyle: const TextStyle(color: AppTheme.muted),
        prefixIcon: Icon(icon, color: AppTheme.muted),
        filled: true, fillColor: AppTheme.card,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppTheme.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppTheme.border)),
      ),
    );

  @override
  void dispose() { _ipCtrl.dispose(); super.dispose(); }
}
