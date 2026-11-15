import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/kom_ble.dart';

/// Test zasięgu do domu (komunikator 0.18-kom): idziesz z komunikatorem, a co 2 minuty leci „t #n” prosto do
/// noda w domu. Blueprint HA odsyła ciche „ok #n” radiem noda; komunikator zapisuje, jak słyszał dom (RSSI,
/// SNR). Apka kładzie każdy punkt na mapie: zielony = dom odpowiedział, czerwony = cisza. Bez serwera.
class KomRangeScreen extends StatefulWidget {
  final KomBle kom;
  const KomRangeScreen({super.key, required this.kom});

  @override
  State<KomRangeScreen> createState() => _KomRangeScreenState();
}

class _Pt {
  final LatLng at;
  final DateTime ts;
  final int n;
  bool? ok; // null = czeka
  int? rssi;
  double? snr;
  int? rtt;
  _Pt(this.at, this.ts, this.n);
}

class _KomRangeScreenState extends State<KomRangeScreen> {
  static const _every = Duration(seconds: 120), _waitMax = Duration(seconds: 35);
  final _map = MapController();
  final List<_Pt> _pts = [];
  Timer? _t;
  bool _run = false, _step = false;
  String? _error;

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw Exception(tr('Włącz lokalizację w telefonie'));
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        throw Exception(tr('Brak zgody na lokalizację'));
      }
    } catch (e) {
      return setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
    setState(() => _run = true);
    _tick();
    _t = Timer.periodic(_every, (_) => _tick());
  }

  void _stop() {
    _t?.cancel();
    _t = null;
    setState(() => _run = false);
  }

  Future<void> _tick() async {
    if (_step || !mounted) return;
    _step = true;
    try {
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high)
          .timeout(const Duration(seconds: 15));
      final r = await widget.kom.request('hping');
      final p = _Pt(LatLng(pos.latitude, pos.longitude), DateTime.now(), (r['n'] as num).toInt());
      setState(() { _pts.add(p); _error = null; });
      if (_pts.length == 1) _map.move(p.at, 15);
      final end = DateTime.now().add(_waitMax);
      while (mounted && DateTime.now().isBefore(end) && p.ok == null) {
        await Future.delayed(const Duration(seconds: 4));
        await widget.kom.refreshInfo();
        final h = widget.kom.info.value?['home_ping'];
        if (h is Map && (h['n'] as num?)?.toInt() == p.n && h['st'] != 'wait') {
          p.ok = h['st'] == 'ok';
          p.rssi = (h['rssi'] as num?)?.toInt();
          p.snr = (h['snr'] as num?)?.toDouble();
          p.rtt = (h['rtt_ms'] as num?)?.toInt();
        }
      }
      p.ok ??= false;
    } catch (e) {
      final code = e is KomError ? e.code : '';
      _error = code == 'budget'
          ? tr('Limit czasu nadawania na tę godzinę. Następny punkt za chwilę.')
          : code == 'home'
              ? tr('Najpierw ustaw dom.')
              : code == 'busy'
                  ? null
                  : e is TimeoutException
                      ? tr('Brak pozycji GPS. Wyjdź pod niebo.')
                      : komErrText(e);
    }
    _step = false;
    if (mounted) setState(() {});
  }

  String _geojson() => const JsonEncoder.withIndent(' ').convert({
        'type': 'FeatureCollection',
        'features': [
          for (final p in _pts)
            {
              'type': 'Feature',
              'geometry': {'type': 'Point', 'coordinates': [p.at.longitude, p.at.latitude]},
              'properties': {
                'ts': p.ts.toUtc().toIso8601String(),
                'ok': p.ok,
                if (p.rssi != null) 'rssi': p.rssi,
                if (p.snr != null) 'snr': p.snr,
                if (p.rtt != null) 'rtt_ms': p.rtt,
              },
            }
        ],
      });

  Color _col(_Pt p) => p.ok == null ? AppTheme.amber : p.ok! ? AppTheme.teal : AppTheme.red;

  @override
  Widget build(BuildContext context) {
    final ok = _pts.where((p) => p.ok == true).length, bad = _pts.where((p) => p.ok == false).length;
    final last = _pts.isEmpty ? null : _pts.last;
    final fwOk = widget.kom.info.value?['home_id8'] != null;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Test zasięgu do domu')), actions: [
        if (_pts.isNotEmpty)
          IconButton(
            tooltip: tr('Kopiuj GeoJSON'),
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _geojson()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Skopiowano punkty (GeoJSON)'))));
              }
            },
          ),
      ]),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: FlutterMap(
              mapController: _map,
              options: const MapOptions(initialCenter: LatLng(52.0, 19.0), initialZoom: 6),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.zkv.sensmos',
                ),
                MarkerLayer(markers: [
                  for (final p in _pts)
                    Marker(
                      point: p.at,
                      width: 46,
                      height: 22,
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: _col(p), borderRadius: BorderRadius.circular(11),
                            border: Border.all(color: AppTheme.bg, width: 1.5)),
                        child: Text(p.rssi != null ? '${p.rssi}' : (p.ok == false ? '×' : '…'),
                            style: const TextStyle(color: AppTheme.bg, fontSize: 11, fontWeight: FontWeight.w600)),
                      ),
                    ),
                ]),
                const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (!fwOk)
                Text(tr('Najpierw ustaw dom.'),
                    style: const TextStyle(color: AppTheme.amber, fontSize: 13))
              else ...[
                Text(
                    _pts.isEmpty
                        ? tr('Idź z komunikatorem tam, gdzie chcesz mieć łączność z domem. Co 2 minuty apka zapisze punkt: zielony, gdy dom odpowiedział, czerwony, gdy cisza. Trzymaj ekran włączony.')
                        : tr('Punkty: %s · dom odpowiedział: %s · cisza: %s', ['${_pts.length}', '$ok', '$bad']),
                    style: const TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.4)),
                if (last?.rssi != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(tr('Ostatnio: RSSI %s dBm, SNR %s dB', ['${last!.rssi}', (last.snr ?? 0).toStringAsFixed(1)]),
                        style: const TextStyle(color: AppTheme.text, fontSize: 13)),
                  ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _run ? _stop : _start,
                  icon: Icon(_run ? Icons.stop : Icons.play_arrow, size: 18),
                  label: Text(_run ? tr('Zatrzymaj test') : tr('Zacznij test')),
                ),
              ],
              if (_error != null)
                Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: AppTheme.red, fontSize: 13))),
              const SizedBox(height: 6),
              Text(tr('Każdy punkt to krótkie nadanie w paśmie 868 MHz, które ma limit czasu nadawania; godzina testu to około 30 punktów. Dom musi mieć blueprint komunikator_dom w wersji z testem zasięgu.'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 11, height: 1.4)),
            ]),
          ),
        ]),
      ),
    );
  }
}
