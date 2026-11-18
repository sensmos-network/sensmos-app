import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config.dart';
import '../l10n.dart';
import '../theme.dart';

/// „Moja stacja pogodowa” na liście nodów: stacja WeatherXM użytkownika obok jego nodów.
/// Odczyt przez BE /v1/weather (publiczne dane WeatherXM, bez klucza); wybór stacji tylko w telefonie.
/// Ta sama karta co w panelu sensmos.com/my (public/my/weather.js). Pomysł społeczności:
/// FPozzi_, Fecoxa, IRON HELL, TreHac. Nubila i SkyX czekają na publiczny odczyt pojedynczej stacji.
class WeatherStationCard extends StatefulWidget {
  const WeatherStationCard({super.key});

  @override
  State<WeatherStationCard> createState() => _WeatherStationCardState();
}

const _t = <String, Map<String, String>>{
  'pl': {
    'h': 'Moja stacja pogodowa',
    'lede': 'Masz stację WeatherXM? Wklej jej link z eksploratora albo wpisz nazwę, a odczyty pokażą się obok nodów.',
    'ph': 'Link WeatherXM albo nazwa stacji',
    'add': 'Pokaż stację', 'change': 'Zmień', 'busy': 'Szukam…', 'hide': 'Ukryj',
    'notFound': 'Nie ma stacji WeatherXM o tej nazwie albo linku.',
    'many': 'W tej kratce jest kilka stacji. Wybierz swoją:',
    'err': 'WeatherXM teraz nie odpowiada. Spróbuj za minutę.',
    'inactive': 'nieaktywna',
    'src': 'Dane: WeatherXM. Stacja dalej zarabia w swojej sieci.',
    'soon': 'Nubila i SkyX dołączą, gdy udostępnią odczyty pojedynczych stacji.',
    'temperature': 'Temperatura', 'humidity': 'Wilgotność', 'pressure': 'Ciśnienie', 'wind_speed': 'Wiatr',
    'wind_gust': 'Porywy', 'wind_direction': 'Kierunek', 'rain_today': 'Opad dziś', 'uv_index': 'UV',
    'now': 'teraz', 'min': 'min temu', 'hr': 'h temu', 'day': 'd temu',
  },
  'en': {
    'h': 'My weather station',
    'lede': 'Run a WeatherXM station? Paste its explorer link or type its name and the readings show up next to your nodes.',
    'ph': 'WeatherXM link or station name',
    'add': 'Show station', 'change': 'Change', 'busy': 'Searching…', 'hide': 'Hide',
    'notFound': 'No WeatherXM station with that name or link.',
    'many': 'There are several stations in this cell. Pick yours:',
    'err': 'WeatherXM is not answering right now. Try again in a minute.',
    'inactive': 'inactive',
    'src': 'Data: WeatherXM. Your station keeps earning in its own network.',
    'soon': 'Nubila and SkyX: coming as soon as they publish per-station data.',
    'temperature': 'Temperature', 'humidity': 'Humidity', 'pressure': 'Pressure', 'wind_speed': 'Wind',
    'wind_gust': 'Gusts', 'wind_direction': 'Direction', 'rain_today': 'Rain today', 'uv_index': 'UV',
    'now': 'now', 'min': 'min ago', 'hr': 'h ago', 'day': 'd ago',
  },
  'de': {
    'h': 'Meine Wetterstation',
    'lede': 'Du betreibst eine WeatherXM-Station? Füge den Explorer-Link ein oder tippe ihren Namen, dann erscheinen die Messwerte neben deinen Nodes.',
    'ph': 'WeatherXM-Link oder Stationsname',
    'add': 'Station anzeigen', 'change': 'Ändern', 'busy': 'Suche…', 'hide': 'Ausblenden',
    'notFound': 'Keine WeatherXM-Station mit diesem Namen oder Link.',
    'many': 'In dieser Zelle gibt es mehrere Stationen. Wähle deine:',
    'err': 'WeatherXM antwortet gerade nicht. Versuch es in einer Minute noch einmal.',
    'inactive': 'inaktiv',
    'src': 'Daten: WeatherXM. Deine Station verdient in ihrem eigenen Netz weiter.',
    'soon': 'Nubila und SkyX kommen, sobald sie Daten einzelner Stationen veröffentlichen.',
    'temperature': 'Temperatur', 'humidity': 'Luftfeuchte', 'pressure': 'Luftdruck', 'wind_speed': 'Wind',
    'wind_gust': 'Böen', 'wind_direction': 'Richtung', 'rain_today': 'Regen heute', 'uv_index': 'UV',
    'now': 'jetzt', 'min': 'Min.', 'hr': 'Std.', 'day': 'Tg.',
  },
  'pt': {
    'h': 'Minha estação meteorológica',
    'lede': 'Tem uma estação WeatherXM? Cole o link do explorador ou digite o nome e as leituras aparecem ao lado dos seus nodes.',
    'ph': 'Link da WeatherXM ou nome da estação',
    'add': 'Mostrar estação', 'change': 'Trocar', 'busy': 'Procurando…', 'hide': 'Ocultar',
    'notFound': 'Nenhuma estação WeatherXM com esse nome ou link.',
    'many': 'Há várias estações nesta célula. Escolha a sua:',
    'err': 'A WeatherXM não está respondendo agora. Tente de novo em um minuto.',
    'inactive': 'inativa',
    'src': 'Dados: WeatherXM. Sua estação continua ganhando na própria rede.',
    'soon': 'Nubila e SkyX chegam assim que publicarem dados por estação.',
    'temperature': 'Temperatura', 'humidity': 'Umidade', 'pressure': 'Pressão', 'wind_speed': 'Vento',
    'wind_gust': 'Rajadas', 'wind_direction': 'Direção', 'rain_today': 'Chuva hoje', 'uv_index': 'UV',
    'now': 'agora', 'min': 'min', 'hr': 'h', 'day': 'd',
  },
};

String _w(String k) => _t[L10n.lang]?[k] ?? _t['en']![k] ?? k;

const _order = ['temperature', 'humidity', 'pressure', 'wind_speed', 'wind_gust', 'wind_direction', 'rain_today', 'uv_index'];
const _dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
const _prefKey = 'weather_station';
const _hiddenKey = 'weather_station_hidden';

class _WeatherStationCardState extends State<WeatherStationCard> {
  final _input = TextEditingController();
  Map<String, dynamic>? _sel; // {cell, id, name}
  Map<String, dynamic>? _data;
  List<Map<String, dynamic>> _many = const [];
  String? _err;
  bool _busy = false, _hidden = false, _loaded = false;
  DateTime _at = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _hidden = p.getBool(_hiddenKey) ?? false;
      final s = p.getString(_prefKey);
      if (s != null) {
        final j = jsonDecode(s);
        if (j is Map && j['cell'] is String && j['id'] is String) _sel = Map<String, dynamic>.from(j);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _loaded = true);
    _refresh();
  }

  Future<(int, dynamic)> _get(String path) async {
    final r = await http.get(Uri.parse('${Config.beUrl}$path'), headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 15));
    dynamic j;
    try { j = jsonDecode(r.body); } catch (_) {}
    return (r.statusCode, j);
  }

  Future<void> _refresh() async {
    final s = _sel;
    if (s == null || DateTime.now().difference(_at).inMinutes < 5 && _data != null) return;
    try {
      final (code, j) = await _get('/v1/weather/weatherxm/${Uri.encodeComponent(s['cell'])}/${Uri.encodeComponent(s['id'])}');
      if (code == 200 && j is Map) { _data = Map<String, dynamic>.from(j); _err = null; _at = DateTime.now(); }
      else { _err = code == 404 ? 'notFound' : 'err'; }
    } catch (_) { _err = 'err'; }
    if (mounted) setState(() {});
  }

  Future<void> _pick(Map<String, dynamic> s) async {
    _sel = {'cell': s['cell'], 'id': s['id'], 'name': s['name']};
    _many = const []; _data = null; _err = null; _at = DateTime.fromMillisecondsSinceEpoch(0);
    try { (await SharedPreferences.getInstance()).setString(_prefKey, jsonEncode(_sel)); } catch (_) {}
    if (mounted) setState(() {});
    _refresh();
  }

  Future<void> _find() async {
    final q = _input.text.trim();
    if (q.length < 3 || _busy) return;
    setState(() { _busy = true; _err = null; _many = const []; });
    try {
      final (code, j) = await _get('/v1/weather/find?q=${Uri.encodeQueryComponent(q)}');
      if (code == 200 && j is Map && j['id'] is String) {
        await _pick(Map<String, dynamic>.from(j));
      } else if (j is Map && j['error'] == 'many' && j['stations'] is List) {
        final cell = RegExp(r'8[0-9a-f]{14}', caseSensitive: false).firstMatch(q)?.group(0)?.toLowerCase();
        _many = [for (final s in j['stations'] as List) if (s is Map) {...Map<String, dynamic>.from(s), 'cell': cell}];
      } else {
        _err = (j is Map && j['error'] == 'not_found') || code == 400 ? 'notFound' : 'err';
      }
    } catch (_) { _err = 'err'; }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _change() async {
    try { (await SharedPreferences.getInstance()).remove(_prefKey); } catch (_) {}
    setState(() { _sel = null; _data = null; _err = null; });
  }

  Future<void> _hide() async {
    try { (await SharedPreferences.getInstance()).setBool(_hiddenKey, true); } catch (_) {}
    setState(() => _hidden = true);
  }

  String _ago(String? ts) {
    final t = ts == null ? null : DateTime.tryParse(ts);
    if (t == null) return '';
    final s = DateTime.now().difference(t).inSeconds;
    if (s < 60) return _w('now');
    if (s < 3600) return '${s ~/ 60} ${_w('min')}';
    if (s < 86400) return '${s ~/ 3600} ${_w('hr')}';
    return '${s ~/ 86400} ${_w('day')}';
  }

  String _fmt(String k, num v) {
    if (k == 'wind_direction') return '${_dirs[((v % 360) / 45).round() % 8]} ${v.round()}°';
    final d = v.abs() >= 100 ? 0 : 1;
    final s = v.toStringAsFixed(d);
    final out = d == 1 && s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
    return L10n.lang == 'en' ? out : out.replaceAll('.', ',');
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || (_hidden && _sel == null)) return const SizedBox.shrink();
    if (_sel != null && _data != null && DateTime.now().difference(_at).inMinutes >= 5) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }
    const small = TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.35);
    final kids = <Widget>[
      Row(children: [
        const Icon(Icons.cloud_outlined, color: AppTheme.teal, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(_w('h'), style: const TextStyle(color: AppTheme.text, fontSize: 15, fontWeight: FontWeight.w600))),
        if (_sel != null)
          TextButton(onPressed: _change, child: Text(_w('change'), style: const TextStyle(color: AppTheme.teal)))
        else
          TextButton(onPressed: _hide, child: Text(_w('hide'), style: const TextStyle(color: AppTheme.muted))),
      ]),
    ];
    final d = _data;
    if (_sel != null) {
      final name = (d?['name'] ?? _sel!['name'] ?? (_sel!['id'] as String).substring(0, 8)).toString();
      final sub = [d?['address'], _ago(d?['ts'] as String?), if (d?['active'] == false) _w('inactive')]
          .where((x) => x != null && '$x'.isNotEmpty).join(' · ');
      kids.add(Text(name, style: const TextStyle(color: AppTheme.text, fontFamily: 'monospace', fontWeight: FontWeight.w600)));
      if (sub.isNotEmpty) kids.add(Text(sub, style: small));
      kids.add(const SizedBox(height: 10));
      final vals = d?['values'];
      if (vals is Map) {
        kids.add(Wrap(spacing: 8, runSpacing: 8, children: [
          for (final k in _order)
            if (vals[k] is Map && vals[k]['value'] is num)
              Container(
                width: 104,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(color: AppTheme.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_w(k), style: small, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text.rich(TextSpan(children: [
                    TextSpan(text: _fmt(k, vals[k]['value'] as num), style: const TextStyle(color: AppTheme.text, fontSize: 17, fontWeight: FontWeight.w600)),
                    if (k != 'wind_direction') TextSpan(text: ' ${vals[k]['unit'] ?? ''}', style: small),
                  ]), overflow: TextOverflow.ellipsis),
                ]),
              ),
        ]));
        kids.add(const SizedBox(height: 8));
        kids.add(InkWell(
          onTap: () => launchUrl(Uri.parse((d?['link'] ?? 'https://explorer.weatherxm.com/').toString()), mode: LaunchMode.externalApplication),
          child: Text('${_w('src')}  WeatherXM ↗', style: small),
        ));
      } else if (_err != null) {
        kids.add(Text(_w(_err!), style: const TextStyle(color: AppTheme.amber, fontSize: 13)));
      } else {
        kids.add(const LinearProgressIndicator(minHeight: 2, color: AppTheme.teal, backgroundColor: AppTheme.surface));
      }
    } else {
      kids.addAll([
        Text(_w('lede'), style: small),
        const SizedBox(height: 10),
        TextField(
          controller: _input,
          autocorrect: false,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _find(),
          style: const TextStyle(color: AppTheme.text, fontSize: 14),
          decoration: InputDecoration(hintText: _w('ph'), isDense: true, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(onPressed: _busy ? null : _find, child: Text(_busy ? _w('busy') : _w('add'))),
        ),
        if (_err != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_w(_err!), style: const TextStyle(color: AppTheme.red, fontSize: 13))),
        if (_many.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_w('many'), style: small),
          Wrap(spacing: 8, children: [
            for (final s in _many)
              OutlinedButton(onPressed: () => _pick(s), child: Text((s['name'] ?? s['id']).toString())),
          ]),
        ],
        const SizedBox(height: 8),
        Text(_w('soon'), style: small),
      ]);
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppTheme.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: kids),
    );
  }
}
