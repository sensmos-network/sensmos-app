import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/node_service.dart';

/// Falownik PV po RS485 (Modbus RTU) — GET/POST /node/inverter na nodzie, w LAN za PIN-em.
/// Firmware tylko czyta rejestry; odczyty idą jako natywne encje energii (karta noda, HA, sieć).
class InverterScreen extends StatefulWidget {
  final SavedNode node;
  final String pin;
  const InverterScreen({super.key, required this.node, required this.pin});

  @override
  State<InverterScreen> createState() => _InverterScreenState();
}

class _InverterScreenState extends State<InverterScreen> {
  bool _loading = true, _saving = false, _on = false;
  String? _error, _model;
  List<String> _models = [];
  Map<String, dynamic> _values = {};
  int _ok = 0, _err = 0, _age = -1;
  final _rx = TextEditingController(text: '16'), _tx = TextEditingController(text: '17'),
      _de = TextEditingController(text: '-1'), _slave = TextEditingController(text: '1');
  Timer? _t;

  Map<String, String> get _h => {'Authorization': 'Bearer ${widget.pin}', 'Content-Type': 'application/json'};

  @override
  void initState() {
    super.initState();
    _load();
    _t = Timer.periodic(const Duration(seconds: 10), (_) { if (_on && !_saving) _load(quiet: true); });
  }

  @override
  void dispose() { _t?.cancel(); super.dispose(); }

  void _apply(Map<String, dynamic> j) {
    _on = j['on'] == true;
    _models = ((j['models'] as List?) ?? []).map((e) => '$e').toList();
    _model = (j['model'] as String?) ?? (_models.isNotEmpty ? _models.first : null);
    _rx.text = '${j['rx'] ?? 16}'; _tx.text = '${j['tx'] ?? 17}'; _de.text = '${j['de'] ?? -1}'; _slave.text = '${j['slave'] ?? 1}';
    _values = (j['values'] as Map<String, dynamic>?) ?? {};
    _ok = (j['ok'] ?? 0) as int; _err = (j['err'] ?? 0) as int; _age = (j['age_s'] ?? -1) as int;
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final r = await http.get(Uri.parse('http://${widget.node.ip}/node/inverter'), headers: _h).timeout(const Duration(seconds: 6));
      if (r.statusCode == 404) throw tr('Ten nod ma za stary firmware — falownik wymaga nowszej wersji');
      if (r.statusCode != 200) throw tr('Nod odpowiedział %s', [r.statusCode]);
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() { _apply(j); _error = null; });
    } catch (e) {
      if (mounted && !quiet) setState(() => _error = '$e');
    } finally {
      if (mounted && !quiet) setState(() => _loading = false);
    }
  }

  Future<void> _save(bool on) async {
    setState(() => _saving = true);
    try {
      final r = await http.post(Uri.parse('http://${widget.node.ip}/node/inverter'), headers: _h, body: jsonEncode({
        'on': on, 'model': _model, 'rx': int.tryParse(_rx.text) ?? 16, 'tx': int.tryParse(_tx.text) ?? 17,
        'de': int.tryParse(_de.text) ?? -1, 'baud': 9600, 'slave': int.tryParse(_slave.text) ?? 1,
      })).timeout(const Duration(seconds: 6));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) throw tr('Nod odrzucił ustawienia: %s', [j['error'] ?? r.statusCode]);
      if (!mounted) return;
      setState(() => _apply(j));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: AppTheme.red));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _dec(String l) => InputDecoration(labelText: l, labelStyle: const TextStyle(color: AppTheme.muted),
      enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.border)),
      focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.teal)));

  Widget _num(TextEditingController c, String l) => Expanded(child: TextField(controller: c, keyboardType: TextInputType.number,
      style: const TextStyle(color: AppTheme.text), decoration: _dec(l)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Falownik PV'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.teal))
          : ListView(padding: const EdgeInsets.all(16), children: [
              Text(tr('Podłącz moduł RS485 (np. MAX485) do portu BMS/RS485 falownika i do pinów ESP32. Nod tylko czyta dane falownika, niczego w nim nie zmienia.'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.35)),
              const SizedBox(height: 12),
              if (_error != null) Card(child: Padding(padding: const EdgeInsets.all(16),
                  child: Text(_error!, style: const TextStyle(color: AppTheme.red, fontSize: 13)))),
              if (_error == null) ...[
                DropdownButtonFormField<String>(key: ValueKey(_model),
                  initialValue: _models.contains(_model) ? _model : null, dropdownColor: AppTheme.card, decoration: _dec(tr('Model falownika')),
                  items: _models.map((m) => DropdownMenuItem(value: m, child: Text(_label(m), style: const TextStyle(color: AppTheme.text)))).toList(),
                  onChanged: (v) => setState(() => _model = v)),
                const SizedBox(height: 10),
                Row(children: [_num(_rx, 'RX'), const SizedBox(width: 8), _num(_tx, 'TX'), const SizedBox(width: 8), _num(_de, 'DE/RE'), const SizedBox(width: 8), _num(_slave, 'Slave')]),
                const SizedBox(height: 4),
                Text(tr('DE/RE: -1, gdy moduł RS485 przełącza kierunek sam.'), style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: AppTheme.teal, foregroundColor: Colors.black),
                    onPressed: _saving || _model == null ? null : () => _save(true),
                    child: Text(_on ? tr('Zapisz') : tr('Włącz odczyt')))),
                  if (_on) ...[const SizedBox(width: 8), Expanded(child: OutlinedButton(onPressed: _saving ? null : () => _save(false), child: Text(tr('Wyłącz'))))],
                ]),
                if (_on) ...[
                  const SizedBox(height: 16),
                  Text(_age < 0 ? tr('Czekam na pierwszą odpowiedź falownika… (błędy: %s)', [_err])
                                : tr('Ostatni odczyt %s s temu · udane %s · błędy %s', [_age, _ok, _err]),
                      style: TextStyle(color: _age < 0 ? AppTheme.amber : AppTheme.muted, fontSize: 12)),
                  const SizedBox(height: 8),
                  ..._values.entries.map((e) => ListTile(dense: true, contentPadding: EdgeInsets.zero,
                      title: Text(e.key, style: const TextStyle(color: AppTheme.text, fontSize: 13)),
                      trailing: Text('${e.value}', style: const TextStyle(color: AppTheme.teal, fontSize: 14, fontWeight: FontWeight.w600)))),
                ],
              ],
            ]),
    );
  }

  String _label(String id) => switch (id) {
        'deye1' => 'Deye / Sunsynk 1-fazowy (SG0xLP1)',
        'deye3' => 'Deye / Sunsynk 3-fazowy (SG04LP3)',
        _ => id,
      };
}
