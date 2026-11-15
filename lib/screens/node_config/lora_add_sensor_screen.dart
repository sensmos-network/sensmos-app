import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/node_service.dart';

/// „Dodaj czujnik LoRa” (pomysły LoRa, dzień 4): w 30 s gotowy YAML dla komponentu ESPHome `sensmos_lora`.
/// Apka zna id8 bazy (pierwsze 8 hex device_id) i wolny numer czujnika (sub z odebranych ramek).
/// Klucza noda nie da się odczytać (zostaje TYLKO na nodzie), więc: brak klucza → apka losuje frazę i zapisuje ją
/// na nodzie (POST /node/lora_rx); klucz już jest → użytkownik wpisuje swoją frazę albo świadomie ustawia nową.
class LoraAddSensorScreen extends StatefulWidget {
  final SavedNode node;
  final String pin;
  final bool keySet;
  final Set<int> usedSubs;
  const LoraAddSensorScreen(
      {super.key, required this.node, required this.pin, required this.keySet, this.usedSubs = const {}});

  @override
  State<LoraAddSensorScreen> createState() => _LoraAddSensorScreenState();
}

/// Płytki z SX1262, dla których przepis jest sprawdzony (piny jak w examples/ repo sensmos-esphome).
class _Board {
  final String id, name, esp, pins;
  final Map<String, String> io;   // wolne piny na czujniki: temp, door, leak
  const _Board(this.id, this.name, this.esp, this.pins, this.io);
}

const _boards = [
  _Board('heltec_v3', 'Heltec WiFi LoRa 32 V3', 'heltec_wifi_lora_32_V3',
      'spi:\n  clk_pin: GPIO9\n  mosi_pin: GPIO10\n  miso_pin: GPIO11\n\nsx126x:\n  id: lora\n  cs_pin: GPIO8\n  rst_pin: GPIO12\n  busy_pin: GPIO13\n  dio1_pin: GPIO14\n  hw_version: sx1262\n  rf_switch: true\n  tcxo_voltage: 1_8V\n',
      {'temp': 'GPIO6', 'door': 'GPIO5', 'leak': 'GPIO7'}),
  _Board('xiao_s3', 'Seeed XIAO ESP32-S3 + Wio-SX1262', 'seeed_xiao_esp32s3',
      'spi:\n  clk_pin: GPIO7\n  mosi_pin: GPIO9\n  miso_pin: GPIO8\n\nsx126x:\n  id: lora\n  cs_pin: GPIO41\n  rst_pin: GPIO42\n  busy_pin: GPIO40\n  dio1_pin: GPIO39\n  hw_version: sx1262\n  rf_switch: true\n  tcxo_voltage: 1_8V\n',
      {'temp': 'GPIO2', 'door': 'GPIO3', 'leak': 'GPIO4'}),
];

/// Co czujnik mierzy: gotowe bloki sensor/binary_sensor + wpisy do sensmos_lora.
class _Kind {
  final String id, label, yaml, sensors, binary;
  const _Kind(this.id, this.label, this.yaml, {this.sensors = '', this.binary = ''});
}

const _kinds = [
  _Kind('temp', 'Temperatura (DS18B20)',
      'one_wire:\n  - platform: gpio\n    pin: {temp}\n\nsensor:\n  - platform: dallas_temp\n    id: temp\n    update_interval: 60s\n',
      sensors: '    - sensor: temp\n      key: t\n'),
  _Kind('door', 'Drzwi / brama (kontaktron)',
      'binary_sensor:\n  - platform: gpio\n    id: door\n    pin:\n      number: {door}\n      mode: INPUT_PULLUP\n    filters:\n      - delayed_on_off: 500ms\n',
      binary: '    - sensor: door\n      key: door\n'),
  _Kind('leak', 'Zalanie (sonda)',
      'binary_sensor:\n  - platform: gpio\n    id: leak\n    pin:\n      number: {leak}\n      inverted: true\n      mode: INPUT_PULLUP\n    filters:\n      - delayed_on: 2s\n',
      binary: '    - sensor: leak\n      key: leak\n'),
];

String _slug(String s) {
  final x = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]+'), '-').replaceAll(RegExp(r'-+'), '-');
  final t = x.replaceAll(RegExp(r'^-|-$'), '');
  return t.isEmpty ? 'czujnik-lora' : (t.length > 24 ? t.substring(0, 24) : t);
}

/// Plik ESPHome dla czujnika (publiczne do testu: test/lora_sensor_yaml_test.dart).
String loraSensorYaml({required String board, required Set<String> kinds, required String name, required String id8, required int sub, required String key}) {
  final b = _boards.firstWhere((x) => x.id == board, orElse: () => _boards.first);
  final ks = _kinds.where((k) => kinds.contains(k.id)).toList();
  if (key.isEmpty) key = 'TWOJA-FRAZA';
  // Bloki sensor:/binary_sensor: z kilku rodzajów łączymy pod jednym nagłówkiem.
  final other = StringBuffer(), sens = StringBuffer(), bins = StringBuffer();
  for (final k in ks) {
    final y = k.yaml.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => b.io[m[1]] ?? m[0]!);
    for (final part in y.split(RegExp(r'\n(?=[a-z_]+:\n)'))) {
      final p = part.endsWith('\n') ? part : '$part\n';
      if (p.startsWith('sensor:\n')) {
        sens.write(p.substring(8));
      } else if (p.startsWith('binary_sensor:\n')) {
        bins.write(p.substring(15));
      } else {
        other.write('$p\n');
      }
    }
  }
  final sSens = ks.map((k) => k.sensors).join();
  final sBin = ks.map((k) => k.binary).join();
  return '''# ${tr('Czujnik LoRa Sensmos z apki')}: ${b.name}
esphome:
  name: ${_slug(name)}

esp32:
  board: ${b.esp}
  framework:
    type: esp-idf

logger:

external_components:
  - source: github://sensmos-network/sensmos-esphome@main
    components: [sensmos_lora]

${b.pins}  # ${tr('Kanał domowy Sensmos (EU). Nie zmieniaj tych wartości.')}
  modulation: LORA
  frequency: 868.1MHz
  bandwidth: 125_0kHz
  spreading_factor: 11
  coding_rate: CR_4_5
  sync_value: [0x34, 0x44]
  preamble_size: 8
  crc_enable: true
  pa_power: 14

$other${sens.isNotEmpty ? 'sensor:\n$sens\n' : ''}${bins.isNotEmpty ? 'binary_sensor:\n$bins\n' : ''}sensmos_lora:
  hub: "$id8"
  sub: $sub
  key: "$key"
  update_interval: 10min
${sSens.isNotEmpty ? '  sensors:\n$sSens' : ''}${sBin.isNotEmpty ? '  binary_sensors:\n$sBin' : ''}''';
}


class _LoraAddSensorScreenState extends State<LoraAddSensorScreen> {
  final _keyCtrl = TextEditingController();
  late final TextEditingController _nameCtrl;
  late int _sub;
  String _board = _boards.first.id;
  final Set<String> _kindsOn = {'temp', 'door'};
  bool _busy = false;
  bool _keyOnNode = false;     // fraza z pola jest na pewno na nodzie (ustawiona tutaj)
  String? _msg;

  Map<String, String> get _auth => {'Authorization': 'Bearer ${widget.pin}'};
  String get _id8 => widget.node.id.length >= 8 ? widget.node.id.substring(0, 8).toLowerCase() : widget.node.id;

  @override
  void initState() {
    super.initState();
    _sub = 1;
    while (widget.usedSubs.contains(_sub) && _sub < 255) {
      _sub++;
    }
    _nameCtrl = TextEditingController(text: 'czujnik-lora-$_sub');
    if (!widget.keySet) _keyCtrl.text = _randomPhrase();
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  static String _randomPhrase() {
    const a = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    return List.generate(4, (_) => List.generate(5, (_) => a[r.nextInt(a.length)]).join()).join('-');
  }

  Future<void> _setKeyOnNode() async {
    final k = _keyCtrl.text.trim();
    if (k.length < 8) {
      setState(() => _msg = tr('Fraza musi mieć co najmniej 8 znaków'));
      return;
    }
    setState(() { _busy = true; _msg = null; });
    try {
      final r = await http.post(Uri.parse('http://${widget.node.ip}/node/lora_rx'),
              headers: {..._auth, 'Content-Type': 'application/json'}, body: jsonEncode({'key': k}))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200 && (jsonDecode(r.body) as Map)['key_set'] == true) {
        _keyOnNode = true;
        _msg = tr('Fraza zapisana na nodzie');
      } else {
        _msg = '${tr('Nie udało się zapisać frazy')} (${r.statusCode})';
      }
    } catch (_) {
      _msg = tr('Nie udało się zapisać frazy');
    }
    if (mounted) setState(() => _busy = false);
  }

  String _yaml() => loraSensorYaml(
      board: _board, kinds: _kindsOn, name: _nameCtrl.text, id8: _id8, sub: _sub, key: _keyCtrl.text.trim());

  @override
  Widget build(BuildContext context) {
    final yaml = _yaml();
    final needKey = widget.keySet && !_keyOnNode;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Dodaj czujnik LoRa'))),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
              tr('Apka przygotuje plik ESPHome dla płytki z radiem SX1262. Czujnik nadaje do tego noda, a encje pojawią się w Home Assistant jako sensor.sensmos_lora_<sub>_*.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _board,
            decoration: InputDecoration(labelText: tr('Płytka'), isDense: true),
            items: [for (final b in _boards) DropdownMenuItem(value: b.id, child: Text(b.name, style: const TextStyle(fontSize: 13)))],
            onChanged: (v) => setState(() => _board = v ?? _board),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final k in _kinds)
              FilterChip(
                label: Text(tr(k.label), style: const TextStyle(fontSize: 12)),
                selected: _kindsOn.contains(k.id),
                onSelected: (v) => setState(() => v ? _kindsOn.add(k.id) : _kindsOn.remove(k.id)),
              ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _nameCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(isDense: true, labelText: tr('Nazwa czujnika')),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Text('sub $_sub', style: const TextStyle(color: AppTheme.muted, fontSize: 12, fontFamily: 'monospace')),
          ]),
          const SizedBox(height: 14),
          Text(tr('Fraza-klucz'), style: const TextStyle(color: AppTheme.text, fontSize: 13)),
          const SizedBox(height: 4),
          Text(
              widget.keySet
                  ? tr('Ten node ma już klucz. Wpisz tę samą frazę, której używają Twoje czujniki. Ustawienie nowej odetnie dotychczasowe czujniki.')
                  : tr('Node nie ma jeszcze klucza. Apka wylosowała frazę: zapisz ją na nodzie, a ta sama trafi do pliku czujnika.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _keyCtrl,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                decoration: const InputDecoration(isDense: true),
                onChanged: (_) => setState(() => _keyOnNode = false),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _busy ? null : _setKeyOnNode,
              child: Text(widget.keySet ? tr('Ustaw nową') : tr('Zapisz na nodzie')),
            ),
          ]),
          if (_msg != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_msg!, style: const TextStyle(color: AppTheme.teal, fontSize: 11)),
            ),
          if (!widget.keySet && !_keyOnNode)
            Text(tr('Najpierw zapisz frazę na nodzie, inaczej node odrzuci ramki czujnika.'),
                style: const TextStyle(color: Colors.amber, fontSize: 11)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: AppTheme.card, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
            child: SelectableText(yaml, style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: AppTheme.text)),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Text(
                  needKey
                      ? tr('Fraza w pliku musi być tą samą, co na nodzie.')
                      : tr('Wklej plik w ESPHome (dodatek HA albo esphome.io/web), wgraj na płytkę i gotowe.'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
            ),
            FilledButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: yaml));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Skopiowano'))));
              },
              icon: const Icon(Icons.copy, size: 16),
              label: Text(tr('Kopiuj YAML')),
            ),
          ]),
          const SizedBox(height: 10),
          Text(
              tr('Odbiór: node w zasięgu w trybie Punkt słyszy czujnik cały czas (LoRa → Odbiór ramek). Hub 0.2.0-beta5 dodaje też alarm, gdy czujnik zamilknie.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
        ],
      ),
    );
  }
}
