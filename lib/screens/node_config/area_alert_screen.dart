import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import '../../config.dart';
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/node_service.dart';
import '../../services/owner_token_service.dart';
import '../../services/wallet_service.dart';

/// Alert sąsiedzki: woda rośnie (roadmapa q3-automatyka-sasiedzka). Nod jest środkiem okręgu; serwer
/// patrzy na stacje otwartych danych z poziomem wody (water_level) w promieniu X km i wysyła push,
/// gdy na którejś woda podniesie się o Y cm w 3 godziny. GET/POST /v1/open/area-alert.
class AreaAlertScreen extends StatefulWidget {
  final SavedNode node;
  const AreaAlertScreen({super.key, required this.node});

  @override
  State<AreaAlertScreen> createState() => _AreaAlertScreenState();
}

class _AreaAlertScreenState extends State<AreaAlertScreen> {
  bool _loading = true, _busy = false, _on = false;
  double _radius = 5, _rise = 20;
  String? _error, _saved;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final owner = (await context.read<WalletService>().load())?.address;
      if (owner != null) {
        final r = await http
            .get(Uri.parse('${Config.beUrl}/v1/open/area-alert/${widget.node.id}?owner=${owner.toLowerCase()}'))
            .timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          _on = j['on'] == true;
          _radius = ((j['radius_km'] as num?) ?? 5).toDouble().clamp(1, 20);
          _rise = ((j['rise_cm'] as num?) ?? 20).toDouble().clamp(5, 100);
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save(bool on) async {
    final wallet = context.read<WalletService>();
    setState(() { _busy = true; _error = null; _saved = null; });
    try {
      final owner = (await wallet.load())?.address;
      if (owner == null) throw tr('Brak portfela');
      final body = <String, dynamic>{
        'device_id': widget.node.id,
        'on': on,
        'radius_km': _radius.round(),
        'rise_cm': _rise.round(),
      };
      final tok = await OwnerTokenService().cached(owner);
      if (tok != null) {
        body['owner_token'] = tok;
      } else {
        if (!await wallet.isUnlocked()) throw tr('Odblokuj portfel, aby podpisać');
        final ts = (DateTime.now().millisecondsSinceEpoch / 1000).round();
        body['owner'] = owner;
        body['ts'] = ts;
        body['sig'] = await wallet.signMessage('sensmos:area-alert:$ts');
      }
      final r = await http
          .post(Uri.parse('${Config.beUrl}/v1/open/area-alert'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 12));
      if (r.statusCode == 200) {
        _on = on;
        _saved = on ? tr('Zapisane. Dostaniesz powiadomienie, gdy woda zacznie szybko rosnąć.') : tr('Alert wyłączony.');
      } else {
        try { _error = '${(jsonDecode(r.body) as Map)['error'] ?? r.statusCode}'; } catch (_) { _error = '${r.statusCode}'; }
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Alert sąsiedzki: woda'))),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(16), children: [
                Text(
                    tr('Sąsiedzi z czujnikiem poziomu wody nad rzeką, potokiem albo stawem udostępniają odczyty w otwartych danych Sensmos. Gdy na którejś stacji w pobliżu Twojego noda woda szybko rośnie, dostaniesz powiadomienie na telefon.'),
                    style: const TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.4)),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _on,
                  onChanged: _busy ? null : (v) => _save(v),
                  title: Text(tr('Powiadamiaj mnie'), style: const TextStyle(color: AppTheme.text)),
                ),
                const SizedBox(height: 8),
                Text(tr('Promień: %s km', ['${_radius.round()}']), style: const TextStyle(color: AppTheme.text)),
                Slider(
                  value: _radius, min: 1, max: 20, divisions: 19,
                  onChanged: _busy ? null : (v) => setState(() => _radius = v),
                ),
                Text(tr('Przyrost: %s cm w 3 godziny', ['${_rise.round()}']), style: const TextStyle(color: AppTheme.text)),
                Slider(
                  value: _rise, min: 5, max: 100, divisions: 19,
                  onChanged: _busy ? null : (v) => setState(() => _rise = v),
                ),
                const SizedBox(height: 8),
                FilledButton(onPressed: _busy ? null : () => _save(true), child: Text(tr('Zapisz'))),
                if (_saved != null)
                  Padding(padding: const EdgeInsets.only(top: 12), child: Text(_saved!, style: const TextStyle(color: AppTheme.teal, fontSize: 13))),
                if (_error != null)
                  Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: AppTheme.red, fontSize: 13))),
                const SizedBox(height: 16),
                Text(
                    tr('To pomoc sąsiedzka z czujników amatorskich, nie oficjalne ostrzeżenie. Komunikaty służb i IMGW mają pierwszeństwo. Jedno powiadomienie najwyżej co 6 godzin.'),
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.4)),
              ]),
      ),
    );
  }
}
