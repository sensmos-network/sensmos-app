import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import '../../theme.dart';
import '../../config.dart';
import '../../l10n.dart';
import '../../core/core_bloc.dart';
import '../../services/wallet_service.dart';

/// Urządzenie LoRa (komunikator) na portfel: apka zgłasza ID, użytkownik trzyma PRG 5 s,
/// urządzenie wysyła podpisaną ramkę radiową, a BE wiąże je z portfelem. Apka tylko odpytuje stan.
class LdevPairScreen extends StatefulWidget {
  const LdevPairScreen({super.key});

  @override
  State<LdevPairScreen> createState() => _LdevPairScreenState();
}

enum _Step { id, hold, failed }

class _LdevPairScreenState extends State<LdevPairScreen> {
  static const _headers = {'Content-Type': 'application/json', 'X-App-Key': Config.appKey};
  static const _errColor = Color(0xFFFF6666);
  final _id = TextEditingController();
  _Step _step = _Step.id;
  bool _busy = false, _polling = false;
  String? _error;
  String _id8 = '', _owner = '';
  Timer? _tick;
  DateTime _deadline = DateTime.now();
  int _total = 180;

  @override
  void dispose() {
    _tick?.cancel();
    _id.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final id8 = _id.text.toLowerCase().replaceAll(RegExp(r'[^0-9a-f]'), '');
    if (id8.length != 8) { setState(() => _error = tr('ID urządzenia to 8 znaków szesnastkowych')); return; }
    final owner = context.read<CoreBloc>().state.wallet?.address;
    if (owner == null) { setState(() => _error = tr('Brak portfela')); return; }
    final wallet = context.read<WalletService>();
    setState(() { _busy = true; _error = null; });
    try {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final sig = await wallet.signMessage('sensmos:ownertoken:ldev_pair:$ts:$id8');
      final res = await http.post(
        Uri.parse('${Config.beUrl}/v1/ldev/pair'),
        headers: _headers,
        body: jsonEncode({'owner': owner, 'ts': ts, 'sig': sig, 'id8': id8}),
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
      if (!mounted) return;
      _id8 = id8;
      _owner = owner;
      _total = (j['expires_s'] as num?)?.toInt() ?? 180;
      _deadline = DateTime.now().add(Duration(seconds: _total));
      _step = _Step.hold;
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (t) {
        if (DateTime.now().isAfter(_deadline)) { _fail(); return; }
        setState(() {});
        if (t.tick.isEven) _poll();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final res = await http.get(
        Uri.parse('${Config.beUrl}/v1/ldev/pair/$_id8').replace(queryParameters: {'owner': _owner}),
        headers: _headers,
      ).timeout(const Duration(seconds: 8));
      if (!mounted || _step != _Step.hold || res.statusCode != 200) return;
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

  String _mmss(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  List<Widget> _idStep() => [
    Container(
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Text(
        tr('Włącz urządzenie w zasięgu noda lub bramy Sensmos. ID widać na ekranie urządzenia.'),
        style: const TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.4),
      ),
    ),
    TextField(
      controller: _id,
      enabled: !_busy,
      autofocus: true,
      autocorrect: false,
      enableSuggestions: false,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
        TextInputFormatter.withFunction((_, v) => v.copyWith(text: v.text.toLowerCase())),
        LengthLimitingTextInputFormatter(8),
      ],
      style: const TextStyle(color: AppTheme.text, fontFamily: 'monospace', letterSpacing: 2),
      decoration: InputDecoration(
          labelText: tr('ID urządzenia'), hintText: '4ac9e654', border: const OutlineInputBorder()),
      onSubmitted: (_) { if (!_busy) _start(); },
    ),
    if (_error != null) Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Text(_error!, style: const TextStyle(color: _errColor, fontSize: 13)),
    ),
    const SizedBox(height: 20),
    FilledButton(
      onPressed: _busy ? null : _start,
      style: FilledButton.styleFrom(
          backgroundColor: AppTheme.teal,
          foregroundColor: AppTheme.bg,
          padding: const EdgeInsets.symmetric(vertical: 16)),
      child: _busy
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : Text(tr('Dalej'), style: const TextStyle(fontWeight: FontWeight.bold)),
    ),
  ];

  List<Widget> _holdStep() {
    final left = _deadline.difference(DateTime.now()).inSeconds.clamp(0, _total);
    return [
      const SizedBox(height: 16),
      const Icon(Icons.touch_app_outlined, size: 56, color: AppTheme.teal),
      const SizedBox(height: 8),
      Text(_id8, textAlign: TextAlign.center,
          style: const TextStyle(color: AppTheme.muted, fontFamily: 'monospace', letterSpacing: 2)),
      const SizedBox(height: 20),
      Text(tr('Przytrzymaj przycisk PRG na urządzeniu przez 5 sekund — puść po dwóch mignięciach diody.'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppTheme.text, fontSize: 20, fontWeight: FontWeight.w600, height: 1.35)),
      const SizedBox(height: 10),
      Text(tr('Po 3 sekundach dioda mignie raz — trzymaj dalej.'),
          textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
      const SizedBox(height: 32),
      LinearProgressIndicator(
          value: _total > 0 ? left / _total : 0, color: AppTheme.teal, backgroundColor: AppTheme.surface),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Flexible(child: Text(tr('Czekam na potwierdzenie z urządzenia… %s', [_mmss(left)]),
            style: const TextStyle(color: AppTheme.muted, fontSize: 13))),
      ]),
    ];
  }

  List<Widget> _failedStep() => [
    const SizedBox(height: 16),
    const Icon(Icons.sensors_off, size: 48, color: AppTheme.amber),
    const SizedBox(height: 16),
    Text(tr('Nie dotarło potwierdzenie z urządzenia. Sprawdź, czy jest w zasięgu, i spróbuj ponownie.'),
        textAlign: TextAlign.center, style: const TextStyle(color: _errColor, fontSize: 14, height: 1.4)),
    const SizedBox(height: 24),
    FilledButton(
      onPressed: () => setState(() { _step = _Step.id; _error = null; }),
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
          _Step.id     => _idStep(),
          _Step.hold   => _holdStep(),
          _Step.failed => _failedStep(),
        },
      ),
    );
  }
}
