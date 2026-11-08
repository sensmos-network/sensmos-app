import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/node_service.dart';

/// Uniwersalny Modbus RTU (RS485) — GET/POST /node/modbus na nodzie, w LAN za PIN-em.
/// Most Modbus TCP (port 502) dla HA/Node-RED + własna lista rejestrów odpytywana przez nod (encje own.mb_*).
class ModbusScreen extends StatefulWidget {
  final SavedNode node;
  final String pin;
  const ModbusScreen({super.key, required this.node, required this.pin});

  @override
  State<ModbusScreen> createState() => _ModbusScreenState();
}

const _types = ['u16', 's16', 'u32', 's32', 'f32', 'temp'];

class _ModbusScreenState extends State<ModbusScreen> {
  bool _loading = true, _saving = false, _on = false, _bridge = false, _write = false, _client = false;
  String? _error;
  String _parity = 'N';
  List<Map<String, dynamic>> _presets = [], _regs = [];
  Map<String, dynamic> _values = {};
  int _ok = 0, _err = 0, _age = -1, _brOk = 0, _brErr = 0;
  final _rx = TextEditingController(text: '16'), _tx = TextEditingController(text: '17'),
      _de = TextEditingController(text: '-1'), _slave = TextEditingController(text: '1'), _baud = TextEditingController(text: '9600');
  Timer? _t;

  Map<String, String> get _h => {'Authorization': 'Bearer ${widget.pin}', 'Content-Type': 'application/json'};
  Uri get _url => Uri.parse('http://${widget.node.ip}/node/modbus');

  @override
  void initState() {
    super.initState();
    _load();
    _t = Timer.periodic(const Duration(seconds: 10), (_) { if ((_on || _bridge) && !_saving) _load(quiet: true); });
  }

  @override
  void dispose() { _t?.cancel(); super.dispose(); }

  int _i(dynamic v, int d) => v is int ? v : int.tryParse('$v') ?? d;

  void _apply(Map<String, dynamic> j, {bool keepForm = false}) {
    if (!keepForm) {
      _on = j['on'] == true; _bridge = j['bridge'] == true; _write = j['write'] == true;
      _rx.text = '${j['rx'] ?? 16}'; _tx.text = '${j['tx'] ?? 17}'; _de.text = '${j['de'] ?? -1}';
      _slave.text = '${j['slave'] ?? 1}'; _baud.text = '${j['baud'] ?? 9600}'; _parity = (j['parity'] as String?) ?? 'N';
      _regs = ((j['regs'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    _presets = ((j['presets'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    _values = (j['values'] as Map<String, dynamic>?) ?? {};
    _ok = _i(j['ok'], 0); _err = _i(j['err'], 0); _age = _i(j['age_s'], -1);
    _brOk = _i(j['br_ok'], 0); _brErr = _i(j['br_err'], 0); _client = j['client'] == true;
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final r = await http.get(_url, headers: _h).timeout(const Duration(seconds: 6));
      if (r.statusCode == 404) throw tr('Ten nod ma za stary firmware — Modbus wymaga nowszej wersji');
      if (r.statusCode != 200) throw tr('Nod odpowiedział %s', [r.statusCode]);
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() { _apply(j, keepForm: quiet); _error = null; });
    } catch (e) {
      if (mounted && !quiet) setState(() => _error = '$e');
    } finally {
      if (mounted && !quiet) setState(() => _loading = false);
    }
  }

  Future<void> _save({String? preset}) async {
    setState(() => _saving = true);
    try {
      final body = <String, dynamic>{
        'on': _on, 'bridge': _bridge, 'write': _write,
        'rx': int.tryParse(_rx.text) ?? 16, 'tx': int.tryParse(_tx.text) ?? 17, 'de': int.tryParse(_de.text) ?? -1,
        'baud': int.tryParse(_baud.text) ?? 9600, 'parity': _parity, 'slave': int.tryParse(_slave.text) ?? 1,
        if (preset != null) 'preset': preset else 'regs': _regs,
      };
      final r = await http.post(_url, headers: _h, body: jsonEncode(body)).timeout(const Duration(seconds: 6));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) throw tr('Nod odrzucił ustawienia: %s', [j['error'] ?? r.statusCode]);
      if (!mounted) return;
      setState(() => _apply(j));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Zapisano'))));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: AppTheme.red));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _dec(String l) => InputDecoration(labelText: l, labelStyle: const TextStyle(color: AppTheme.muted), isDense: true,
      enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.border)),
      focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.teal)));

  Widget _num(TextEditingController c, String l) => Expanded(child: TextField(controller: c, keyboardType: TextInputType.number,
      style: const TextStyle(color: AppTheme.text), decoration: _dec(l)));

  Widget _h2(String t) => Padding(padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(t, style: const TextStyle(color: AppTheme.text, fontSize: 15, fontWeight: FontWeight.w600)));

  Widget _muted(String t, {Color color = AppTheme.muted}) => Text(t, style: TextStyle(color: color, fontSize: 12, height: 1.35));

  Future<void> _editReg([int? idx]) async {
    final r = idx == null ? <String, dynamic>{'f': 3, 't': 0, 'k': 1} : Map<String, dynamic>.from(_regs[idx]);
    final n = TextEditingController(text: '${r['n'] ?? ''}'), a = TextEditingController(text: r['a'] == null ? '' : '${r['a']}'),
        k = TextEditingController(text: '${r['k'] ?? 1}'), u = TextEditingController(text: '${r['u'] ?? ''}'),
        s = TextEditingController(text: r['s'] == null ? '' : '${r['s']}');
    int f = _i(r['f'], 3), t = _i(r['t'], 0);
    bool lo = r['o'] == true;
    final res = await showDialog<Map<String, dynamic>?>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, set) => AlertDialog(
      backgroundColor: AppTheme.card,
      title: Text(idx == null ? tr('Nowy rejestr') : tr('Rejestr'), style: const TextStyle(color: AppTheme.text)),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: n, style: const TextStyle(color: AppTheme.text), decoration: _dec(tr('Nazwa (np. moc_pv)'))),
        const SizedBox(height: 8),
        Row(children: [_num(a, tr('Adres')), const SizedBox(width: 8), _num(s, tr('Slave (puste = domyślny)'))]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: DropdownButtonFormField<int>(initialValue: f, dropdownColor: AppTheme.card, decoration: _dec(tr('Funkcja')),
              items: const [DropdownMenuItem(value: 3, child: Text('03 holding')), DropdownMenuItem(value: 4, child: Text('04 input'))],
              onChanged: (v) => set(() => f = v ?? 3))),
          const SizedBox(width: 8),
          Expanded(child: DropdownButtonFormField<int>(initialValue: t, dropdownColor: AppTheme.card, decoration: _dec(tr('Typ')),
              items: [for (var i = 0; i < _types.length; i++) DropdownMenuItem(value: i, child: Text(_types[i]))],
              onChanged: (v) => set(() => t = v ?? 0))),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(controller: k, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              style: const TextStyle(color: AppTheme.text), decoration: _dec(tr('Mnożnik')))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: u, style: const TextStyle(color: AppTheme.text), decoration: _dec(tr('Jednostka')))),
        ]),
        if (t >= 2 && t <= 4) CheckboxListTile(contentPadding: EdgeInsets.zero, value: lo, onChanged: (v) => set(() => lo = v ?? false),
            title: Text(tr('Młodsze słowo pierwsze'), style: const TextStyle(color: AppTheme.text, fontSize: 13))),
      ])),
      actions: [
        if (idx != null) TextButton(onPressed: () => Navigator.pop(ctx, {'_del': true}), child: Text(tr('Usuń'), style: const TextStyle(color: AppTheme.red))),
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anuluj'))),
        FilledButton(onPressed: () {
          final addr = int.tryParse(a.text);
          if (addr == null || addr < 0 || addr > 65535) return;
          Navigator.pop(ctx, {
            'n': n.text.trim(), if (r['e'] != null) 'e': r['e'], if (int.tryParse(s.text) != null) 's': int.parse(s.text),
            'f': f, 'a': addr, 't': t, if (lo && t >= 2 && t <= 4) 'o': true,
            'k': double.tryParse(k.text.replaceAll(',', '.')) ?? 1, 'u': u.text.trim(),
          });
        }, child: Text(tr('OK'))),
      ],
    )));
    if (res == null || !mounted) return;
    setState(() {
      if (res['_del'] == true) { _regs.removeAt(idx!); }
      else if (idx == null) { _regs.add(res); }
      else { _regs[idx] = res; }
    });
  }

  String _regLine(Map<String, dynamic> r) =>
      '${_i(r['f'], 3) == 4 ? 'IR' : 'HR'} ${r['a']} · ${_types[_i(r['t'], 0).clamp(0, 5)]}${r['k'] != null && '${r['k']}' != '1' ? ' × ${r['k']}' : ''} ${r['u'] ?? ''}';

  @override
  Widget build(BuildContext context) {
    final ip = widget.node.ip;
    return Scaffold(
      appBar: AppBar(title: const Text('Modbus RS485')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.teal))
          : _error != null
              ? ListView(padding: const EdgeInsets.all(16), children: [Card(child: Padding(padding: const EdgeInsets.all(16),
                  child: Text(_error!, style: const TextStyle(color: AppTheme.red, fontSize: 13))))])
              : ListView(padding: const EdgeInsets.all(16), children: [
                  _muted(tr('Podłącz moduł RS485 (np. MAX485) do urządzenia (falownik, licznik, pompa ciepła, rekuperator…) i do pinów ESP32. Wszystko działa w Twojej sieci, bez chmury.')),
                  _h2(tr('Połączenie RS485')),
                  Row(children: [_num(_rx, 'RX'), const SizedBox(width: 8), _num(_tx, 'TX'), const SizedBox(width: 8), _num(_de, 'DE/RE')]),
                  const SizedBox(height: 8),
                  Row(children: [
                    _num(_baud, tr('Prędkość')), const SizedBox(width: 8),
                    Expanded(child: DropdownButtonFormField<String>(initialValue: _parity, dropdownColor: AppTheme.card, decoration: _dec(tr('Parzystość')),
                        items: const [DropdownMenuItem(value: 'N', child: Text('8N1')), DropdownMenuItem(value: 'E', child: Text('8E1')), DropdownMenuItem(value: 'O', child: Text('8O1'))],
                        onChanged: (v) => setState(() => _parity = v ?? 'N'))),
                    const SizedBox(width: 8), _num(_slave, 'Slave'),
                  ]),
                  const SizedBox(height: 4),
                  _muted(tr('DE/RE: -1, gdy moduł RS485 przełącza kierunek sam.')),

                  _h2(tr('Most Modbus TCP')),
                  SwitchListTile(contentPadding: EdgeInsets.zero, value: _bridge, activeThumbColor: AppTheme.teal,
                      onChanged: (v) => setState(() => _bridge = v),
                      title: Text(tr('Włącz most (port 502)'), style: const TextStyle(color: AppTheme.text, fontSize: 14)),
                      subtitle: _muted(tr('Home Assistant, Node-RED i inne programy łączą się z nodem jak z bramką Modbus TCP i czytają dowolne rejestry.'))),
                  if (_bridge) ...[
                    SwitchListTile(contentPadding: EdgeInsets.zero, value: _write, activeThumbColor: AppTheme.amber,
                        onChanged: (v) => setState(() => _write = v),
                        title: Text(tr('Zezwól na zapis'), style: const TextStyle(color: AppTheme.text, fontSize: 14)),
                        subtitle: _muted(tr('Pozwala programom w sieci zmieniać ustawienia urządzenia. Włącz tylko, jeśli wiesz, co robisz.'), color: _write ? AppTheme.amber : AppTheme.muted)),
                    Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: SelectableText('modbus:\n  - name: sensmos\n    type: tcp\n    host: $ip\n    port: 502',
                            style: const TextStyle(color: AppTheme.text, fontFamily: 'monospace', fontSize: 12))),
                        IconButton(icon: const Icon(Icons.copy, size: 18), onPressed: () =>
                            Clipboard.setData(ClipboardData(text: 'modbus:\n  - name: sensmos\n    type: tcp\n    host: $ip\n    port: 502\n'))),
                      ]),
                      _muted(tr('Wklej do configuration.yaml w Home Assistancie i dopisz własne czujniki (sensors:) z adresami rejestrów.')),
                      const SizedBox(height: 6),
                      _muted(_client ? tr('Klient połączony · odpowiedzi %s · błędy %s', [_brOk, _brErr]) : tr('Brak połączonego klienta')),
                    ]))),
                  ],

                  _h2(tr('Odczyt przez nod')),
                  SwitchListTile(contentPadding: EdgeInsets.zero, value: _on, activeThumbColor: AppTheme.teal,
                      onChanged: (v) => setState(() => _on = v),
                      title: Text(tr('Nod sam czyta rejestry co 10 s'), style: const TextStyle(color: AppTheme.text, fontSize: 14)),
                      subtitle: _muted(tr('Wartości pojawiają się na karcie noda, w integracji Sensmos w HA i w danych sieci.'))),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final p in _presets) ActionChip(label: Text('${p['label']}', style: const TextStyle(fontSize: 12)),
                        onPressed: _saving ? null : () => _save(preset: '${p['id']}')),
                  ]),
                  const SizedBox(height: 4),
                  _muted(tr('Gotowa lista podmienia rejestry i od razu zapisuje.')),
                  const SizedBox(height: 8),
                  for (var i = 0; i < _regs.length; i++) ListTile(dense: true, contentPadding: EdgeInsets.zero,
                      onTap: () => _editReg(i),
                      title: Text('${_regs[i]['n']}', style: const TextStyle(color: AppTheme.text, fontSize: 13)),
                      subtitle: Text(_regLine(_regs[i]), style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                      trailing: _values.containsKey('${_regs[i]['n']}')
                          ? Text('${_values['${_regs[i]['n']}']}', style: const TextStyle(color: AppTheme.teal, fontSize: 14, fontWeight: FontWeight.w600))
                          : const Icon(Icons.edit_outlined, size: 16, color: AppTheme.muted)),
                  if (_regs.length < 16) TextButton.icon(onPressed: () => _editReg(), icon: const Icon(Icons.add), label: Text(tr('Dodaj rejestr'))),
                  if (_on && _regs.isNotEmpty) _muted(_age < 0 ? tr('Czekam na pierwszą odpowiedź… (błędy: %s)', [_err])
                      : tr('Ostatni odczyt %s s temu · udane %s · błędy %s', [_age, _ok, _err]), color: _age < 0 ? AppTheme.amber : AppTheme.muted),
                  const SizedBox(height: 16),
                  SizedBox(width: double.infinity, child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: AppTheme.teal, foregroundColor: Colors.black),
                    onPressed: _saving ? null : () => _save(), child: Text(tr('Zapisz')))),
                ]),
    );
  }
}
