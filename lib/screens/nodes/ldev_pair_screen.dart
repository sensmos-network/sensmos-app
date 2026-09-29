import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import '../../theme.dart';
import '../../config.dart';
import '../../l10n.dart';
import '../../core/core_bloc.dart';
import '../../services/wallet_service.dart';

/// Urządzenie LoRa (komunikator) na portfel przez domowe WiFi: apka szuka urządzenia w podsieci
/// telefonu (/api/id), zgłasza parowanie w BE i przekazuje urządzeniu adres portfela (/api/pair).
/// Urządzenie nadaje podpisaną ramkę radiową, a BE wiąże je z portfelem. Apka tylko odpytuje stan.
class LdevPairScreen extends StatefulWidget {
  const LdevPairScreen({super.key});

  @override
  State<LdevPairScreen> createState() => _LdevPairScreenState();
}

class _Dev {
  final String ip, id8, fw;
  final String? name;
  const _Dev(this.ip, this.id8, this.fw, this.name);
}

enum _Step { list, confirm, failed }

class _LdevPairScreenState extends State<LdevPairScreen> {
  static const _headers = {'Content-Type': 'application/json', 'X-App-Key': Config.appKey};
  static const _errColor = Color(0xFFFF6666);
  // Android trzyma dane komórkowe aktywne także przy WiFi — ich 10.x to nie domowa sieć.
  static const _skipIf = ['rmnet', 'ccmni', 'pdp_ip', 'v4-', 'clat', 'tun', 'utun', 'ipsec', 'ppp', 'p2p', 'dummy'];
  _Step _step = _Step.list;
  bool _scanning = true, _noWifi = false, _busy = false, _polling = false;
  final List<_Dev> _found = [];
  _Dev? _dev;
  String? _error;
  String _owner = '';
  Timer? _tick;
  DateTime _deadline = DateTime.now();

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<(String, int)?> _subnet() async {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    (String, int)? best;
    var bestScore = 0;
    for (final i in ifs) {
      final n = i.name.toLowerCase();
      if (_skipIf.any(n.startsWith)) continue;
      final wifi = n.startsWith('wlan') || n.startsWith('en') || n.startsWith('wifi') || n.startsWith('eth');
      for (final a in i.addresses) {
        final o = a.rawAddress;
        final rank = o[0] == 192 && o[1] == 168 ? 3
            : o[0] == 172 && o[1] >= 16 && o[1] <= 31 ? 2
            : o[0] == 10 ? 1 : 0;
        if (rank == 0) continue;
        final score = rank + (wifi ? 4 : 0);
        if (score > bestScore) { bestScore = score; best = ('${o[0]}.${o[1]}.${o[2]}.', o[3]); }
      }
    }
    return best;
  }

  Future<void> _scan() async {
    setState(() { _scanning = true; _noWifi = false; _error = null; _found.clear(); });
    (String, int)? net;
    try { net = await _subnet(); } catch (_) {}
    if (!mounted) return;
    if (net == null) { setState(() { _scanning = false; _noWifi = true; }); return; }
    final (prefix, self) = net;
    final hosts = [for (var i = 1; i <= 254; i++) if (i != self) i];
    var next = 0;
    // connectionTimeout przerywa samo łączenie — bez tego martwe adresy wiszą do timeoutu systemu.
    final client = IOClient(HttpClient()..connectionTimeout = const Duration(milliseconds: 900));
    Future<void> worker() async {
      while (next < hosts.length && mounted) {
        final d = await _probe(client, '$prefix${hosts[next++]}');
        if (d != null && mounted && !_found.any((f) => f.id8 == d.id8)) setState(() => _found.add(d));
      }
    }
    try {
      await Future.wait([for (var i = 0; i < 32; i++) worker()]);
    } finally {
      client.close();
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<_Dev?> _probe(http.Client c, String ip) async {
    try {
      final r = await c.get(Uri.parse('http://$ip/api/id')).timeout(const Duration(milliseconds: 1500));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body);
      if (j is! Map || j['kom'] != 1) return null;
      final id8 = '${j['id8']}'.toLowerCase();
      if (!RegExp(r'^[0-9a-f]{8}$').hasMatch(id8)) return null;
      final name = j['name'];
      return _Dev(ip, id8, '${j['fw'] ?? '?'}', name is String && name.trim().isNotEmpty ? name.trim() : null);
    } catch (_) {
      return null;
    }
  }

  Future<void> _pair(_Dev d) async {
    final owner = context.read<CoreBloc>().state.wallet?.address;
    if (owner == null) { setState(() => _error = tr('Brak portfela')); return; }
    final wallet = context.read<WalletService>();
    setState(() { _dev = d; _busy = true; _error = null; });
    try {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final sig = await wallet.signMessage('sensmos:ownertoken:ldev_pair:$ts:${d.id8}');
      final res = await http.post(
        Uri.parse('${Config.beUrl}/v1/ldev/pair'),
        headers: _headers,
        body: jsonEncode({'owner': owner, 'ts': ts, 'sig': sig, 'id8': d.id8}),
      ).timeout(const Duration(seconds: 20));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        throw Exception(switch (j['error']) {
          'id8'            => tr('ID urządzenia to 8 znaków szesnastkowych'),
          'unknown_device' => tr('Serwer jeszcze nie słyszał tego urządzenia. Włącz je w zasięgu noda lub bramy Sensmos i spróbuj za minutę.'),
          'device_taken'   => tr('To urządzenie jest sparowane z innym portfelem.'),
          'busy'           => tr('Ktoś właśnie paruje to urządzenie. Spróbuj za 3 minuty.'),
          final String e when e.startsWith('stale timestamp') =>
              tr('Zegar telefonu odbiega o ponad godzinę — włącz automatyczny czas i spróbuj ponownie.'),
          _ => tr('Nie udało się sparować (%s).', [j['error'] ?? res.statusCode]),
        });
      }
      _owner = owner.toLowerCase();
      if (!await _handOwner(d.ip)) throw Exception(tr('Urządzenie w sieci nie odpowiada. Spróbuj ponownie.'));
      if (!mounted) return;
      _deadline = DateTime.now().add(const Duration(seconds: 120));
      _step = _Step.confirm;
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 2), (_) {
        if (DateTime.now().isAfter(_deadline)) { _fail(); } else { _poll(); }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
    if (mounted) setState(() => _busy = false);
  }

  // Adres portfela trafia do urządzenia lokalnie — ono odsyła go w podpisanej ramce radiowej.
  Future<bool> _handOwner(String ip) async {
    try {
      final r = await http.post(
        Uri.parse('http://$ip/api/pair'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'owner': _owner}),
      ).timeout(const Duration(seconds: 5));
      return r.statusCode == 200 && (jsonDecode(r.body) as Map)['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _poll() async {
    final d = _dev;
    if (_polling || d == null) return;
    _polling = true;
    try {
      final res = await http.get(
        Uri.parse('${Config.beUrl}/v1/ldev/pair/${d.id8}').replace(queryParameters: {'owner': _owner}),
        headers: _headers,
      ).timeout(const Duration(seconds: 8));
      if (!mounted || _step != _Step.confirm || res.statusCode != 200) return;
      final state = (jsonDecode(res.body) as Map<String, dynamic>)['state'];
      if (state == 'paired') {
        _tick?.cancel();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Urządzenie sparowane'))));
        Navigator.of(context).pop();
      } else if (state == 'expired' || state == 'none') {
        _fail();
      }
    } catch (_) {
      // chwilowy błąd sieci — kolejna próba za 2 s
    } finally {
      _polling = false;
    }
  }

  void _fail() {
    _tick?.cancel();
    if (mounted) setState(() => _step = _Step.failed);
  }

  Widget _note(String text) => Container(
    padding: const EdgeInsets.all(14),
    margin: const EdgeInsets.only(bottom: 16),
    decoration: BoxDecoration(
      color: AppTheme.card,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppTheme.border),
    ),
    child: Text(text, style: const TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.4)),
  );

  Widget _card(_Dev d) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      leading: const Icon(Icons.forum_outlined, color: AppTheme.teal),
      title: Text(d.name ?? tr('Komunikator'), style: const TextStyle(color: AppTheme.text, fontSize: 14)),
      subtitle: Text('ID ${d.id8}\n${d.ip} · FW ${d.fw}',
          style: const TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.4)),
      isThreeLine: true,
      trailing: FilledButton(
        onPressed: _busy ? null : () => _pair(d),
        style: FilledButton.styleFrom(
            backgroundColor: AppTheme.teal,
            foregroundColor: AppTheme.bg,
            padding: const EdgeInsets.symmetric(horizontal: 12)),
        child: _busy && _dev?.id8 == d.id8
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(tr('Sparuj')),
      ),
    ),
  );

  List<Widget> _listStep() => [
    if (_scanning)
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.teal)),
          const SizedBox(width: 10),
          Flexible(child: Text(tr('Szukam urządzeń w sieci…'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 13))),
        ]),
      )
    else if (_noWifi)
      _note(tr('Połącz telefon z tą samą siecią WiFi co urządzenie.'))
    else if (_found.isEmpty)
      _note(tr('Nie znaleziono urządzenia w tej sieci. Sprawdź, czy urządzenie jest podłączone do Twojego WiFi (pierwsze uruchomienie: sieć SENSMOS-…, hasło 12345678).')),
    ..._found.map(_card),
    if (_error != null) Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Text(_error!, style: const TextStyle(color: _errColor, fontSize: 13)),
    ),
    const SizedBox(height: 20),
    OutlinedButton.icon(
      onPressed: _scanning || _busy ? null : _scan,
      icon: const Icon(Icons.refresh, size: 18),
      label: Text(tr('Szukaj ponownie')),
      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
    ),
  ];

  List<Widget> _confirmStep() => [
    const SizedBox(height: 16),
    const Icon(Icons.settings_input_antenna, size: 56, color: AppTheme.teal),
    const SizedBox(height: 8),
    Text(_dev?.id8 ?? '', textAlign: TextAlign.center,
        style: const TextStyle(color: AppTheme.muted, fontFamily: 'monospace', letterSpacing: 2)),
    const SizedBox(height: 20),
    Text(tr('Urządzenie potwierdza parowanie przez radio…'),
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppTheme.text, fontSize: 20, fontWeight: FontWeight.w600, height: 1.35)),
    const SizedBox(height: 32),
    const LinearProgressIndicator(color: AppTheme.teal, backgroundColor: AppTheme.surface),
  ];

  List<Widget> _failedStep() => [
    const SizedBox(height: 16),
    const Icon(Icons.sensors_off, size: 48, color: AppTheme.amber),
    const SizedBox(height: 16),
    Text(tr('Nie dotarło potwierdzenie z urządzenia. Sprawdź, czy jest w zasięgu noda lub bramy Sensmos, i spróbuj ponownie.'),
        textAlign: TextAlign.center, style: const TextStyle(color: _errColor, fontSize: 14, height: 1.4)),
    const SizedBox(height: 24),
    FilledButton(
      onPressed: () {
        setState(() => _step = _Step.list);
        if (_dev != null) _pair(_dev!);
      },
      style: FilledButton.styleFrom(
          backgroundColor: AppTheme.teal,
          foregroundColor: AppTheme.bg,
          padding: const EdgeInsets.symmetric(vertical: 16)),
      child: Text(tr('Spróbuj ponownie'), style: const TextStyle(fontWeight: FontWeight.bold)),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Dodaj urządzenie LoRa'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: switch (_step) {
          _Step.list    => _listStep(),
          _Step.confirm => _confirmStep(),
          _Step.failed  => _failedStep(),
        },
      ),
    );
  }
}
