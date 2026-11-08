import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/node_service.dart';

/// Czujniki widziane przez Hub w Home Assistancie (GET /sensors) i wybór, które udostępnić sieci
/// (POST /sensors/share). Wszystko w LAN z PIN-em; domyślnie nic nie jest udostępniane.
class HubSensorsScreen extends StatefulWidget {
  final SavedNode node;
  final String pin;
  const HubSensorsScreen({super.key, required this.node, required this.pin});

  @override
  State<HubSensorsScreen> createState() => _HubSensorsScreenState();
}

class _HubSensorsScreenState extends State<HubSensorsScreen> {
  bool _loading = true, _saving = false;
  String? _error, _via, _netError;
  List<Map<String, dynamic>> _sensors = [];
  final Set<String> _shared = {};
  Set<String> _saved = {};

  Map<String, String> get _h => {'Authorization': 'Bearer ${widget.pin}', 'Content-Type': 'application/json'};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; _netError = null; });
    try {
      final r = await http.get(Uri.parse('http://${widget.node.ip}/sensors'), headers: _h).timeout(const Duration(seconds: 8));
      if (r.statusCode == 404) throw tr('Ten Hub jest za stary — zaktualizuj go do 0.2.0-beta1 lub nowszego');
      if (r.statusCode != 200) throw tr('Hub odpowiedział %s', [r.statusCode]);
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final list = ((j['sensors'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _via = j['via'] as String?;
        _error = j['error'] as String?;
        _sensors = list;
        _shared..clear()..addAll(list.where((s) => s['shared'] == true).map((s) => s['entity_id'] as String));
        _saved = {..._shared};
      });
    } catch (e) {
      if (mounted) setState(() => _netError = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final r = await http.post(Uri.parse('http://${widget.node.ip}/sensors/share'), headers: _h,
          body: jsonEncode({'shared': _shared.toList()})).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) throw tr('Hub odpowiedział %s', [r.statusCode]);
      setState(() => _saved = {..._shared});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Zapisano wybór czujników'))));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: AppTheme.red));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _value(Map<String, dynamic> s) {
    final v = s['value'];
    if (v is bool) return v ? tr('włączony') : tr('wyłączony');
    return '$v${s['unit'] != null ? ' ${s['unit']}' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final dirty = _shared.length != _saved.length || !_shared.containsAll(_saved);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Czujniki Huba')), actions: [
        IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.teal))
          : ListView(padding: const EdgeInsets.all(16), children: [
              Text(tr('Hub czyta czujniki, które zna Twój Home Assistant. Zaznacz te, które chcesz udostępnić sieci Sensmos; reszta zostaje tylko w domu.'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.35)),
              const SizedBox(height: 12),
              if (_netError != null)
                Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(_netError!, style: const TextStyle(color: AppTheme.red, fontSize: 13))))
              else if (_sensors.isEmpty)
                Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(
                    _via == null
                        ? tr('Hub nie ma dostępu do Home Assistanta. W dodatku HA działa sam; w Dockerze ustaw HUB_HA_URL i HUB_HA_TOKEN.')
                        : _error != null ? tr('Home Assistant: %s', [_error!]) : tr('Home Assistant nie zgłasza żadnych czujników z wartością.'),
                    style: const TextStyle(color: AppTheme.text, fontSize: 13))))
              else
                ..._sensors.map((s) {
                  final id = s['entity_id'] as String;
                  return Card(child: SwitchListTile(
                    value: _shared.contains(id),
                    onChanged: (v) => setState(() => v ? _shared.add(id) : _shared.remove(id)),
                    title: Text('${s['name'] ?? id}', style: const TextStyle(color: AppTheme.text, fontSize: 14)),
                    subtitle: Text('${_value(s)} · $id', style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                  ));
                }),
              const SizedBox(height: 12),
              if (_sensors.isNotEmpty)
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppTheme.teal, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: (!dirty || _saving) ? null : _save,
                  child: Text(tr('Zapisz wybór (%s udostępnionych)', [_shared.length])),
                ),
              const SizedBox(height: 8),
              Text(tr('Udostępnione odczyty Hub wysyła do sieci co 5 minut, tak jak nod ESP32 (od Huba 0.2.0-beta1). Reszta czujników nie opuszcza domu.'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
            ]),
    );
  }
}
