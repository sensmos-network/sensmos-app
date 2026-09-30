import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import '../../theme.dart';
import '../../config.dart';
import '../../l10n.dart';
import '../../core/core_bloc.dart';
import '../../services/kom_ble.dart';
import '../../services/kom_chat.dart';
import '../../services/wallet_service.dart';
import 'kom_pin_screen.dart';

const _headers = {'Content-Type': 'application/json', 'X-App-Key': Config.appKey};

/// Odpięcie komunikatora od konta (portfela) na serwerze. null = odpięty, inaczej tekst błędu.
Future<String?> komUnpin(BuildContext context, String id8) async {
  final owner = context.read<CoreBloc>().state.wallet?.address.toLowerCase();
  if (owner == null) return tr('Brak portfela');
  final wallet = context.read<WalletService>();
  try {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final sig = await wallet.signMessage('sensmos:ownertoken:ldev_unpair:$ts:$id8');
    final res = await http.delete(
      Uri.parse('${Config.beUrl}/v1/ldev/$id8'),
      headers: _headers,
      body: jsonEncode({'owner': owner, 'ts': ts, 'sig': sig}),
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode == 200) return null;
    return tr('Nie udało się odpiąć (%s).', [res.statusCode]);
  } catch (_) {
    return tr('Nie udało się odpiąć — sprawdź internet.');
  }
}

/// Ustawienia komunikatora przez BLE: nazwa, widoczność, PIN, konto, odłączenie. Bez okien —
/// formularze na pełnym ekranie, potwierdzenia drugim stuknięciem.
class KomDevice extends StatefulWidget {
  final KomBle kom;
  final VoidCallback onPaired;
  final Widget footer;
  const KomDevice({super.key, required this.kom, required this.onPaired, required this.footer});

  @override
  State<KomDevice> createState() => _KomDeviceState();
}

enum _Pair { none, sending, pending, failed }

class _KomDeviceState extends State<KomDevice> with AutomaticKeepAliveClientMixin {
  static const _vis = [
    ('Ukryty', 'Nie ma Cię na mapie ani w „w pobliżu”. Sieć i tak przenosi Twoje wiadomości.'),
    ('W pobliżu', 'Inne komunikatory słyszane przez te same bramy widzą Cię na liście „w pobliżu”.'),
    ('Na mapie', 'Kropka na publicznej mapie przy bramie, która Cię słyszy (przybliżona, bez GPS).'),
  ];
  bool _busy = false, _polling = false;
  _Pair _pair = _Pair.none;
  String? _pairError, _pairId8, _srvId8, _srvState, _confirm;
  Timer? _tick, _confirmT;
  DateTime _deadline = DateTime.now();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.kom.info.addListener(_onInfo);
    _onInfo();
  }

  @override
  void dispose() {
    widget.kom.info.removeListener(_onInfo);
    _tick?.cancel();
    _confirmT?.cancel();
    super.dispose();
  }

  // Stan konta według serwera: komunikator zapisuje adres, zanim potwierdzi go radiem.
  void _onInfo() {
    final i = widget.kom.info.value;
    final id8 = i?['id8'];
    if (id8 is! String || id8 == _srvId8) return;
    _srvId8 = id8;
    _srvState = null;
    _loadState(id8);
  }

  void _loadState(String id8) {
    _pairState(id8).then((s) {
      if (mounted && id8 == _srvId8) setState(() => _srvState = s);
    }).catchError((_) {});
  }

  Future<String?> _pairState(String id8) async {
    final owner = context.read<CoreBloc>().state.wallet?.address.toLowerCase();
    if (owner == null) return null;
    final res = await http.get(
      Uri.parse('${Config.beUrl}/v1/ldev/pair/$id8').replace(queryParameters: {'owner': owner}),
      headers: _headers,
    ).timeout(const Duration(seconds: 8));
    return res.statusCode == 200 ? (jsonDecode(res.body) as Map<String, dynamic>)['state'] as String? : null;
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<void> Function() op, [String? done]) async {
    setState(() => _busy = true);
    try {
      await op();
      await widget.kom.refreshInfo();
      if (done != null) _snack(done);
    } catch (e) {
      _snack(komErrText(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  // Drugie stuknięcie tego samego przycisku w ciągu 4 s wykonuje akcję; pierwsze tylko pyta.
  bool _confirmed(String key) {
    if (_confirm == key) {
      _confirmT?.cancel();
      setState(() => _confirm = null);
      return true;
    }
    _confirmT?.cancel();
    setState(() => _confirm = key);
    _confirmT = Timer(const Duration(seconds: 4), () { if (mounted) setState(() => _confirm = null); });
    return false;
  }

  // Wyświetlacz wybiera user: e-papieru nie da się wykryć (trzy generacje Wireless Paper na tych
  // samych pinach), OLED — tak. Kody jak KOM_DISP_* w firmware.
  static const _displays = [
    (0, 'Automatycznie', 'OLED, gdy odpowiada; Heltec bez OLED → Wireless Paper V1.1.1 / V1.2.'),
    (1, 'Brak', 'Ekranem jest telefon.'),
    (2, 'OLED 0,96″ (Heltec V3)', ''),
    (3, 'Heltec Wireless Paper V1.0', ''),
    (4, 'Heltec Wireless Paper V1.1', ''),
    (5, 'Heltec Wireless Paper V1.1.1 / V1.2', ''),
  ];

  String _displayOn(Object? on) => switch ('$on') {
        'oled' => tr('OLED 0,96″ (Heltec V3)'),
        'wp10' => tr('Heltec Wireless Paper V1.0'),
        'wp11' => tr('Heltec Wireless Paper V1.1'),
        'wp12' => tr('Heltec Wireless Paper V1.1.1 / V1.2'),
        'fail' => tr('ekran nie odpowiada — wybierz inny typ'),
        _ => tr('bez ekranu'),
      };

  // Po zmianie komunikator restartuje się sam (inne piny/SPI) — nie odpytujemy go zaraz po tym.
  Future<void> _setDisplay(int n) async {
    setState(() => _busy = true);
    try {
      await widget.kom.request('set', {'display': n});
      _snack(tr('Komunikator restartuje się z nowym ekranem…'));
    } catch (e) {
      _snack(komErrText(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _setPin() => Navigator.push(
      context, MaterialPageRoute(builder: (_) => KomPinScreen(kom: widget.kom, set: true)));

  Future<void> _clearPin() async {
    if (!_confirmed('pin')) return;
    await _run(() => widget.kom.setPin(''), tr('PIN usunięty'));
  }

  // Odłączony komunikator przestaje ogłaszać ten telefon i zbierać dla niego wiadomości.
  Future<void> _disconnect() async {
    if (!_confirmed('forget')) return;
    if (widget.kom.link.value == KomLink.ready) {
      try {
        await widget.kom.request('keys', {'hex': ''});           // kasuje kopię kluczy, grup i kontaktów
        await widget.kom.request('advert', {'hex': ''});
        await widget.kom.request('watch', {'ids': <String>[], 'gids': <String>[]});
      } catch (_) {}
    }
    await widget.kom.forget();
  }

  Future<void> _unpin(String id8) async {
    if (!_confirmed('unpin')) return;
    setState(() => _busy = true);
    final err = await komUnpin(context, id8);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) return _snack(err);
    _snack(tr('Odpięty od konta'));
    _loadState(id8);
    widget.onPaired();
  }

  // Dodanie do konta: zgłoszenie w BE podpisem portfela, adres przez BLE, komunikator
  // potwierdza radiem (HELLO z OWN), a apka odpytuje stan.
  Future<void> _startPair(String id8) async {
    final owner = context.read<CoreBloc>().state.wallet?.address.toLowerCase();
    if (owner == null) { setState(() { _pair = _Pair.failed; _pairError = tr('Brak portfela'); }); return; }
    final wallet = context.read<WalletService>();
    setState(() { _busy = true; _pair = _Pair.sending; _pairError = null; });
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
          'device_taken'   => tr('Ten komunikator jest na innym koncie.'),
          'busy'           => tr('Ktoś właśnie dodaje ten komunikator do konta. Spróbuj za 3 minuty.'),
          final String e when e.startsWith('stale timestamp') =>
              tr('Zegar telefonu odbiega o ponad godzinę — włącz automatyczny czas i spróbuj ponownie.'),
          _ => tr('Nie udało się dodać do konta (%s).', [j['error'] ?? res.statusCode]),
        });
      }
      try {
        await widget.kom.request('pair', {'owner': owner});
      } catch (e) {
        throw Exception(komErrText(e));
      }
      if (!mounted) return;
      _pairId8 = id8;
      _deadline = DateTime.now().add(const Duration(seconds: 120));
      _pair = _Pair.pending;
      _srvState = 'pending';
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 2), (_) {
        if (DateTime.now().isAfter(_deadline)) { _fail(); } else { _poll(); }
      });
      widget.kom.refreshInfo().catchError((_) {});
    } catch (e) {
      if (mounted) setState(() { _pair = _Pair.failed; _pairError = e.toString().replaceFirst('Exception: ', ''); });
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _poll() async {
    if (_polling || _pairId8 == null) return;
    _polling = true;
    try {
      final state = await _pairState(_pairId8!);
      if (!mounted || _pair != _Pair.pending || state == null) return;
      if (state == 'paired') {
        _tick?.cancel();
        setState(() { _pair = _Pair.none; _srvState = state; });
        _snack(tr('Dodano do konta'));
        widget.onPaired();
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
    if (mounted) {
      setState(() {
        _pair = _Pair.failed;
        _pairError = tr('Nie dotarło potwierdzenie z komunikatora. Sprawdź, czy jest w zasięgu noda lub bramy Sensmos, i spróbuj ponownie.');
      });
    }
  }

  bool get _onAccount => _srvState == 'paired';

  String _accountText(Object? o) {
    final mine = context.read<CoreBloc>().state.wallet?.address.toLowerCase();
    if (_onAccount) return tr('Na Twoim koncie');
    if (o is String && o.isNotEmpty && o.toLowerCase() != mine) {
      return tr('Na innym koncie (%s)', [o.length > 12 ? '${o.substring(0, 6)}…${o.substring(o.length - 4)}' : o]);
    }
    return tr('Nie jest na koncie. Działa i bez tego.');
  }

  Widget _section(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Text(text, style: const TextStyle(color: AppTheme.text, fontSize: 14, fontWeight: FontWeight.w600)),
      );

  Widget _note(String text, Color color) => Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(top: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 13, height: 1.4)),
      );

  Widget _disconnectButton() {
    final ask = _confirm == 'forget';
    return OutlinedButton.icon(
      onPressed: _disconnect,
      icon: const Icon(Icons.link_off, size: 18, color: AppTheme.red),
      label: Text(ask ? tr('Stuknij jeszcze raz, żeby odłączyć') : tr('Odłącz komunikator'),
          style: const TextStyle(color: AppTheme.red)),
      style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          side: BorderSide(color: ask ? AppTheme.red : AppTheme.border)),
    );
  }

  List<Widget> _body(Map<String, dynamic> i, bool ready) {
    final id8 = '${i['id8'] ?? ''}';
    final name = '${i['name'] ?? ''}';
    final vis = (i['vis'] as num?)?.toInt() ?? 255;
    final pinSet = i['pin_set'] == true;
    final disp = (i['display'] as num?)?.toInt() ?? 0;
    final dutyMs = (i['duty_ms'] as num?) ?? 0, dutyMax = (i['duty_max'] as num?) ?? 0;
    final can = ready && !_busy;
    return [
      Card(child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name.isNotEmpty ? name : id8,
              style: const TextStyle(color: AppTheme.text, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('ID $id8 · FW ${i['fw'] ?? '?'} · ${i['board'] ?? '?'}',
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          if (i['fp'] != null)
            Text('${i['fp']}', style: const TextStyle(color: AppTheme.muted, fontSize: 11, fontFamily: 'monospace')),
          const SizedBox(height: 8),
          Row(children: [
            Icon(i['radio'] == true ? Icons.check_circle_outline : Icons.error_outline,
                size: 16, color: i['radio'] == true ? AppTheme.teal : AppTheme.amber),
            const SizedBox(width: 6),
            Expanded(child: Text(i['radio'] == true ? tr('Radio działa') : tr('Radio komunikatora nie działa.'),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12))),
          ]),
          if (dutyMax > 0) ...[
            const SizedBox(height: 8),
            Text(tr('Nadawanie w ostatniej godzinie: %s s z %s s',
                    [(dutyMs / 1000).toStringAsFixed(1), (dutyMax / 1000).toStringAsFixed(0)]),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
            const SizedBox(height: 4),
            LinearProgressIndicator(
                value: (dutyMs / dutyMax).clamp(0, 1).toDouble(),
                color: AppTheme.teal, backgroundColor: AppTheme.surface),
          ],
        ]),
      )),
      _section(tr('Widoczność')),
      SegmentedButton<int>(
        segments: [for (var v = 0; v < _vis.length; v++) ButtonSegment(value: v, label: Text(tr(_vis[v].$1)))],
        selected: vis < _vis.length ? {vis} : const <int>{},
        emptySelectionAllowed: true,
        showSelectedIcon: false,
        onSelectionChanged: can
            ? (s) { if (s.isNotEmpty) _run(() => widget.kom.request('set', {'vis': s.first})); }
            : null,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: Text(vis < _vis.length ? tr(_vis[vis].$2) : tr('Wybierz, kto może Cię zobaczyć.'),
            style: const TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.4)),
      ),
      _section(tr('Wyświetlacz')),
      for (final o in _displays)
        Card(child: ListTile(
          dense: true,
          title: Text(tr(o.$2), style: const TextStyle(color: AppTheme.text)),
          subtitle: o.$3.isEmpty ? null : Text(tr(o.$3), style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          trailing: disp == o.$1 ? const Icon(Icons.check, color: AppTheme.teal) : null,
          onTap: can && disp != o.$1 ? () => _setDisplay(o.$1) : null,
        )),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: Text('${tr('Działa teraz: %s', [_displayOn(i['display_on'])])} · ${tr('Zmiana restartuje komunikator.')}',
            style: const TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.4)),
      ),
      _section(tr('Sposób wysyłania')),
      ListenableBuilder(
        listenable: KomChat.instance,
        builder: (_, __) => SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'auto', label: Text(tr('Automatycznie'))),
            ButtonSegment(value: 'radio', label: Text(tr('Zawsze radiem'))),
          ],
          selected: {KomChat.instance.mode},
          showSelectedIcon: false,
          onSelectionChanged: (v) => KomChat.instance.setMode(v.first),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: Text(
            KomChat.instance.mode == 'radio'
                ? tr('Wiadomości wychodzą tylko przez ten komunikator (radio).')
                : tr('Najpierw internet; bez internetu przez ten komunikator (radio).'),
            style: const TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.4)),
      ),
      _section(tr('PIN')),
      Card(child: ListTile(
        leading: const Icon(Icons.pin_outlined, color: AppTheme.teal),
        title: Text(pinSet ? tr('Zmień PIN') : tr('Ustaw PIN'), style: const TextStyle(color: AppTheme.text)),
        subtitle: Text(
            pinSet
                ? tr('Telefony, które nie znają PIN-u, poproszą o niego przy podłączeniu.')
                : tr('Bez PIN-u każdy telefon w zasięgu Bluetooth może się podłączyć.'),
            style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
        enabled: can,
        onTap: _setPin,
      )),
      if (pinSet)
        Card(child: ListTile(
          leading: const Icon(Icons.lock_open_outlined, color: AppTheme.muted),
          title: Text(_confirm == 'pin' ? tr('Stuknij jeszcze raz, żeby usunąć PIN') : tr('Usuń PIN'),
              style: TextStyle(color: _confirm == 'pin' ? AppTheme.red : AppTheme.text)),
          enabled: can,
          onTap: _clearPin,
        )),
      _section(tr('Konto')),
      Card(child: ListTile(
        leading: const Icon(Icons.account_balance_wallet_outlined, color: AppTheme.teal),
        title: Text(_onAccount ? tr('Na koncie') : tr('Dodaj do konta'), style: const TextStyle(color: AppTheme.text)),
        subtitle: Text(_accountText(i['owner']), style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
        trailing: _pair == _Pair.sending
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : _onAccount
                ? TextButton(
                    onPressed: _busy ? null : () => _unpin(id8),
                    child: Text(_confirm == 'unpin' ? tr('Na pewno?') : tr('Odepnij'),
                        style: TextStyle(color: _confirm == 'unpin' ? AppTheme.red : AppTheme.muted)),
                  )
                : null,
        enabled: can && _pair != _Pair.pending,
        onTap: _onAccount ? null : () => _startPair(id8),
      )),
      if (_pair == _Pair.pending) ...[
        const SizedBox(height: 8),
        Text(tr('Komunikator potwierdza przez radio…'), style: const TextStyle(color: AppTheme.text, fontSize: 13)),
        const SizedBox(height: 8),
        const LinearProgressIndicator(color: AppTheme.teal, backgroundColor: AppTheme.surface),
      ],
      if (_pair == _Pair.failed && _pairError != null) _note(_pairError!, AppTheme.red),
      const SizedBox(height: 20),
      _disconnectButton(),
      const SizedBox(height: 16),
      widget.footer,
    ];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
        listenable: Listenable.merge([widget.kom.info, widget.kom.link]),
        builder: (_, __) {
          final i = widget.kom.info.value;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: i == null
                ? [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                          widget.kom.link.value == KomLink.connecting
                              ? tr('Łączę z komunikatorem…')
                              : tr('Brak połączenia — łączę ponownie…'),
                          textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.muted)),
                    ),
                    _disconnectButton(),
                    const SizedBox(height: 16),
                    widget.footer,
                  ]
                : _body(i, widget.kom.link.value == KomLink.ready),
          );
        },
      );
  }
}
