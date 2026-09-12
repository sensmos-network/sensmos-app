import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../theme.dart';
import '../../app_shell.dart';
import '../../config.dart';
import '../../l10n.dart';
import '../../core/core_bloc.dart';
import '../../core/core_state.dart';
import '../../core/core_event.dart';
import '../../services/wallet_service.dart';
import '../../services/eth_service.dart';
import '../../services/node_service.dart';

/// Wpłata GALU — WŁĄCZONA z powrotem 2026-09-09.
///
/// Była wygaszona i powód był wtedy prawdziwy: kupować dane mógł wyłącznie zarejestrowany node,
/// a każdy node zarabiał wielokrotnie więcej, niż kosztowało zapytanie (0,50 GALU przy kilkunastu
/// zarabianych na dobę). Skoro `earned + deposited − spent − claimed`, to same zarobki wystarczały
/// i nikt nigdy nie musiał dopłacać — za całą historię sieci wydano wtedy 7,50 GALU wobec 41 152
/// zarobionych, a depozyt wpłaciły trzy portfele, z czego dwa nie wydały nic.
///
/// Store ten świat zamknął. Miejsce u sprzedawcy kupuje się na ADRES, nie na node (bramka „musisz
/// mieć noda" zdjęta 2026-09-09), więc pierwszy raz w historii istnieje ktoś, kto ma za co płacić
/// tylko wtedy, gdy dostanie albo wpłaci GALU: człowiek bez własnego sprzętu.
///
/// NIE wygaszać ponownie „bo przecież nikt nie dopłaca" — dopóki Store żyje, to jest jedyna droga
/// wejścia dla kupującego spoza sieci nodów.
const bool kDepositEnabled = true;

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  bool _loading = true;
  bool _busy = false;
  bool _keysOpen = false;
  bool _pwProtected = false;   // portfel zabezpieczony hasłem
  bool _unlocked = false;      // sesja odblokowana (klucz w RAM)
  final _unlockCtrl = TextEditingController();
  String? _address;

  WalletService get _wallet => context.read<WalletService>();

  // saldo z BE (GALU, human)
  double _available = 0;
  double _earned = 0;
  double _spent = 0;
  double _deposited = 0;
  double _claimed = 0;
  double _claimPending = 0;   // hold claim-intent (wypłata w toku, czeka na event on-chain)
  double _depositPending = 0; // wpłata potwierdzona on-chain, czeka aż listener BE zaksięguje event Deposited
  bool _settling = false;     // claim potwierdzony on-chain, czekamy aż BE go zaksięguje —
                              // przez ten czas liczby są NIEAKTUALNE i tak je pokazujemy

  // saldo on-chain (wei)
  BigInt _dhv = BigInt.zero;
  BigInt _matic = BigInt.zero;
  // Za mało gazu = poniżej ~kosztu claima z zapasem (0.005 POL), nie tylko dokładne zero —
  // pył 0.0001 POL i tak nie pozwoli wysłać transakcji, a ostrzeżenie by się nie pokazało.
  bool get _lowGas => _matic < BigInt.from(5) * BigInt.from(10).pow(15);

  EthService get _eth => context.read<EthService>();

  @override
  void initState() {
    super.initState();
    _address = context.read<CoreBloc>().state.wallet?.address;
    _load();
  }

  @override
  void dispose() {
    _unlockCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final addr = _address;
    if (addr == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    _pwProtected = await _wallet.isPasswordProtected();
    _unlocked = await _wallet.isUnlocked();
    // Gate zablokowanego portfela renderuje build() (_unlockView) — bez dialogu w initState,
    // który wracał „w próżnię". Danych z sieci nie ciągniemy, dopóki nie odblokowane.
    if (_pwProtected && !_unlocked) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    await _loadBe(addr);
    await _loadChain(addr);
    if (mounted) setState(() => _loading = false);
  }

  // Dialog odblokowania sesji hasłem (z opcją recovery przez BLE).
  Future<void> _promptUnlock() async {
    final ctrl = TextEditingController();
    while (mounted && !await _wallet.isUnlocked()) {
      final action = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.card,
          title: Text(tr('Odblokuj portfel'), style: const TextStyle(color: AppTheme.text)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr('Portfel jest chroniony hasłem. Podaj je, aby wykonywać operacje.'),
                style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
            const SizedBox(height: 12),
            TextField(controller: ctrl, obscureText: true, autofocus: true,
                style: const TextStyle(color: AppTheme.text),
                decoration: _pwDec(tr('Hasło'))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'forgot'),
                child: Text(tr('Zapomniałem'), style: const TextStyle(color: AppTheme.muted))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.teal),
              onPressed: () => Navigator.pop(ctx, 'ok'),
              child: Text(tr('Odblokuj'), style: const TextStyle(color: Colors.black))),
          ],
        ),
      );
      if (action == 'forgot') {
        if (mounted) {
          _snack(tr('Odzyskaj portfel z noda (Ustawienia noda → tryb serwisowy Bluetooth) — to zresetuje hasło.'));
        }
        return;   // recovery robi osobny flow (service_screen); tu tylko kierujemy
      }
      try {
        await _wallet.unlock(ctrl.text);
      } catch (e) {
        if (mounted) _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
      }
    }
  }

  // Zapewnia odblokowany klucz przed operacją (claim/deposit/export). null = brak/nieodblokowany.
  Future<String?> _ensureUnlockedKey() async {
    if (!await _wallet.isUnlocked()) {
      await _promptUnlock();
      if (!mounted || !await _wallet.isUnlocked()) return null;
    }
    final pk = (await _wallet.load())?.privateKeyHex;
    return (pk == null || pk.isEmpty) ? null : pk;
  }

  /// Dobijanie po claimie, aż listener zaksięguje zdarzenie z łańcucha.
  ///
  /// `waitReceipt` wraca po PIERWSZYM potwierdzeniu, a BE czyta logi 12 bloków wstecz i odpytuje
  /// co 15 s (listener.js) — więc w tej chwili backend GWARANTOWANIE ma jeszcze stare `claimed_galu`
  /// i nadal trzyma hold. Bez dobijania „Odebrano" zostaje nietknięte, a „Wypłata w toku" wisi
  /// do restartu apki. Depozyt ma taką pętlę od dawna; claim jej nie miał i to był cały bug.
  ///
  /// Ratuje też ścieżkę bez claim-intentu (`viaIntent == false`), gdzie BE nie zapisał nic i bez
  /// tego wszystkie liczby zostawały dokładnie takie jak przed claimem.
  Future<void> _settleClaim(String addr, double claimedBefore) async {
    if (mounted) setState(() => _settling = true);
    try {
      for (int i = 0; i < 12 && mounted; i++) {   // 12 × 5 s = 60 s: 12 bloków (~24 s) + poll 15 s z zapasem
        await Future.delayed(const Duration(seconds: 5));
        if (!mounted) return;
        await _loadBe(addr);
        if (!mounted) return;
        setState(() {});
        if (_claimed > claimedBefore + 0.0001) return;   // zaksięgowane — hold schodzi tym samym UPDATE-em
      }
    } finally {
      if (mounted) setState(() => _settling = false);
    }
  }

  /// Kafel z liczbami, które przez chwilę po claimie są nieprawdziwe. Wygaszamy je i mówimy
  /// wprost, że trwa księgowanie — milczące pokazywanie starej kwoty wyglądało jak zawieszony
  /// przycisk i kusiło, żeby nacisnąć drugi raz.
  Widget _settlingWrap(Widget child) {
    if (!_settling) return child;
    return Stack(children: [
      Opacity(opacity: 0.35, child: IgnorePointer(child: child)),
      Positioned.fill(child: Center(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.teal)),
          const SizedBox(width: 10),
          Text(tr('Księgowanie odbioru…'),
              style: const TextStyle(color: AppTheme.teal, fontSize: 13)),
        ]),
      )),
    ]);
  }

  Future<void> _loadBe(String addr) async {
    try {
      final res = await http
          .get(Uri.parse('${Config.beUrl}/v1/wallet/$addr'))
          .timeout(const Duration(seconds: 6));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      _available = _d(j['available']);
      _earned = _d(j['total_earned']);
      _spent = _d(j['total_spent']);
      _deposited = _d(j['total_deposited']);
      _claimed = _d(j['claimed_galu']);
      _claimPending = _d(j['claim_pending']);
    } catch (_) {}
  }

  Future<void> _loadChain(String addr) async {
    try {
      final r = await Future.wait([
        _eth.tokenBalance(addr),
        _eth.maticBalance(addr),
      ]);
      _dhv = r[0];
      _matic = r[1];
    } catch (_) {}
  }

  double _d(dynamic v) =>
      v == null ? 0 : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? AppTheme.red : null,
    ));
  }

  // ── Deposit ─────────────────────────────────────────────────
  Future<void> _deposit() async {
    final pk = await _ensureUnlockedKey();
    final amount = await _amountDialog(tr('Wpłać GALU na nody'), _dhvHuman());
    if (amount == null || pk == null) return;
    final wei = _toWei(amount);
    if (wei <= BigInt.zero) return;
    if (wei > _dhv) {
      _snack(tr('Za mało GALU w portfelu'), error: true);
      return;
    }

    setState(() => _busy = true);
    final depBefore = _deposited;   // do wykrycia zaksięgowania wpłaty przez listener BE
    try {
      final allowance = await _eth.allowance(_address!);
      if (allowance < wei) {
        _snack(tr('Zatwierdzanie GALU (approve)…'));
        final ah = await _eth.approve(pk, wei);
        final aok = await _eth.waitReceipt(ah);
        if (!aok) {
          _snack(tr('Approve nie powiodło się'), error: true);
          return;
        }
      }
      _snack(tr('Wpłacanie…'));
      final h = await _eth.deposit(pk, wei);
      final ok = await _eth.waitReceipt(h);
      _snack(ok ? tr('Wpłacono %s GALU', [amount]) : tr('Wpłata odrzucona przez kontrakt'),
          error: !ok);
      await _load();
      // Wpłata potwierdzona on-chain, ale saldo kredytuje dopiero listener BE z eventu Deposited
      // (~15-30 s). „Wpłata w toku" + odpytujemy BE aż total_deposited urośnie o tę kwotę.
      // NIC nie doliczamy sami — kwota zawsze z BE (blokada RPC nie doda GALU, napis by tylko wisiał).
      if (ok && mounted) {
        final amtNum = _d(amount);
        setState(() => _depositPending = amtNum);
        for (int i = 0; i < 8 && mounted; i++) {
          await Future.delayed(const Duration(seconds: 5));
          await _loadBe(_address!);
          if (_deposited >= depBefore + amtNum - 0.01) break;
          if (mounted) setState(() {});
        }
        if (mounted) setState(() => _depositPending = 0);
      }
    } catch (e) {
      _snack(tr('Błąd: %s', [e]), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Claim ───────────────────────────────────────────────────
  // Dwufazowy: podpisany claim-intent do BE (hold → available spada OD RAZU, proof w
  // odpowiedzi), potem tx na kontrakt. Finalizuje event on-chain; brak tx → BE zwalnia
  // hold do 2h. Fallback na stary GET /proof gdy intent niedostępny (stary BE/offline).
  Future<void> _claim() async {
    final addr = _address;
    final pk = await _ensureUnlockedKey();
    if (addr == null || pk == null) return;

    setState(() => _busy = true);
    try {
      http.Response res;
      bool viaIntent = false;
      try {
        final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final sig =
            _eth.signIntent(pk, 'sensmos-claim:${addr.toLowerCase()}:$ts');
        res = await http
            .post(Uri.parse(
                '${Config.beUrl}/v1/wallet/${addr.toLowerCase()}/claim-intent'),
                headers: const {'Content-Type': 'application/json'},
                body: jsonEncode({'ts': ts, 'sig': sig}))
            .timeout(const Duration(seconds: 8));
        if (res.statusCode == 401) throw Exception('intent rejected');
        if (res.statusCode == 200) viaIntent = true;
      } catch (_) {
        res = await http
            .get(Uri.parse('${Config.beUrl}/v1/wallet/$addr/proof'))
            .timeout(const Duration(seconds: 8));
      }
      if (res.statusCode != 200) {
        final msg = (jsonDecode(res.body) as Map)['error'] ?? tr('Brak nagród');
        _snack('$msg', error: true);
        return;
      }
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final cumulativeWei = BigInt.parse(j['cumulativeWei'].toString());
      final proof = (j['proof'] as List).map((e) => e.toString()).toList();

      // claim-intent zdjął już z available na BE (hold) → pokaż OD RAZU (available spada,
      // „do odebrania"→0, „wypłata w toku"→kwota), nie czekając na potwierdzenie tx on-chain (~20-30 s).
      if (viaIntent) {
        await _loadBe(addr);
        if (mounted) setState(() {});
      }

      // Cumulative: jeśli już odebrano całość (claimedTotal >= cumulative) — nic do claim.
      final already = await _eth.claimedTotal(addr);
      if (already >= cumulativeWei) {
        _snack(tr('Wszystko już odebrane'));
        return;
      }

      final claimedBefore = _claimed;
      _snack(tr('Odbieranie nagród…'));
      final h = await _eth.claim(pk, cumulativeWei, proof);
      final ok = await _eth.waitReceipt(h);
      _snack(ok ? tr('Odebrano nagrody') : tr('Odbiór odrzucony przez kontrakt'), error: !ok);
      await _load();
      if (ok) _settleClaim(addr, claimedBefore);   // BEZ await — inaczej scrim wisiałby minutę
    } catch (e) {
      _snack(tr('Błąd: %s', [e]), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Wysyłka na dowolny adres (np. sprzętowy portfel) — GALU (ERC-20) albo POL (natywny) ──
  static final BigInt _polReserve = BigInt.from(10).pow(17); // 0.1 POL zostaje na gas

  Future<void> _sendGalu() => _sendAsset(pol: false);
  Future<void> _sendPol() => _sendAsset(pol: true);

  Future<void> _sendAsset({required bool pol}) async {
    final asset = pol ? 'POL' : 'GALU';
    final bal = pol ? _matic : _dhv;
    if (bal <= BigInt.zero) { _snack(tr('Brak %s w portfelu', [asset]), error: true); return; }
    // Przy POL zostaw rezerwę na gas — inaczej „wyślij wszystko" i tx nie ma czym opłacić.
    final maxWei = pol ? (bal > _polReserve ? bal - _polReserve : BigInt.zero) : bal;
    if (maxWei <= BigInt.zero) {
      _snack(tr('Za mało POL — zostaw rezerwę na gas'), error: true);
      return;
    }
    final pk = await _ensureUnlockedKey();
    if (pk == null) return;
    final res = await _sendDialog(asset, maxWei, isPol: pol);
    if (res == null || !mounted) return;
    final to = res['to'] ?? '';
    final amountStr = res['amount'] ?? '';
    if (!EthService.isValidAddress(to)) {
      _snack(tr('Nieprawidłowy adres odbiorcy'), error: true);
      return;
    }
    final wei = _toWei(amountStr);
    if (wei <= BigInt.zero) { _snack(tr('Podaj kwotę'), error: true); return; }
    if (wei > maxWei) {
      _snack(pol ? tr('Za mało POL — zostaw rezerwę na gas') : tr('Za mało GALU w portfelu'), error: true);
      return;
    }
    if (_lowGas) { _snack(tr('Za mało POL na gas — dopłać POL, aby wysłać'), error: true); return; }
    if (await _confirmSend(to, amountStr, asset) != true || !mounted) return;

    setState(() => _busy = true);
    try {
      _snack(tr('Wysyłanie…'));
      final h = pol ? await _eth.sendNative(pk, to, wei) : await _eth.transfer(pk, to, wei);
      final ok = await _eth.waitReceipt(h);
      _snack(ok ? tr('Wysłano %s %s', [amountStr, asset]) : tr('Transakcja odrzucona przez kontrakt'), error: !ok);
      await _load();
    } catch (e) {
      _snack(tr('Błąd: %s', [e]), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Wyciągnij adres 0x… z surowego QR: goły adres albo EIP-681 (ethereum:0x..@137?value=..).
  String? _parseEthAddress(String raw) {
    var s = raw.trim();
    if (s.toLowerCase().startsWith('ethereum:')) s = s.substring('ethereum:'.length);
    for (final sep in ['@', '?', '/']) {
      final i = s.indexOf(sep);
      if (i >= 0) s = s.substring(0, i);
    }
    s = s.trim();
    return EthService.isValidAddress(s) ? s : null;
  }

  Future<Map<String, String>?> _sendDialog(String asset, BigInt maxWei, {required bool isPol}) {
    final toCtrl = TextEditingController();
    final amtCtrl = TextEditingController();
    final maxStr = _weiToHuman6(maxWei);   // floor do 6 miejsc — MAX nigdy > salda
    return showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('Wyślij %s', [asset]), style: const TextStyle(color: AppTheme.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(controller: toCtrl, autofocus: true, maxLines: 2,
                style: const TextStyle(color: AppTheme.text, fontSize: 13, fontFamily: 'monospace'),
                decoration: _pwDec(tr('Adres odbiorcy (0x…)')).copyWith(
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.qr_code_scanner, color: AppTheme.teal),
                    tooltip: tr('Skanuj QR'),
                    onPressed: () async {
                      final raw = await Navigator.of(ctx).push<String>(
                          MaterialPageRoute(builder: (_) => const _QrScanScreen()));
                      if (raw == null) return;
                      final addr = _parseEthAddress(raw);
                      if (addr == null) {
                        _snack(tr('W kodzie QR nie ma poprawnego adresu'), error: true);
                        return;
                      }
                      toCtrl.text = addr;
                    },
                  ),
                )),
            const SizedBox(height: 14),
            TextField(controller: amtCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: AppTheme.text, fontSize: 18),
                decoration: InputDecoration(
                  hintText: '0.0', hintStyle: const TextStyle(color: AppTheme.muted),
                  suffixText: asset, suffixStyle: const TextStyle(color: AppTheme.muted))),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => amtCtrl.text = maxStr,
              child: Text(tr('Dostępne: %s (MAX)', [maxStr]),
                  style: const TextStyle(color: AppTheme.teal, fontSize: 12)),
            ),
            const SizedBox(height: 10),
            Text(isPol
                    ? tr('Zostawiam 0.1 POL na gas. Wysyłka jest nieodwracalna — sprawdź adres.')
                    : tr('Gas zapłacisz w POL. Wysyłka jest nieodwracalna — sprawdź adres.'),
                style: const TextStyle(color: AppTheme.amber, fontSize: 11)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anuluj'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.teal),
            onPressed: () => Navigator.pop(ctx, {'to': toCtrl.text.trim(), 'amount': amtCtrl.text.trim()}),
            child: Text(tr('Dalej'), style: const TextStyle(color: Colors.black))),
        ],
      ),
    );
  }

  Future<bool?> _confirmSend(String to, String amount, String asset) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.card,
          title: Text(tr('Potwierdź wysyłkę'), style: const TextStyle(color: AppTheme.text)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('Wysyłasz %s %s', [amount, asset]),
                  style: const TextStyle(color: AppTheme.text, fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Text(tr('na adres:'), style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
              const SizedBox(height: 2),
              SelectableText(to,
                  style: const TextStyle(color: AppTheme.text, fontSize: 12, fontFamily: 'monospace')),
              const SizedBox(height: 12),
              Text(tr('Tej operacji NIE można cofnąć.'),
                  style: const TextStyle(color: AppTheme.amber, fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anuluj'))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.teal),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Wyślij'), style: const TextStyle(color: Colors.black))),
          ],
        ),
      );

  // ── Eksport klucza (PIN noda) ───────────────────────────────
  Future<void> _exportKey() async {
    final nodes = context.read<NodeService>().nodes;
    if (nodes.isEmpty) {
      _snack(tr('Brak nodów — eksport wymaga PIN-u noda'), error: true);
      return;
    }

    final entered = await _pinDialog();
    if (entered == null) return;

    // Weryfikacja PIN-u przeciw DOWOLNEMU z nodów (pierwszy 200 = OK)
    bool ok = false;
    bool anyReachable = false;
    for (final n in nodes) {
      try {
        final res = await http.get(
          Uri.parse('http://${n.ip}/config'),
          headers: {'Authorization': 'Bearer $entered'},
        ).timeout(const Duration(seconds: 4));
        anyReachable = true;
        if (res.statusCode == 200) {
          ok = true;
          break;
        }
      } catch (_) {}
    }
    if (!anyReachable) {
      _snack(tr('Brak połączenia z żadnym nodem'), error: true);
      return;
    }
    if (!ok) {
      _snack(tr('Błędny PIN'), error: true);
      return;
    }
    if (!mounted) return;

    final pk = await _ensureUnlockedKey();
    if (pk == null) return;
    _showKeyDialog(pk);
  }

  // ── UI ──────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // Portfel potrafi zmienic sie POD tym ekranem: odzysk kopii z noda / import w trybie
    // serwisowym dispatchuje WalletImported. Reaguj na zmiane ADRESU (inny portfel) ORAZ
    // KLUCZA (odzysk TEGO SAMEGO adresu resetuje haslo: privateKeyHex leci z '' na jawny,
    // wiec sam adres by tego nie wykryl i gate „zablokowany" wisialby do recznego odswiezenia).
    return BlocListener<CoreBloc, CoreState>(
      listenWhen: (p, c) =>
          p.wallet?.address != c.wallet?.address ||
          p.wallet?.privateKeyHex != c.wallet?.privateKeyHex,
      listener: (_, state) {
        _address = state.wallet?.address;
        _load();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(tr('Portfel')),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _busy ? null : _load),
          const InboxBellSlot(),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.teal))
          : (_pwProtected && !_unlocked)
              ? _unlockView()
              : BlocBuilder<CoreBloc, CoreState>(
              builder: (context, state) {
                return Stack(children: [
                  ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _addressCard(state.wallet?.address ?? '—'),
                      const SizedBox(height: 16),
                      _settlingWrap(_balanceCard()),
                      if (kDepositEnabled) ...[
                        const SizedBox(height: 16),
                        _actions(),
                      ],
                      const SizedBox(height: 16),
                      _settlingWrap(_onchainCard()),
                      const SizedBox(height: 16),
                      _expensesSection(state.wallet?.address),
                      const SizedBox(height: 16),
                      _securitySection(),
                      const SizedBox(height: 16),
                      _keysSection(),
                    ],
                  ),
                  if (_busy)
                    Container(
                      color: Colors.black54,
                      child: const Center(
                          child: CircularProgressIndicator(
                              color: AppTheme.teal)),
                    ),
                ]);
              },
            ),
    ),
    );
  }

  // ── Wydatki usług (cennik 2026-09-01): ryczałty dobowe z BE (service_days). ──
  // Skoro brak salda niczego nie blokuje, przejrzystość naliczeń jest całym zaufaniem.
  Future<List<Map<String, dynamic>>>? _expFuture;
  Future<List<Map<String, dynamic>>> _fetchExpenses(String addr) async {
    final r = await http.get(
      Uri.parse('${Config.beUrl}/v1/nodes/expenses?owner=$addr'),
      headers: {'X-App-Key': Config.appKey},
    ).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return const [];
    return List<Map<String, dynamic>>.from((jsonDecode(r.body) as Map)['items'] ?? []);
  }

  static const _serviceNames = {
    'lora_rx_aes': 'LoRa: odbiór ramek (AES)',
    'lora_rx_open': 'LoRa: odbiór ramek jawnych',
    'lora_send': 'LoRa: wysyłka ramek',
    'tunnel': 'Tunel (SSH / HA / panel)',
  };

  Widget _expensesSection(String? addr) {
    if (addr == null) return const SizedBox.shrink();
    _expFuture ??= _fetchExpenses(addr);
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          title: Text(tr('Wydatki usług'),
              style: const TextStyle(
                  color: AppTheme.text, fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: Text(tr('ryczałty dobowe — ostatnie 30 dni'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
          children: [
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _expFuture,
              builder: (ctx, snap) {
                final items = snap.data ?? const [];
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
                }
                if (items.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(tr('Brak naliczeń — płatne funkcje nie były używane.'),
                        style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                  );
                }
                return Column(
                  children: items.map((e) {
                    final svc = (e['service'] ?? '').toString();
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(tr(_serviceNames[svc] ?? svc),
                                    style: const TextStyle(
                                        color: AppTheme.text, fontSize: 12)),
                                Text((e['day'] ?? '').toString(),
                                    style: const TextStyle(
                                        color: AppTheme.muted, fontSize: 10)),
                              ]),
                        ),
                        Text('-${e['amount']} GALU',
                            style: TextStyle(
                                color: Colors.amber.shade600,
                                fontSize: 12,
                                fontFamily: 'monospace')),
                      ]),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // Pełnoekranowy gate odblokowania (zamiast dialogu — deterministyczny render).
  Widget _unlockView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock, color: AppTheme.teal, size: 48),
            const SizedBox(height: 16),
            Text(tr('Portfel zablokowany'),
                style: const TextStyle(color: AppTheme.text, fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(tr('Podaj hasło, aby odblokować portfel.'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
            const SizedBox(height: 20),
            TextField(
              controller: _unlockCtrl, obscureText: true, autofocus: true,
              onSubmitted: (_) => _doUnlock(),
              style: const TextStyle(color: AppTheme.text),
              decoration: _pwDec(tr('Hasło')),
            ),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.teal, padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: _doUnlock,
              child: Text(tr('Odblokuj'), style: const TextStyle(color: Colors.black)))),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => _snack(tr('Odzyskaj portfel z noda (Ustawienia noda → tryb serwisowy Bluetooth) — to zresetuje hasło.')),
              child: Text(tr('Zapomniałem hasła'), style: const TextStyle(color: AppTheme.muted))),
          ]),
        ),
      );

  Future<void> _doUnlock() async {
    try {
      await _wallet.unlock(_unlockCtrl.text);
      _unlockCtrl.clear();
      if (!mounted) return;
      setState(() => _unlocked = true);
      _load();   // odblokowane → dociągnij dane i pokaż portfel
    } catch (e) {
      if (mounted) _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  // ── Zabezpieczenie portfela hasłem (opt-in, zalecane) ────────
  Widget _securitySection() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(_pwProtected ? Icons.lock : Icons.lock_open,
                  color: _pwProtected ? AppTheme.teal : AppTheme.amber, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(tr('Hasło portfela'),
                    style: const TextStyle(color: AppTheme.text, fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              if (!_pwProtected)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: AppTheme.amber.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4)),
                  child: Text(tr('Zalecane'),
                      style: const TextStyle(color: AppTheme.amber, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
            ]),
            const SizedBox(height: 10),
            Text(
              _pwProtected
                  ? tr('Klucz zaszyfrowany hasłem. Zapomniane hasło zresetujesz przy nodzie (tryb serwisowy + PIN).')
                  : tr('Zaszyfruj klucz hasłem — chroni środki, gdyby ktoś wykradł dane aplikacji. Zapomniane hasło zresetujesz przy nodzie.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : (_pwProtected ? _disablePasswordFlow : _enablePasswordFlow),
                icon: Icon(_pwProtected ? Icons.lock_open : Icons.lock, size: 18),
                label: Text(_pwProtected ? tr('Wyłącz hasło') : tr('Włącz hasło')),
                style: OutlinedButton.styleFrom(
                    foregroundColor: _pwProtected ? AppTheme.muted : AppTheme.teal,
                    side: BorderSide(color: (_pwProtected ? AppTheme.muted : AppTheme.teal).withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 12)),
              ),
            ),
          ]),
        ),
      );

  // Włączenie: hasło 2× (potwierdzenie), potem zaszyfrowanie klucza.
  Future<void> _enablePasswordFlow() async {
    if (!await _wallet.isUnlocked()) { await _promptUnlock(); if (!await _wallet.isUnlocked()) return; }
    final p1 = TextEditingController(), p2 = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('Ustaw hasło portfela'), style: const TextStyle(color: AppTheme.text)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: p1, obscureText: true, autofocus: true,
              style: const TextStyle(color: AppTheme.text),
              decoration: _pwDec(tr('Hasło'))),
          const SizedBox(height: 12),
          TextField(controller: p2, obscureText: true,
              style: const TextStyle(color: AppTheme.text),
              decoration: _pwDec(tr('Powtórz hasło'))),
          const SizedBox(height: 8),
          Text(tr('Zapamiętaj PIN swojego noda — to jedyna droga odzysku, jeśli zapomnisz hasła.'),
              style: const TextStyle(color: AppTheme.amber, fontSize: 11)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anuluj'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.teal),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Zapisz'), style: const TextStyle(color: Colors.black))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (p1.text.isEmpty || p1.text != p2.text) { _snack(tr('Hasła nie są takie same'), error: true); return; }
    setState(() => _busy = true);
    try {
      await _wallet.enablePassword(p1.text);
      _pwProtected = true;
      _unlocked = true;   // enablePassword zostawia sesję odblokowaną
      if (mounted) _snack(tr('Hasło włączone — portfel zaszyfrowany.'));
    } catch (e) {
      if (mounted) _snack(tr('Błąd: %s', [e.toString().replaceFirst('Exception: ', '')]), error: true);
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _disablePasswordFlow() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('Wyłączyć hasło?'), style: const TextStyle(color: AppTheme.text)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('Klucz wróci do ochrony samego telefonu. Podaj obecne hasło.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
          const SizedBox(height: 10),
          TextField(controller: ctrl, obscureText: true, autofocus: true,
              style: const TextStyle(color: AppTheme.text),
              decoration: _pwDec(tr('Hasło'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anuluj'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Wyłącz'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _wallet.disablePassword(ctrl.text);
      _pwProtected = false;
      if (mounted) _snack(tr('Hasło wyłączone.'));
    } catch (e) {
      if (mounted) _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally { if (mounted) setState(() => _busy = false); }
  }


  Widget _addressCard(String addr) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('ADRES PORTFELA'),
                  style: const TextStyle(
                      color: AppTheme.muted,
                      fontSize: 11,
                      letterSpacing: 0.8)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Text(addr,
                      style: const TextStyle(
                          color: AppTheme.text,
                          fontSize: 13,
                          fontFamily: 'monospace')),
                ),
                IconButton(
                  icon: const Icon(Icons.copy,
                      size: 18, color: AppTheme.muted),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: addr));
                    _snack(tr('Adres skopiowany'));
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.qr_code,
                      size: 20, color: AppTheme.teal),
                  onPressed: () => _showReceive(addr),
                ),
              ]),
            ],
          ),
        ),
      );

  Widget _balanceCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('W SENSMOS'),
                  style: const TextStyle(
                      color: AppTheme.muted, fontSize: 11, letterSpacing: 0.8)),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(_available.toStringAsFixed(3),
                      style: const TextStyle(
                          color: AppTheme.teal, fontSize: 34, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  const Text('GALU',
                      style: TextStyle(color: AppTheme.muted, fontSize: 14, fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                  tr('Zarobione GALU — do odbioru na portfel on-chain albo do wykorzystania na usługi (Store, LoRa).'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.teal,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  // Bez POL claim i tak padnie na gazie z błędem RPC — szary przycisk mówi to wcześniej.
                  onPressed: (_busy || _lowGas) ? null : _claim,
                  icon: const Icon(Icons.download, color: Colors.black, size: 18),
                  label: Text(tr('Odbierz (Claim)'),
                      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600)),
                ),
              ),
              if (_lowGas) ...[
                const SizedBox(height: 6),
                Text(tr('Odbiór wymaga POL na gaz — patrz portfel on-chain poniżej.'),
                    style: const TextStyle(color: AppTheme.amber, fontSize: 12)),
              ],
              if (_claimPending > 0) ...[
                const SizedBox(height: 6),
                _smallRow(tr('Wypłata w toku'), _claimPending),
              ],
              const Divider(color: AppTheme.border, height: 24),
              _smallRow(tr('Zarobione'), _earned),
              if (_spent > 0) _smallRow(tr('Wydane'), _spent),
              if (kDepositEnabled || _deposited > 0)
                _smallRow(tr('Zdeponowane'), _deposited),
              if (_depositPending > 0) _smallRow(tr('Wpłata w toku'), _depositPending),
              _smallRow(tr('Odebrane'), _claimed),
            ],
          ),
        ),
      );

  Widget _smallRow(String label, double v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
            Text(v.toStringAsFixed(3),
                style: const TextStyle(color: AppTheme.text, fontSize: 13)),
          ],
        ),
      );

  // Wpłata (Deposit) — włączona 2026-09-09, patrz kDepositEnabled u góry pliku.
  Widget _actions() => Column(children: [
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.teal,
                  side: const BorderSide(color: AppTheme.teal),
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: _busy ? null : _deposit,
              icon: const Icon(Icons.upload, size: 18),
              label: Text(tr('Wpłać (Deposit)')),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Text(
            tr('Przenosi GALU z portfela on-chain do Sensmos — na opłacanie usług (Store, LoRa).'),
            style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
      ]);

  Widget _onchainCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('PORTFEL ON-CHAIN (Polygon)'),
                  style: const TextStyle(
                      color: AppTheme.muted, fontSize: 11, letterSpacing: 0.8)),
              const SizedBox(height: 6),
              Text(
                  tr('Twoje własne środki na portfelu. Nie płacą za usługi — do tego służy Wpłata.'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
              const SizedBox(height: 16),
              _assetRow('GALU', _weiToDouble(_dhv), AppTheme.amber, 3, 26,
                  onSend: (_busy || _dhv <= BigInt.zero) ? null : _sendGalu),
              const SizedBox(height: 16),
              _assetRow('POL', _weiToDouble(_matic),
                  _lowGas ? AppTheme.red : AppTheme.text, 4, 20,
                  onSend: (_busy || _matic <= BigInt.zero) ? null : _sendPol),
              if (_lowGas) ...[
                const SizedBox(height: 8),
                Text(
                    tr('Za mało POL — odbiór nagród (claim) wymaga gazu. '
                       'Wpłać POL na adres portfela (QR na górze).'),
                    style: const TextStyle(color: AppTheme.amber, fontSize: 12)),
              ],
            ],
          ),
        ),
      );

  // Wiersz aktywa: napis nad DUŻĄ wartością (jak realny portfel), „Wyślij →" wyśrodkowane po prawej.
  Widget _assetRow(String label, double value, Color valueColor, int decimals, double fontSize,
          {VoidCallback? onSend}) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: AppTheme.muted, fontSize: 13, letterSpacing: 0.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(value.toStringAsFixed(decimals),
                    style: TextStyle(
                        color: valueColor, fontSize: fontSize, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          InkWell(
            onTap: onSend,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(tr('Wyślij'),
                    style: TextStyle(
                        color: onSend == null ? AppTheme.muted : AppTheme.teal,
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(width: 3),
                Icon(Icons.arrow_forward, size: 16,
                    color: onSend == null ? AppTheme.muted : AppTheme.teal),
              ]),
            ),
          ),
        ],
      );

  // Klucz portfela — zwinięte pod jeden kafel (zaawansowane, rzadko potrzebne)
  Widget _keysSection() => Card(
        child: Column(children: [
          ListTile(
            leading: const Icon(Icons.shield_outlined, color: AppTheme.muted),
            title: Text(tr('Kopia zapasowa i odzysk'),
                style: const TextStyle(color: AppTheme.text)),
            subtitle: Text(tr('zapisz klucz offline albo odzyskaj portfel'),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
            trailing: Icon(_keysOpen ? Icons.expand_less : Icons.expand_more,
                color: AppTheme.muted),
            onTap: () => setState(() => _keysOpen = !_keysOpen),
          ),
          if (_keysOpen) ...[
            const Divider(color: AppTheme.border, height: 1),
            _exportTile(),
            _importTile(),
          ],
        ]),
      );

  Widget _exportTile() => ListTile(
        leading: const Icon(Icons.save_outlined, color: AppTheme.amber),
        title: Text(tr('Zapisz kopię zapasową'),
            style: const TextStyle(color: AppTheme.text)),
        subtitle: Text(tr('klucz do zapisania offline — na wypadek utraty telefonu i noda'),
            style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
        trailing: const Icon(Icons.chevron_right, color: AppTheme.muted),
        onTap: _busy ? null : _exportKey,
      );

  Widget _importTile() => ListTile(
        leading: const Icon(Icons.restore, color: AppTheme.amber),
        title: Text(tr('Odzyskaj portfel z kopii'),
            style: const TextStyle(color: AppTheme.text)),
        subtitle: Text(tr('wpisz zapisany klucz — tylko jeśli sam go stworzyłeś'),
            style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
        trailing: const Icon(Icons.chevron_right, color: AppTheme.muted),
        onTap: _busy ? null : _importKey,
      );

  Future<void> _importKey() async {
    final ctrl = TextEditingController();
    final pk = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('Odzyskaj portfel z kopii'),
            style: const TextStyle(color: AppTheme.text)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Wpisz klucz z własnej kopii zapasowej, aby odzyskać portfel. '
                  'Rób to tylko na swoim telefonie i tylko kluczem, który sam stworzyłeś.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          const SizedBox(height: 10),
          TextField(controller: ctrl, autofocus: true, maxLines: 2,
            style: const TextStyle(color: AppTheme.text, fontSize: 13, fontFamily: 'monospace'),
            decoration: const InputDecoration(hintText: '0x…',
                hintStyle: TextStyle(color: AppTheme.muted))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anuluj'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.amber),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('Importuj'), style: const TextStyle(color: Colors.black))),
        ],
      ),
    );
    if (pk == null || pk.isEmpty) return;

    // Waliduj + policz adres BEZ zapisu (podglad przed nadpisaniem)
    final ws = context.read<WalletService>();
    String newAddr;
    try {
      newAddr = await ws.addressOf(pk);
    } catch (_) {
      _snack(tr('Nieprawidłowy klucz prywatny'), error: true);
      return;
    }

    final current = context.read<CoreBloc>().state.wallet?.address;
    final sameWallet = current != null && current.toLowerCase() == newAddr.toLowerCase();

    if (!sameWallet && current != null) {
      // Inny wallet niz obecny owner nodow — ostrzez o konsekwencjach
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.card,
          title: Text(tr('Inny portfel'), style: const TextStyle(color: AppTheme.text)),
          content: Text(tr(
              'Importujesz INNY portfel (%s) niż obecny (%s).\n\n'
              'Twoje nody pozostaną przypisane do obecnego portfela, dopóki nie dodasz ich '
              'ponownie przez Bluetooth (to zmieni właściciela i wymaga ponownej weryfikacji — '
              'bez resetu urządzenia). Zarobione GALU zostają przy portfelu, który je zarobił.',
              [_shortAddr(newAddr), _shortAddr(current)]),
              style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anuluj'))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.amber),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Zaimportuj mimo to'), style: const TextStyle(color: Colors.black))),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _busy = true);
    try {
      await ws.restore(pk);
      if (!mounted) return;
      context.read<CoreBloc>().add(WalletImported());
      _snack(sameWallet
          ? tr('Portfel zaimportowany — Twoje nody działają dalej')
          : tr('Portfel zaimportowany: %s', [_shortAddr(newAddr)]));
    } catch (e) {
      if (mounted) _snack(tr('Błąd importu: %s', [e.toString()]), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _shortAddr(String a) => a.length > 12 ? '${a.substring(0,6)}…${a.substring(a.length-4)}' : a;

  // ── Dialogi ─────────────────────────────────────────────────
  Future<String?> _amountDialog(String title, double maxHuman) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(title, style: const TextStyle(color: AppTheme.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: AppTheme.text, fontSize: 18),
              decoration: const InputDecoration(
                hintText: '0.0',
                hintStyle: TextStyle(color: AppTheme.muted),
                suffixText: 'GALU',
                suffixStyle: TextStyle(color: AppTheme.muted),
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => ctrl.text = maxHuman.toStringAsFixed(6),
              child: Text(
                  tr('Dostępne: %s (MAX)', [maxHuman.toStringAsFixed(4)]),
                  style: const TextStyle(color: AppTheme.teal, fontSize: 12)),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Anuluj'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.teal),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('Dalej'), style: const TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  Future<String?> _pinDialog() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('PIN noda'), style: const TextStyle(color: AppTheme.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          style: const TextStyle(
              color: AppTheme.text, fontSize: 18, letterSpacing: 2),
          decoration: const InputDecoration(
            hintText: 'PIN',
            hintStyle: TextStyle(color: AppTheme.muted),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Anuluj'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.teal),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('Odblokuj'),
                style: const TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  void _showKeyDialog(String pk) {
    // Kanoniczne 64 hex (32 bajty). web3dart potrafi zwrócić 66 znaków z wiodącym
    // bajtem 00 (klucz z najwyższym bitem = 1, ~50% przypadków) albo <64 (wiodące
    // zero) — MetaMask wymaga dokładnie 64. Obetnij nadmiar / dopełnij zerami.
    final k = pk.length > 64 ? pk.substring(pk.length - 64) : pk.padLeft(64, '0');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('Klucz prywatny'),
            style: const TextStyle(color: AppTheme.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: AppTheme.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8)),
              child: Text(
                  tr('⚠️ To jest klucz do Twoich środków. NIKT — ani my, ani żadna strona, '
                      'giełda czy „pomoc na forum" — nie ma prawa Cię o niego prosić. '
                      'Nie wysyłaj go, nie wklejaj online, nie rób zdjęcia. '
                      'Zapisz go na papierze i trzymaj offline.'),
                  style: const TextStyle(color: AppTheme.red, fontSize: 12)),
            ),
            const SizedBox(height: 12),
            SelectableText('0x$k',
                style: const TextStyle(
                    color: AppTheme.text,
                    fontSize: 12,
                    fontFamily: 'monospace')),
            const SizedBox(height: 8),
            Text(
                tr('Przepisz na kartkę i schowaj. To Twoja kopia zapasowa na wypadek '
                    'utraty telefonu — nie służy do wklejania w innych aplikacjach.'),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: '0x$k'));
              _snack(tr('Klucz skopiowany'));
            },
            child: Text(tr('Kopiuj')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.teal),
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Zamknij'),
                style: const TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  void _showReceive(String addr) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('Odbiór POL / GALU'),
                style: const TextStyle(
                    color: AppTheme.text,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(tr('Wyślij POL na ten adres (gas na transakcje)'),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12)),
              child: QrImageView(
                  data: addr, size: 200, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 18),
            // Adres celowo łamany na 2 RÓWNE połowy (nie przypadkowy wrap „ostatniej cyfry").
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(8)),
              child: SelectableText(
                  addr.length >= 42 ? '${addr.substring(0, 21)}\n${addr.substring(21)}' : addr,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppTheme.text,
                      fontSize: 15,
                      fontFamily: 'monospace',
                      letterSpacing: 1.2,
                      height: 1.7)),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.teal,
                  side: const BorderSide(color: AppTheme.teal)),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: addr));
                _snack(tr('Adres skopiowany'));
              },
              icon: const Icon(Icons.copy, size: 16),
              label: Text(tr('Kopiuj adres')),
            ),
          ],
        ),
      ),
      ),
    );
  }

  // Dekoracja pola hasła z JAWNĄ ramką (motywowa jest niewidoczna na ciemnym tle).
  InputDecoration _pwDec(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: AppTheme.muted),
        enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.border)),
        focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.teal, width: 1.6)),
      );

  // ── Helpers ─────────────────────────────────────────────────
  double _dhvHuman() => _weiToDouble(_dhv);

  double _weiToDouble(BigInt wei) =>
      wei / BigInt.from(10).pow(18);

  // Human string floorowany do 6 miejsc (NIE zaokrągla w górę — inaczej MAX > salda i tx odrzucona).
  String _weiToHuman6(BigInt wei) {
    final micro = wei ~/ BigInt.from(10).pow(12);   // jednostki 1e-6 (floor)
    final whole = micro ~/ BigInt.from(1000000);
    final frac = (micro % BigInt.from(1000000)).toString().padLeft(6, '0');
    return '$whole.$frac';
  }

  BigInt _toWei(String amount) {
    final parts = amount.replaceAll(',', '.').split('.');
    final whole = parts[0].isEmpty ? '0' : parts[0];
    var frac = parts.length > 1 ? parts[1] : '';
    if (frac.length > 18) frac = frac.substring(0, 18);
    frac = frac.padRight(18, '0');
    try {
      return BigInt.parse(whole) * BigInt.from(10).pow(18) + BigInt.parse(frac);
    } catch (_) {
      return BigInt.zero;
    }
  }
}

/// Ekran skanera QR — zwraca surową zawartość kodu (pop). Uprawnienie kamery
/// ogarnia mobile_scanner przy starcie podglądu (Android/iOS).
class _QrScanScreen extends StatefulWidget {
  const _QrScanScreen();
  @override
  State<_QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<_QrScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Zeskanuj adres (QR)'))),
      body: Stack(children: [
        MobileScanner(
          onDetect: (capture) {
            if (_done) return;
            final code = capture.barcodes.isNotEmpty
                ? capture.barcodes.first.rawValue : null;
            if (code == null || code.isEmpty) return;
            _done = true;
            Navigator.of(context).pop(code);
          },
        ),
        Center(
          child: Container(
            width: 220, height: 220,
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.teal, width: 2),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        Positioned(
          left: 0, right: 0, bottom: 40,
          child: Text(tr('Skieruj aparat na kod QR z adresem portfela'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ),
      ]),
    );
  }
}
