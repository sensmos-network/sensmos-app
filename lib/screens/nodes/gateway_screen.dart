import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../../theme.dart';
import '../../config.dart';
import '../../l10n.dart';
import '../../core/core_bloc.dart';
import '../../services/wallet_service.dart';

/// Brama LoRaWAN (Crankk, SenseCAP…) na portfel — jak Store, bez noda. Warunek: w forwarderze
/// bramy dopisany `sensmos.com:1700` i brama TERAZ do nas śle. Ten sam ekran zmienia nazwę
/// i pozycję już sparowanej bramy (BE rozpoznaje ją po EUI i portfelu).
class GatewayScreen extends StatefulWidget {
  final Map<String, dynamic>? existing;   // wiersz z /v1/nodes/by-owner (kind == 'gateway')
  const GatewayScreen({super.key, this.existing});

  @override
  State<GatewayScreen> createState() => _GatewayScreenState();
}

class _GatewayScreenState extends State<GatewayScreen> {
  final _eui  = TextEditingController();
  final _name = TextEditingController();
  final _lat  = TextEditingController();
  final _lon  = TextEditingController();
  bool _busy = false, _gps = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _eui.text  = (e['gw_eui'] ?? '').toString().toUpperCase();
      _name.text = (e['gw_name'] ?? '').toString();
    }
  }

  @override
  void dispose() {
    for (final c in [_eui, _name, _lat, _lon]) { c.dispose(); }
    super.dispose();
  }

  Future<void> _usePhone() async {
    setState(() { _gps = true; _error = null; });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw Exception(tr('Włącz lokalizację w telefonie'));
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        throw Exception(tr('Brak zgody na lokalizację'));
      }
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high)
          .timeout(const Duration(seconds: 12));
      _lat.text = pos.latitude.toStringAsFixed(5);
      _lon.text = pos.longitude.toStringAsFixed(5);
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => _gps = false);
  }

  String? _reason(String? r) {
    if (r == null) return null;
    if (r.startsWith('too_far')) {
      return tr('Pozycja jest za daleko od miejsca, z którego łączy się brama (%s). Brama jest sparowana, ale bez pozycji nie zarabia.',
          [r.split(':').last]);
    }
    if (r.startsWith('country_mismatch')) {
      return tr('Pozycja jest w innym kraju niż łącze bramy. Brama jest sparowana, ale bez pozycji nie zarabia.');
    }
    return tr('Nie udało się ustawić pozycji (%s).', [r]);
  }

  Future<void> _save() async {
    final eui = _eui.text.toLowerCase().replaceAll(RegExp(r'[^0-9a-f]'), '');
    final lat = double.tryParse(_lat.text.trim().replaceAll(',', '.'));
    final lon = double.tryParse(_lon.text.trim().replaceAll(',', '.'));
    if (eui.length != 16) { setState(() => _error = tr('EUI bramy to 16 znaków szesnastkowych')); return; }
    if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
      setState(() => _error = tr('Podaj pozycję bramy'));
      return;
    }
    final owner = context.read<CoreBloc>().state.wallet?.address;
    if (owner == null) { setState(() => _error = tr('Brak portfela')); return; }
    final wallet = context.read<WalletService>();
    setState(() { _busy = true; _error = null; });
    try {
      // lat/lon lecą jako te same napisy, które wchodzą do podpisu
      final latS = lat.toStringAsFixed(5), lonS = lon.toStringAsFixed(5);
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final sig = await wallet.signMessage('sensmos:ownertoken:gateway:$ts:$eui:$latS:$lonS');
      final res = await http.post(
        Uri.parse('${Config.beUrl}/v1/nodes/gateway'),
        headers: const {'Content-Type': 'application/json', 'X-App-Key': Config.appKey},
        body: jsonEncode({'owner': owner, 'ts': ts, 'sig': sig, 'eui': eui,
                          'name': _name.text.trim(), 'lat': latS, 'lon': lonS}),
      ).timeout(const Duration(seconds: 20));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        throw Exception(switch (j['error']) {
          'gateway_silent' => tr('Brama nie wysyła teraz danych do sensmos.com:1700. Dopisz ten adres w forwarderze bramy i spróbuj za minutę.'),
          'gateway_taken'  => tr('Ta brama jest już sparowana z innym portfelem.'),
          _ => j['error'] ?? res.statusCode,
        });
      }
      if (!mounted) return;
      final keptOld = widget.existing?['located'] == true;
      final why = j['located'] == true ? null
          : keptOld ? tr('Nowa pozycja odrzucona — zostaje poprzednia, brama dalej zarabia.')
          : _reason(j['reason']?.toString());
      if (why != null) {
        await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
          title: Text(tr('Brama sparowana')),
          content: Text(why),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Rozumiem')))],
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Brama sparowana'))));
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _field(TextEditingController c, String label, {String? hint, TextInputType? type, bool enabled = true}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          enabled: enabled && !_busy,
          keyboardType: type,
          style: const TextStyle(color: AppTheme.text),
          decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final edit = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(edit ? tr('Brama LoRaWAN') : tr('Dodaj bramę LoRaWAN'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!edit) Container(
            padding: const EdgeInsets.all(14),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: AppTheme.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: Text(
              tr('W panelu bramy (np. Crankk → Forwards To) dopisz serwer sensmos.com:1700. '
                 'Gdy brama zacznie do nas wysyłać, wpisz tu jej EUI. Brama słyszy nody Sensmos, '
                 'nadaje beacon i zarabia jak node.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.4),
            ),
          ),
          _field(_eui, tr('EUI bramy'), hint: 'E45F01FFFEA7021E', enabled: !edit),
          _field(_name, tr('Nazwa (opcjonalnie)'), hint: tr('np. brama na dachu')),
          Row(children: [
            Expanded(child: _field(_lat, tr('Szerokość'), hint: '52.22970',
                type: const TextInputType.numberWithOptions(decimal: true, signed: true))),
            const SizedBox(width: 10),
            Expanded(child: _field(_lon, tr('Długość'), hint: '21.01220',
                type: const TextInputType.numberWithOptions(decimal: true, signed: true))),
          ]),
          OutlinedButton.icon(
            onPressed: _busy || _gps ? null : _usePhone,
            icon: _gps
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.my_location, size: 18),
            label: Text(tr('Jestem przy bramie — użyj pozycji telefonu')),
          ),
          const SizedBox(height: 6),
          Text(tr('Pozycja musi zgadzać się z krajem i okolicą, z której łączy się brama.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          if (_error != null) Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(_error!, style: const TextStyle(color: Color(0xFFFF6666), fontSize: 13)),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.teal,
                foregroundColor: AppTheme.bg,
                padding: const EdgeInsets.symmetric(vertical: 16)),
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(edit ? tr('Zapisz') : tr('Sparuj z portfelem'),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
