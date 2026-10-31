import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import '../../theme.dart';
import '../../core/core_bloc.dart';
import '../../services/ble_service.dart';
import '../../services/attest_service.dart';
import '../../services/wallet_service.dart';
import '../../services/node_service.dart';
import '../../config.dart';
import '../../l10n.dart';

/// Ceremonia trust (re-atestacja) — node przechodzi w tryb BLE,
/// apka wykonuje rundy challenge + odbiera podpisany atest,
/// BE weryfikuje krzyżowo i oznacza node jako zaufany.
class TrustScreen extends StatefulWidget {
  final SavedNode node;
  const TrustScreen({super.key, required this.node});

  @override
  State<TrustScreen> createState() => _TrustScreenState();
}

enum _Phase { idle, restarting, scanning, ceremony, submitting, done, error }

class _TrustScreenState extends State<TrustScreen> {
  _Phase _phase = _Phase.idle;
  String _status = '';
  String? _error;
  bool? _trusted;
  String? _trustedAt;
  bool _loading = true;
  String? _fw;
  bool? _ghost;
  bool _fuzz = true;
  bool _located = false;

  AttestService get _attest => context.read<AttestService>();
  BleService get _ble => context.read<BleService>();

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final s = await _attest.status(widget.node.id);
    if (!mounted) return;
    setState(() {
      _trusted = s?['trusted'] as bool?;
      _trustedAt = s?['trusted_at'] as String?;
      _loading = false;
    });
    _loadGhost();
  }

  // Ghost wymaga FW ≥ 0.25 (starsze nie forwardują location_mode → cicha porażka)
  bool get _fwSupportsGhost {
    final v = _fw;
    if (v == null) return false;
    final p = v.split('.');
    final major = int.tryParse(p.isNotEmpty ? p[0] : '0') ?? 0;
    final minor = int.tryParse(p.length > 1 ? p[1] : '0') ?? 0;
    return major > 0 || (major == 0 && minor >= 25);
  }

  // Fuzz-only re-publikacja z kotwicy wymaga FW ≥ 0.27
  bool get _fwSupportsFuzz {
    final v = _fw;
    if (v == null) return false;
    final p = v.split('.');
    final major = int.tryParse(p.isNotEmpty ? p[0] : '0') ?? 0;
    final minor = int.tryParse(p.length > 1 ? p[1] : '0') ?? 0;
    return major > 0 || (major == 0 && minor >= 27);
  }

  Future<void> _loadGhost() async {
    try {
      final info = await http
          .get(Uri.parse('http://${widget.node.ip}/info'))
          .timeout(const Duration(seconds: 4));
      final j = jsonDecode(info.body) as Map<String, dynamic>;
      if (mounted) setState(() => _fw = (j['version'] ?? j['firmware']) as String?);
      final be = await http
          .get(Uri.parse('${Config.beUrl}/v1/nodes/${widget.node.id}'))
          .timeout(const Duration(seconds: 5));
      final bj = jsonDecode(be.body) as Map<String, dynamic>;
      final src = (bj['device']?['location_source'] ?? '').toString();
      if (mounted) setState(() { _ghost = src == 'ghost'; _located = src == 'app'; });
    } catch (_) {
      if (mounted) setState(() => _ghost ??= false);
    }
  }

  Future<void> _setFuzz(bool on) async {
    setState(() => _fuzz = on);
    try {
      final res = await http
          .post(Uri.parse('http://${widget.node.ip}/config'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${widget.node.pin}',
              },
              body: jsonEncode({'fuzz': on}))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        _snack(on
            ? tr('Rozmycie włączone — na mapie ~200–800 m od pozycji')
            : tr('Rozmycie wyłączone — na mapie dokładny adres'));
      } else {
        _snack(tr('Błąd %s', [res.statusCode]), error: true);
      }
    } catch (e) {
      _snack(tr('Błąd: %s', [e]), error: true);
    }
  }

  Future<void> _setGhost(bool on) async {
    try {
      final res = await http
          .post(Uri.parse('http://${widget.node.ip}/config'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${widget.node.pin}',
              },
              body: jsonEncode({'location_mode': on ? 'ghost' : 'public'}))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        if (mounted) setState(() => _ghost = on);
        _snack(on
            ? tr('Tryb prywatny włączony — node ukryty z mapy')
            : tr('Tryb prywatny wyłączony'));
        // Przeładuj stan z BE. _located wyliczane jest z location_source, a _setGhost
        // go nie ruszał — po wyjściu z trybu prywatnego suwak rozmycia zostawał
        // zablokowany aż do ponownego wejścia na ekran. Krótka zwłoka, bo zmiana leci
        // przez noda po WS i BE potrzebuje chwili, żeby ją zapisać.
        await Future.delayed(const Duration(milliseconds: 900));
        await _loadGhost();
      } else {
        _snack(tr('Błąd %s', [res.statusCode]), error: true);
      }
    } catch (e) {
      _snack(tr('Błąd: %s', [e]), error: true);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? AppTheme.red : null,
    ));
  }

  Future<void> _runCeremony() async {
    final owner = context.read<CoreBloc>().state.wallet?.address;
    final wallet = context.read<WalletService>();
    if (owner == null) {
      setState(() { _phase = _Phase.error; _error = tr('Brak portfela'); });
      return;
    }

    // GPS telefonu (jesteś przy nodzie) → ceremonia v2 = lokalizacja + trust naraz. Best-effort.
    String? gpsLat, gpsLon;
    try {
      final gps = await AttestService.ceremonyGps();
      gpsLat = gps?.lat;
      gpsLon = gps?.lon;
    } catch (_) { /* brak GPS → sam trust, bez lokalizacji */ }

    setState(() { _phase = _Phase.restarting; _error = null;
        _status = tr('Przełączam node w tryb Bluetooth…'); });

    // 1. Node → tryb BLE
    try {
      await http.post(
        Uri.parse('http://${widget.node.ip}/node/ble_mode'),
        headers: {'Authorization': 'Bearer ${widget.node.pin}'},
      ).timeout(const Duration(seconds: 6));
    } catch (e) {
      setState(() { _phase = _Phase.error;
          _error = tr('Node nie odpowiada: %s', [e]); });
      return;
    }

    // 2. Skanuj BLE — szukaj SENSMOS-<6 znaków device_id>
    setState(() { _phase = _Phase.scanning;
        _status = tr('Node restartuje się — szukam przez Bluetooth…'); });
    await Future.delayed(const Duration(seconds: 4));

    final shortId = widget.node.id.length >= 6
        ? widget.node.id.substring(0, 6) : widget.node.id;
    final target = 'SENSMOS-${shortId.toUpperCase()}';

    BluetoothDevice? device;
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    StreamSubscription? scanSub;
    try {
      while (device == null && DateTime.now().isBefore(deadline)) {
        final found = Completer<BluetoothDevice?>();
        scanSub = _ble.scan(timeout: const Duration(seconds: 10)).listen((rs) {
          for (final r in rs) {
            final n = r.advertisementData.advName.isNotEmpty
                ? r.advertisementData.advName : r.device.platformName;
            if (n.toUpperCase() == target && !found.isCompleted) {
              found.complete(r.device);
            }
          }
        });
        device = await found.future
            .timeout(const Duration(seconds: 11), onTimeout: () => null);
        await scanSub.cancel();
        await _ble.stopScan();
      }
    } catch (_) {
      await scanSub?.cancel();
    }

    if (device == null) {
      setState(() { _phase = _Phase.error;
          _error = tr('Nie znalazłem noda przez Bluetooth.\n'
              'Node wróci sam do WiFi w ciągu 5 minut.'); });
      return;
    }

    // 3. Połącz + auth + ceremonia
    setState(() { _phase = _Phase.ceremony;
        _status = tr('Połączono — przeprowadzam ceremonię…'); });
    try {
      await _ble.connect(device);
      final auth = await _ble.sendCommand(
          {'cmd': 'auth', 'pin': widget.node.pin});
      if (auth['status'] != 'ok') {
        throw Exception(tr('Autoryzacja BLE nieudana (PIN?)'));
      }

      final seedResp = await _attest.fetchSeed(widget.node.id, owner);
      if (seedResp == null) {
        throw Exception(tr('Backend niedostępny — brak seedu ceremonii'));
      }
      final seed = seedResp['seed'] as String;
      final rounds = (seedResp['rounds'] as num?)?.toInt() ?? 3;

      final obsMac = _ble.remoteId ?? '';
      final obsName = device.platformName.isNotEmpty
          ? device.platformName : target;
      final obsRssi = await _ble.readRssi();

      setState(() => _status = tr('Rundy challenge (%s)…', [rounds]));
      final ev = await _attest.runCeremony(
          ble: _ble, seed: seed, owner: owner,
          rounds: rounds, resume: true,
          gpsLat: gpsLat, gpsLon: gpsLon);

      await _ble.disconnect();

      // 4. Podpis portfela + submit do BE
      setState(() { _phase = _Phase.submitting;
          _status = tr('Weryfikacja w sieci…'); });
      final canonical = _attest.canonicalAttest(
          deviceId: widget.node.id, owner: owner, seed: seed, ev: ev);
      final sigWallet = await wallet.signMessage(canonical);
      final (ok, msg) = await _attest.submit(
        deviceId: widget.node.id, owner: owner, seed: seed,
        ev: ev, sigWallet: sigWallet,
        bleName: obsName, bleMac: obsMac, rssi: obsRssi,
      );

      if (!ok) throw Exception(tr('Weryfikacja odrzucona: %s', [msg]));

      setState(() { _phase = _Phase.done;
          _status = tr('Node zaufany — wraca do WiFi.'); });
      await _loadStatus();
    } catch (e) {
      try { await _ble.disconnect(); } catch (_) {}
      setState(() {
        _phase = _Phase.error;
        _error = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _phase == _Phase.restarting ||
        _phase == _Phase.scanning ||
        _phase == _Phase.ceremony ||
        _phase == _Phase.submitting;

    return Scaffold(
      appBar: AppBar(title: Text(tr('Lokalizacja i weryfikacja'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.teal))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _statusCard(),
                const SizedBox(height: 16),
                _howItWorks(),
                const SizedBox(height: 20),
                if (busy) ...[
                  const Center(
                      child: CircularProgressIndicator(color: AppTheme.teal)),
                  const SizedBox(height: 12),
                  Center(
                      child: Text(_status,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: AppTheme.muted, fontSize: 13))),
                ] else
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.teal,
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                    onPressed: _runCeremony,
                    icon: const Icon(Icons.verified_user,
                        color: Colors.black, size: 18),
                    label: Text(
                        _trusted == true
                            ? tr('Powtórz ceremonię')
                            : tr('Przeprowadź ceremonię'),
                        style: const TextStyle(
                            color: Colors.black, fontSize: 15)),
                  ),
                if (_phase == _Phase.done) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: AppTheme.teal.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8)),
                    child: Row(children: [
                      const Icon(Icons.check_circle, color: AppTheme.teal, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Text(tr('Ceremonia zakończona — node zaufany.'),
                              style: const TextStyle(
                                  color: AppTheme.teal, fontSize: 13))),
                    ]),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: AppTheme.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8)),
                    child: Row(children: [
                      const Icon(Icons.error_outline,
                          color: AppTheme.red, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Text(_error!,
                              style: const TextStyle(
                                  color: AppTheme.red, fontSize: 13))),
                    ]),
                  ),
                ],
                const SizedBox(height: 24),
                const Divider(color: AppTheme.border),
                const SizedBox(height: 12),
                Text(tr('PRYWATNOŚĆ'),
                    style: const TextStyle(
                        color: AppTheme.muted, fontSize: 11, letterSpacing: 0.8)),
                const SizedBox(height: 8),
                _privacyCard(),
              ],
            ),
    );
  }

  Widget _privacyCard() => Container(
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(
          children: [
            SwitchListTile(
              value: _fuzz,
              onChanged: (!_fwSupportsFuzz || !_located || (_ghost ?? false))
                  ? null
                  : (v) => _setFuzz(v),
              activeColor: AppTheme.teal,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              secondary: const Icon(Icons.blur_on, color: AppTheme.muted),
              title: Text(tr('Rozmycie prywatności'),
                  style: const TextStyle(color: AppTheme.text, fontSize: 14)),
              subtitle: Text(
                  !_fwSupportsFuzz
                      ? tr('Wymaga firmware 0.27+ — zaktualizuj node.')
                      : !_located
                          ? tr('Najpierw ustaw lokalizację (ceremonia powyżej).')
                          : _fuzz
                              ? tr('Na mapie ~200–800 m od prawdziwej pozycji (losowo).')
                              : tr('Na mapie dokładny adres noda.'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
            ),
            const Divider(height: 1, color: AppTheme.border),
            SwitchListTile(
              value: _ghost ?? false,
              onChanged: (!_fwSupportsGhost || _ghost == null)
                  ? null
                  : (v) => _setGhost(v),
              activeColor: AppTheme.teal,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              secondary: const Icon(Icons.visibility_off_outlined,
                  color: AppTheme.muted),
              title: Text(tr('Tryb prywatny (ghost)'),
                  style: const TextStyle(color: AppTheme.text, fontSize: 14)),
              subtitle: Text(
                  _fwSupportsGhost
                      ? tr('Ukryty z mapy, 0 nagród. Dane działają lokalnie; za subskrypcje płacisz.')
                      : tr('Wymaga firmware 0.25+ — zaktualizuj node.'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
            ),
          ],
        ),
      );

  Widget _statusCard() {
    final trusted = _trusted == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
                color: (trusted ? AppTheme.teal : AppTheme.amber)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(
                trusted ? Icons.verified_user : Icons.gpp_maybe_outlined,
                color: trusted ? AppTheme.teal : AppTheme.amber, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(trusted ? tr('Node zaufany') : tr('Node niezweryfikowany'),
                    style: TextStyle(
                        color: trusted ? AppTheme.teal : AppTheme.amber,
                        fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(
                    trusted
                        ? tr('Ceremonia: %s', [_trustedAt?.substring(0, 10) ?? "—"])
                        : tr('Przeprowadź ceremonię, aby potwierdzić,\nże to fizyczne urządzenie.'),
                    style: const TextStyle(
                        color: AppTheme.muted, fontSize: 12)),
                // Bez tego zdania user po udanej ceremonii widzi zero nagród i uznaje, że
                // atestacja nie zadziałała — po czym powtarza ją w kółko (realny przypadek:
                // 22 podejścia w 2 godziny). Nagrody ruszają dopiero po progu obecności.
                if (trusted) ...[
                  const SizedBox(height: 6),
                  Text(
                      tr('Nagrody naliczają się po ok. 4 godzinach online w danej dobie — '
                         'zero na starcie jest normalne.'),
                      style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _howItWorks() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('JAK TO DZIAŁA'),
                  style: const TextStyle(
                      color: AppTheme.muted,
                      fontSize: 11,
                      letterSpacing: 0.8)),
              const SizedBox(height: 8),
              _step('1', tr('Node restartuje się w tryb Bluetooth (zostaw go włączony).')),
              _step('2', tr('Telefon łączy się i wykonuje szybkie rundy challenge — '
                  'dowód, że urządzenie jest fizycznie obok.')),
              _step('3', tr('Node podpisuje atest swoim kluczem, Ty podpisujesz portfelem.')),
              _step('4', tr('Sieć weryfikuje oba podpisy i oznacza node jako zaufany. '
                  'Node sam wraca do WiFi.')),
            ],
          ),
        ),
      );

  Widget _step(String n, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 20, height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(5)),
              child: Text(n,
                  style: const TextStyle(
                      color: AppTheme.teal, fontSize: 11)),
            ),
            const SizedBox(width: 10),
            Expanded(
                child: Text(text,
                    style: const TextStyle(
                        color: AppTheme.text, fontSize: 13, height: 1.35))),
          ],
        ),
      );
}
