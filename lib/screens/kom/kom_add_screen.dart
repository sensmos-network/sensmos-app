import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/kom_ble.dart';
import 'kom_pin_screen.dart';

/// Dodanie komunikatora: lista z BLE → stuknięcie → podłączony (bez żadnego okna). Komunikator
/// z PIN-em, którego telefon nie zna → ekran PIN-u.
class KomAddScreen extends StatefulWidget {
  final KomBle kom;
  const KomAddScreen({super.key, required this.kom});

  @override
  State<KomAddScreen> createState() => _KomAddScreenState();
}

class _KomAddScreenState extends State<KomAddScreen> {
  static const _scanFor = Duration(seconds: 12);
  final _results = <ScanResult>[];
  StreamSubscription? _scanSub;
  bool _scanning = false;
  ScanResult? _busy;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }

  String _name(ScanResult r) {
    final n = r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.platformName;
    return n.isNotEmpty ? n : 'Sensmos';
  }

  Future<void> _scan() async {
    setState(() { _scanning = true; _error = null; _results.clear(); });
    if (!await widget.kom.bluetoothOn()) {
      if (mounted) setState(() { _error = tr('Włącz Bluetooth'); _scanning = false; });
      return;
    }
    await _scanSub?.cancel();
    _scanSub = widget.kom.scan(timeout: _scanFor).listen((r) {
      if (mounted) setState(() => _results..clear()..addAll(r)..sort((a, b) => b.rssi.compareTo(a.rssi)));
    });
    await Future.delayed(_scanFor);
    if (!mounted || _busy != null) return;
    setState(() => _scanning = false);
    // Android ≤11: skan BLE wymaga włączonej lokalizacji — bez niej lista jest po cichu pusta.
    if (_results.isEmpty && Platform.isAndroid && !await Geolocator.isLocationServiceEnabled() && mounted) {
      setState(() => _error = tr(
          'Lokalizacja (GPS) jest wyłączona — na Androidzie 11 i starszych jest wymagana do skanowania Bluetooth.'));
    }
  }

  Future<void> _connect(ScanResult r) async {
    await _scanSub?.cancel();
    _scanSub = null;
    setState(() { _busy = r; _scanning = false; _error = null; });
    try {
      await widget.kom.add(r.device);
      if (!mounted) return;
      if (widget.kom.link.value == KomLink.pin) {
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => KomPinScreen(kom: widget.kom)));
      } else {
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = null;
          _error = tr('Nie udało się podłączyć komunikatora. Trzymaj go blisko telefonu i spróbuj ponownie.');
        });
      }
    }
  }

  IconData _bars(int rssi) => rssi >= -65
      ? Icons.signal_cellular_alt
      : rssi >= -80 ? Icons.signal_cellular_alt_2_bar : Icons.signal_cellular_alt_1_bar;

  Widget _connecting(ScanResult r) => ListView(padding: const EdgeInsets.all(16), children: [
        const SizedBox(height: 16),
        const Icon(Icons.bluetooth_connected, size: 56, color: AppTheme.teal),
        const SizedBox(height: 16),
        Text(tr('Łączę z %s…', [_name(r)]),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.text, fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 24),
        const LinearProgressIndicator(color: AppTheme.teal, backgroundColor: AppTheme.surface),
      ]);

  Widget _list() => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.bluetooth_searching, color: _scanning ? AppTheme.teal : AppTheme.muted),
            const SizedBox(width: 10),
            Text(_scanning ? tr('Szukam...') : tr('Znalezione urządzenia'),
                style: const TextStyle(color: AppTheme.text, fontSize: 15)),
          ]),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: AppTheme.red)),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: _results.isEmpty
                ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    if (_scanning) ...[
                      const CircularProgressIndicator(color: AppTheme.teal),
                      const SizedBox(height: 16),
                    ],
                    Text(
                        _scanning
                            ? tr('Skanowanie...')
                            : tr('Brak komunikatorów w pobliżu. Włącz komunikator i trzymaj go blisko telefonu.'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppTheme.muted)),
                  ]))
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (_, i) {
                      final r = _results[i];
                      return Card(child: ListTile(
                        leading: Icon(_bars(r.rssi), color: AppTheme.teal),
                        title: Text(_name(r), style: const TextStyle(color: AppTheme.text)),
                        subtitle: Text('RSSI ${r.rssi} dBm', style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                        trailing: const Icon(Icons.chevron_right, color: AppTheme.muted),
                        onTap: () => _connect(r),
                      ));
                    }),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _scanning ? null : _scan,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(tr('Szukaj ponownie')),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final busy = _busy;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Dodaj komunikator'))),
      body: SafeArea(child: busy != null ? _connecting(busy) : _list()),
    );
  }
}
