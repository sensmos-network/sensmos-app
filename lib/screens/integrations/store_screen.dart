import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:cryptography/cryptography.dart' as cg;
import '../../config.dart';
import '../../theme.dart';
import '../../l10n.dart';
import '../../core/core_bloc.dart';
import '../../services/wallet_service.dart';
import '../wallet/wallet_screen.dart';
import 'package:sensmos_store/sensmos_store.dart';

import '../../services/node_service.dart';

/// Store — pakiet miejsca u innych właścicieli nodów i panel plików.
/// Skrzynka właściciela powstaje z podpisu portfela przy wejściu na ekran i żyje tylko w tym ekranie.
class StoreScreen extends StatefulWidget {
  const StoreScreen({super.key});
  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  static const int maxDownloadMb =
      256; // pobranie na telefon idzie przez pamięć (SAF bez strumienia)

  StoreRelay? _relay;
  cg.SimpleKeyPair?
      _box; // skrzynka właściciela — prywatna połowa, z podpisu portfela
  Uint8List? _boxSeed; // to samo ziarno — jedyne, co przechodzi do izolatu tła
  cg.SimplePublicKey? _boxPub;
  Map<String, dynamic>? _pkg; // {sellers, limit_b, used_b, daily}
  Map<String, dynamic>? _capacity; // gdy nie ma pakietu: wolne miejsce w sieci
  List<Map<String, dynamic>> _items = const [];
  int _wantGb = 1; // pozycja suwaka na ekranie zakupu
  int?
      _wantCopies; // wybór liczby kopii; null = jeszcze nie tknięty, bierz zalecaną
  /// Ile plikow jest w tej chwili na ekranie. Reszta czeka na „Pokaz wiecej" — i to nie jest
  /// kosmetyka: kazda nazwa kosztuje wymiane kluczy, wiec pokazanie wszystkiego naraz znaczy
  /// tyle samo wymian, ile plikow, zanim ekran w ogole cokolwiek narysuje.
  static const _stronaPo = 30;

  /// Katalog, w ktorym stoimy. '' = korzen.
  String _folder = '';

  /// Drzewo katalogow prosto z serwera: sciezka → ile plikow. Serwer grupuje po odcisku i nie
  /// zna nazw; nazwy odszyfrowujemy tutaj, po JEDNEJ na katalog.
  Map<String, int> _drzewo = {};

  /// Ile plikow jest w tym widoku wszystkiego — z tego wiadomo, czy jest jeszcze strona.
  int _wWidoku = 0;
  bool _dociagam = false;
  Map<String, dynamic>? _archive; // {enabled, last_day, paused_reason}
  String? _error, _busy;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _relay?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final owner = context.read<CoreBloc>().state.wallet?.address;
      if (owner == null) throw Exception(tr('Portfel wymagany'));
      final wallet = context.read<WalletService>();
      // Zamknięty portfel to nie błąd Storage — to brama. Pytamy PRZED podpisem, bo inaczej
      // wyjątek z podpisu lądował na ekranie jako techniczna linijka, a karta obok twierdziła,
      // że w sieci nie ma miejsca. Jedno i drugie nieprawda.
      if (!await wallet.isUnlocked()) {
        if (mounted) setState(() => _zablokowany = true);
        return;
      }
      // Skrzynka z podpisu stałego komunikatu — deterministyczna, nigdzie nie zapisywana.
      final sig = await wallet.signMessage('sensmos:store:v1');
      _boxSeed = StoreCrypto.boxSeed(_hex(sig));
      _box = await StoreCrypto.boxFromSeed(_boxSeed!);
      _boxPub = await _box!.extractPublicKey();
      _relay = StoreRelay(
          owner: owner,
          signMessage: wallet.signMessage,
          boxPub: StoreCrypto.pubHex(_boxPub!),
          beUrl: Config.beUrl);
      await _relay!.connect();
      await _loadPackage();
    } catch (e) {
      if (mounted) setState(() => _error = _powod(e));
    }
  }

  /// Komunikat dla człowieka: wyjątki niosą gotowe zdania, tylko Dart dokleja do nich „Exception:".
  String _powod(Object e) => '$e'.replaceFirst('Exception: ', '');

  /// Wejście do portfela i powrót tutaj. Po odblokowaniu ekran ładuje się normalnie —
  /// sam, bez proszenia o cokolwiek drugi raz.
  Future<void> _odblokuj() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const WalletScreen()));
    if (!mounted) return;
    if (!await context.read<WalletService>().isUnlocked()) return;
    setState(() {
      _zablokowany = false;
      _error = null;
    });
    await _init();
  }

  Uint8List _hex(String h) {
    final s = h.startsWith('0x') ? h.substring(2) : h;
    return Uint8List.fromList(List.generate(s.length ~/ 2,
        (i) => int.parse(s.substring(2 * i, 2 * i + 2), radix: 16)));
  }

  /// Ostatni odczyt stanu się nie udał — to CO INNEGO niż „nie ma pakietu".
  bool _loadFailed = false;

  /// Portfel jest pod hasłem i zamknięty. To CO INNEGO niż „nie ma wolnego miejsca w sieci":
  /// bez klucza nie da się nawet zapytać, więc ekran nie ma prawa niczego o tym miejscu twierdzić.
  bool _zablokowany = false;

  Future<void> _loadPackage() async {
    Map<String, dynamic> r;
    try {
      r = await _relay!.package();
    } catch (e) {
      // Zerwane łącze to nie jest odpowiedź „nie masz pakietu". Zostawiamy to, co już wiemy.
      if (mounted)
        setState(() {
          _loadFailed = true;
          _error = _powod(e);
        });
      return;
    }
    if (r['ok'] != true) {
      // TYLKO jawne „no_package" znaczy, że nie ma czego pokazywać i wolno zaproponować zakup.
      // Każda inna odmowa — sprzedawca chwilowo offline, zerwane łącze, błąd serwera — nie mówi
      // nic o tym, czy pakiet istnieje. Pokazanie wtedy oferty wyglądało jak utrata plików.
      if (r['no_package'] != true) {
        if (mounted)
          setState(() {
            _loadFailed = true;
            _error = r['error']?.toString();
          });
        return;
      }
      try {
        final c =
            await http.get(Uri.parse('${Config.beUrl}/v1/store/capacity'));
        _capacity = jsonDecode(c.body) as Map<String, dynamic>;
      } catch (_) {}
      if (mounted)
        setState(() {
          _pkg = null;
          _loadFailed = false;
          _error = null;
        });
      return;
    }
    _pkg = r;
    _loadFailed = false;
    await _refresh();
  }

  /// Nie udało się sprawdzić stanu — mówimy to wprost i dajemy przycisk. Pliki leżą na dyskach
  /// sprzedawców niezależnie od tego, czy akurat udało nam się o nie zapytać.
  Widget _retryCard() => _card([
        Row(children: [
          const Icon(Icons.cloud_off, color: AppTheme.amber, size: 18),
          const SizedBox(width: 8),
          Expanded(
              child: Text(tr('Nie udało się sprawdzić stanu pakietu'),
                  style: const TextStyle(
                      color: AppTheme.text, fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 6),
        Text(
            tr(
                'To nie znaczy, że coś zginęło — Twoje pliki leżą u sprzedawców niezależnie od tego '
                'połączenia. Spróbuj za chwilę.'),
            style: const TextStyle(
                color: AppTheme.muted, fontSize: 12, height: 1.35)),
        const SizedBox(height: 10),
        SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
                onPressed: _busy == null
                    ? () => _run(tr('Sprawdzam…'), _loadPackage)
                    : null,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(tr('Spróbuj ponownie')),
                style:
                    OutlinedButton.styleFrom(foregroundColor: AppTheme.teal))),
      ]);

  /// Nazwa jest zaszyfrowana kluczem pliku, a ten leży w skrzynce — odpakowanie wymaga wymiany
  /// kluczy, więc nie da się go zrobić w `build()`. Robimy to z góry, ale TYLKO dla pozycji,
  /// które ktoś zobaczy; przy stu plikach robienie tego dla wszystkich zamrażało ekran.
  /// Katalogi wynikaja z nazw, wiec potrzebujemy ich WSZYSTKICH — ale ani jednej nie liczymy
  /// na watku interfejsu. Sto wymian kluczy zamrazalo ekran i wywracalo timeouty na zapytaniach
  /// do serwera, bo czekaja w tej samej kolejce zdarzen.
  ///
  /// Kolejnosc jest celowa: najpierw pierwsza strona, czyli to, co czlowiek i tak zobaczy, potem
  /// reszta porcjami. Dzieki temu lista jest na ekranie po ulamku sekundy, a licznik naprawde
  /// idzie do przodu, zamiast stac na zerze do samego konca.
  Future<void> _nazwy() async {
    if (_boxSeed == null) return;
    var od = 0;
    while (od < _items.length) {
      final ile = od == 0 ? _stronaPo : 25;
      final koniec = (od + ile).clamp(0, _items.length);
      final brakujace = <int>[];
      final pary = <(String, String?)>[];
      for (var i = od; i < koniec; i++) {
        if (_items[i].containsKey('_name')) continue;
        brakujace.add(i);
        pary.add((
          _items[i]['wrapped_key'] as String,
          _items[i]['name_enc'] as String?
        ));
      }
      if (pary.isNotEmpty) {
        try {
          final nazwy = await StoreCrypto.namesInIsolate(_boxSeed!, pary);
          for (var k = 0; k < brakujace.length && k < nazwy.length; k++) {
            _items[brakujace[k]]['_name'] = nazwy[k];
          }
        } catch (_) {
          for (final i in brakujace) {
            _items[i]['_name'] = '';
          }
        }
      }
      od = koniec;
      if (!mounted) return;
      setState(() {});
    }
  }

  // ── katalogi z nazw ──
  String _katalog(Map<String, dynamic> it) {
    final n = it['_name'] as String?;
    if (n == null || !n.contains('/')) return '';
    return n.substring(0, n.lastIndexOf('/'));
  }

  String _nazwaPliku(Map<String, dynamic> it) {
    final n = (it['_name'] as String?) ?? '';
    if (n.isEmpty) return (it['id'] as String).substring(0, 8);
    return n.contains('/') ? n.substring(n.lastIndexOf('/') + 1) : n;
  }

  /// Strona przyszla juz zawezona do biezacego katalogu — serwer wie, po czym filtrowac.
  List<Map<String, dynamic>> get _tutaj => _items;

  /// Podkatalogi biezacego katalogu, wyprowadzone z drzewa serwera. Drzewo jest plaskie (jeden
  /// wpis na pelna sciezke), wiec poziom wycinamy tutaj.
  List<String> get _podkatalogi {
    final t = <String>{};
    for (final d in _drzewo.keys) {
      if (_folder.isEmpty) {
        if (d.isNotEmpty) t.add(d.split('/').first);
      } else if (d.startsWith('$_folder/')) {
        t.add('$_folder/${d.substring(_folder.length + 1).split('/').first}');
      }
    }
    final l = t.toList()..sort();
    return l;
  }

  int _ilePlikow(String folder) {
    var n = 0;
    _drzewo.forEach((d, ile) {
      if (d == folder || d.startsWith('$folder/')) n += ile;
    });
    return n;
  }

  void _wejdz(String folder) {
    setState(() {
      _folder = folder;
      _items = const [];
      _wWidoku = 0;
    });
    _run(null, _refresh);
  }

  /// Pierwsza strona biezacego katalogu plus drzewo. `dalej: true` doklada kolejna strone.
  Future<void> _refresh({bool dalej = false}) async {
    final l = await _relay!.list(
      folderH: _hDla(_folder),
      offset: dalej ? _items.length : 0,
      limit: _stronaPo,
      tree: !dalej,
    );
    final strona =
        ((l['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    if (!mounted) return;
    setState(() {
      _items = dalej ? [..._items, ...strona] : strona;
      _wWidoku = (num.tryParse('${l['total']}') ?? strona.length).toInt();
      _archive = (l['archive'] as Map?)?.cast<String, dynamic>();
      _pkg = {
        ...?_pkg,
        'used_b': l['used_b'],
        'limit_b': l['limit_b'],
        'daily': l['daily'],
        'sellers': l['sellers'],
        'price_gb': l['price_gb'],
        'files': l['files'],
        'max_files': l['max_files']
      };
      _error = null;
    });
    if (!dalej) await _drzewoZ(l['folders']);
    await _nazwy();
  }

  /// Odcisk katalogu, ktorym pyta sie serwer. Liczymy go z ziarna skrzynki — serwer takiego
  /// klucza nie ma i nazwy z odcisku nie wyprowadzi.
  String? _hDla(String sciezka) {
    final z = _boxSeed;
    if (z == null) return null;
    return sciezka.isEmpty ? '' : StoreCrypto.folderHash(z, sciezka);
  }

  /// Drzewo z odpowiedzi serwera: po jednej zaszyfrowanej nazwie na katalog. To jedyne miejsce,
  /// gdzie odszyfrowujemy cokolwiek poza biezaca strona — i jest tego tyle, ile katalogow.
  Future<void> _drzewoZ(dynamic surowe) async {
    final z = _boxSeed;
    if (z == null || surowe is! List) return;
    final t = <String, int>{};
    for (final f in surowe) {
      if (f is! Map) continue;
      final enc = f['enc'] as String?;
      final ile = (num.tryParse('${f['files']}') ?? 0).toInt();
      final sciezka =
          (enc == null || enc.isEmpty) ? '' : StoreCrypto.decryptFolder(z, enc);
      if (sciezka.isEmpty || sciezka == '?') continue;
      t[sciezka] = ile;
    }
    if (mounted) setState(() => _drzewo = t);
  }

  Future<void> _buy(int gb, int copies) =>
      _run(tr('Wykupuję pakiet…'), () async {
        final r = await _relay!.package(gb: gb, copies: copies);
        // Odmowa z braku środków to jedyna, przy której człowiek nie wie, co zrobić dalej — sama
        // kwota mu nie pomoże, jeśli nie wie, skąd GALU brać. Reszta odmów jest samotłumacząca.
        if (r['funds'] == true) {
          throw Exception('${r['error']}. ' +
              tr('GALU dostaniesz od kogoś, kto ma nody, albo '
                  'wpłacisz je w portfelu.'));
        }
        if (r['ok'] != true) throw Exception(r['error']);
        _pkg = r;
        await _refresh();
      });

  Future<void> _grow() => _run(tr('Dokupuję…'), () async {
        final r = await _relay!.package(addGb: 1);
        if (r['ok'] != true) throw Exception(r['error']);
        _pkg = r;
        await _refresh();
      });

  Future<void> _shrink() => _run(tr('Zmniejszam…'), () async {
        final r = await _relay!.package(addGb: -1);
        if (r['ok'] != true) throw Exception(r['error']);
        _pkg = r;
        await _refresh();
      });

  /// Zmiana liczby kopii istniejącego pakietu. W górę serwer dobiera sprzedawcę od razu i sam
  /// odmawia, gdy nie ma z kogo — wtedy pokazujemy jego powód, bo tylko on wie, czego zabrakło.
  Future<void> _setCopies(int n) =>
      _run(tr('Zmieniam liczbę kopii…'), () async {
        final r = await _relay!.package(copies: n);
        if (r['funds'] == true) {
          throw Exception('${r['error']}. ' +
              tr('GALU dostaniesz od kogoś, kto ma nody, albo '
                  'wpłacisz je w portfelu.'));
        }
        if (r['ok'] != true) throw Exception(r['error']);
        _pkg = r;
        await _refresh();
      });

  /// Archiwum pomiarów: serwer raz na dobę pakuje pomiary z nodów właściciela, szyfruje je do
  /// JEGO skrzynki (po wysłaniu sam ich nie odczyta) i wysyła do tego pakietu. Włącza wyłącznie
  /// właściciel — dane bez pytania nikomu się nie pojawiają, a każda doba zajmuje jego miejsce.
  Future<void> _setArchive(bool on) =>
      _run(on ? tr('Włączam archiwum…') : tr('Wyłączam archiwum…'), () async {
        final r = await _relay!.archive(on: on);
        if (r['ok'] != true) throw Exception(r['error']);
        if (mounted) setState(() => _archive = r.cast<String, dynamic>());
      });

  /// Katalog nie istnieje na serwerze — jest przedrostkiem w zaszyfrowanej nazwie. Wiec „nowy
  /// folder" znaczy tylko tyle: wchodzimy do niego, a zaklada go pierwszy wyslany plik.
  Future<void> _nowyFolder() async {
    final c = TextEditingController();
    final n = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
              backgroundColor: AppTheme.card,
              title: Text(tr('Nowy folder'),
                  style: const TextStyle(color: AppTheme.text)),
              content: TextField(
                controller: c,
                autofocus: true,
                style: const TextStyle(color: AppTheme.text),
                decoration: InputDecoration(
                  hintText: tr('zdjęcia'),
                  helperText: tr(
                      'Folder mieszka w zaszyfrowanej nazwie pliku — serwer go nie widzi. '
                      'Powstanie razem z pierwszym plikiem, który tu wyślesz.'),
                  helperMaxLines: 3,
                ),
                onSubmitted: (v) => Navigator.pop(ctx, v),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(tr('Anuluj'))),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, c.text),
                    child: Text(tr('Przejdź'))),
              ],
            ));
    final czysty = (n ?? '').trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (czysty.isEmpty || !mounted) return;
    _wejdz(_folder.isEmpty ? czysty : '$_folder/$czysty');
  }

  Future<void> _upload() async {
    final picked = await FilePicker.platform.pickFiles();
    final f = picked?.files.single;
    if (f == null || f.path == null) return;
    if (f.size <= 0) {
      _snack(tr('Plik jest pusty'));
      return;
    }
    final path = f.path!;
    await _run(tr('Szyfrowanie…'), () async {
      final dek = StoreCrypto.randomBytes(32);
      // AES w czystym Darcie → osobny izolat, inaczej UI stoi (ANR na MIUI już przy zdjęciu).
      final (encPath, blocks, digest) =
          await StoreCrypto.encryptInIsolate(path, dek);
      final enc = File(encPath);
      try {
        _setBusy(tr('Wysyłanie…'));
        final size = await enc.length();
        // Telefon traci sieć w windzie, w metrze, przy przejściu z Wi-Fi na komórkę. To, co
        // już doszło, leży u sprzedawcy, a szyfrogram mamy jeszcze obok — wracamy do TEJ SAMEJ
        // wysyłki zamiast zaczynać nowej. Wznowienie kończy się razem z tym ekranem.
        String? wznow;
        for (var proba = 0;; proba++) {
          try {
            await _relay!.put(
                cipher: enc,
                size: size,
                blocks: blocks,
                sha256hex: digest,
                wrappedKey: await StoreCrypto.wrapDek(dek, _boxPub!),
                nameEnc: StoreCrypto.encryptName(
                    dek, _folder.isEmpty ? f.name : '$_folder/${f.name}'),
                // Odcisk katalogu OBOK podpisanej nazwy — po nim serwer grupuje i wydaje strony.
                folderH: _hDla(_folder) ?? '',
                folderEnc: _boxSeed == null
                    ? ''
                    : StoreCrypto.encryptFolder(_boxSeed!, _folder),
                resumeOid: wznow,
                onProgress: (s) => _setProgress(s / size));
            break;
          } on UploadInterrupted catch (e) {
            if (proba >= 2) rethrow;
            wznow = e.objectId;
            _setBusy(tr('Zerwane połączenie — wracam tam, gdzie skończyło'));
          }
        }
      } finally {
        try {
          await enc.parent.delete(recursive: true);
        } catch (_) {}
      }
      await _refresh();
      _snack('${tr('Wysłano: %s', [f.name])} · ${_route()}');
    });
  }

  Future<void> _download(Map<String, dynamic> it) async {
    final size = _n(it['size_b']).toInt();
    if (it['wrapped_key'] == null) {
      _snack(
          tr('Obiekt bez klucza (wysyłka testowa) — nie da się odszyfrować'));
      return;
    }
    if (size > maxDownloadMb * 1024 * 1024) {
      _snack(tr('Za duży plik do pobrania na telefon (limit %s MB)',
          [maxDownloadMb]));
      return;
    }
    final name = (it['_name'] as String?) ?? '';
    await _run(tr('Pobieranie…'), () async {
      final dir = await Directory.systemTemp.createTemp('sensmos-store-');
      final enc = File('${dir.path}/dl.bin');
      try {
        await _relay!.get(it['id'] as String, enc,
            onProgress: (g) => _setProgress(g / size));
        _setBusy(tr('Odszyfrowywanie…'));
        final dek =
            await StoreCrypto.unwrapDek(it['wrapped_key'] as String, _box!);
        final plain = await StoreCrypto.decryptInIsolate(enc.path, dek);
        final path = await FilePicker.platform
            .saveFile(fileName: name.isEmpty ? 'file' : name, bytes: plain);
        if (path != null) _snack('${tr('Pobrano: %s', [name])} · ${_route()}');
      } finally {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });
  }

  Future<void> _delete(Map<String, dynamic> it) async {
    final name = (it['_name'] as String?) ?? '';
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                backgroundColor: AppTheme.card,
                title: Text(tr('Usunąć %s?', [name]),
                    style: const TextStyle(color: AppTheme.text)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(tr('Anuluj'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(tr('Usuń'))),
                ]));
    if (ok != true) return;
    await _run(null, () async {
      await _relay!.del(it['id'] as String);
      await _refresh();
    });
  }

  /// Zamknięcie pakietu: pliki znikają u sprzedawców, opłaty kończą się z tą dobą, karta pod
  /// listą nodów wraca do „Kup miejsce". Jedno pytanie z liczbą plików — nic więcej do wpisania.
  Future<void> _close() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                backgroundColor: AppTheme.card,
                title: Text(tr('Zamknąć pakiet?'),
                    style: const TextStyle(color: AppTheme.text)),
                content: Text(
                    tr('Usunie %s plików u sprzedawców. Opłaty kończą się z tą dobą, ponowny zakup zaczyna od zera.',
                        [_items.length]),
                    style: const TextStyle(color: AppTheme.muted)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(tr('Anuluj'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFFF6666)),
                      child: Text(tr('Zamknij pakiet'))),
                ]));
    if (ok != true) return;
    await _run(tr('Zamykam pakiet…'), () async {
      final r = await _relay!.close();
      if (r['ok'] != true) throw Exception(r['error'] ?? 'close failed');
      if (!mounted) return;
      _snack(tr('Pakiet zamknięty'));
      Navigator.pop(context);
    });
  }

  // ── stan/UI ──
  Future<void> _run(String? label, Future<void> Function() body) async {
    setState(() {
      _busy = label;
      _progress = null;
      _error = null;
    });
    try {
      await body();
    } catch (e) {
      if (mounted) setState(() => _error = _powod(e));
    }
    if (mounted)
      setState(() {
        _busy = null;
        _progress = null;
      });
  }

  void _setBusy(String s) {
    if (mounted)
      setState(() {
        _busy = s;
        _progress = null;
      });
  }

  void _setProgress(double p) {
    if (mounted) setState(() => _progress = p.clamp(0, 1));
  }

  /// Którędy poszły bajty ostatniego transferu. Kupujący nic tu nie wybiera — decyduje serwer —
  /// ale ma prawo widzieć, czy jego plik szedł wprost od hosta, czy przez nas.
  String _route() =>
      _relay?.lastRoute == 'direct' ? tr('bezpośrednio') : tr('przez serwer');

  void _snack(String s) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  // BIGINT z Postgresa przychodzi przez JSON jako tekst — rzut `as num` wywalał ekran.
  num _n(dynamic v) => v is num ? v : (num.tryParse('$v') ?? 0);
  String _gb(num b) =>
      (b / 1073741824).toStringAsFixed(b >= 1073741824 ? 1 : 2);
  String _mb(num b) => b >= 1048576
      ? '${(b / 1048576).toStringAsFixed(1)} MB'
      : '${(b / 1024).toStringAsFixed(0)} KB';

  @override
  Widget build(BuildContext context) {
    final ready = _relay != null && _box != null;
    return Scaffold(
      appBar:
          AppBar(title: Text(_folder.isEmpty ? tr('Dysk') : _folder), actions: [
        if (_pkg != null && _busy == null)
          IconButton(
            tooltip: tr('Nowy folder'),
            onPressed: _nowyFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
        if (_pkg != null && _busy == null)
          PopupMenuButton<String>(
            onSelected: (_) => _close(),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'close', child: Text(tr('Zamknij pakiet')))
            ],
          ),
      ]),
      floatingActionButton: (_pkg != null && _busy == null)
          ? FloatingActionButton.extended(
              onPressed: _upload,
              backgroundColor: AppTheme.teal,
              heroTag: null,
              icon: const Icon(Icons.upload_file, color: Colors.black),
              label: Text(tr('Dodaj plik'),
                  style: const TextStyle(color: Colors.black)))
          : null,
      body: !ready && _error == null && !_zablokowany
          ? const Center(child: CircularProgressIndicator())
          : _lista(),
    );
  }

  /// Wiersze budowane LENIWIE — powstaja dopiero, gdy wchodza w kadr. Wczesniej lista tworzyla
  /// wszystkie naraz i przy stu plikach potrafila polozyc ekran.
  Widget _lista() {
    final kat = _pkg == null ? const <String>[] : _podkatalogi;
    final pliki = _pkg == null ? const <Map<String, dynamic>>[] : _tutaj;
    final widoczne = pliki.length;
    final zostalo = (_wWidoku - widoczne).clamp(0, 1 << 30);
    final wstecz = _folder.isEmpty ? 0 : 1;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 1 + wstecz + kat.length + widoczne + (_pkg == null ? 0 : 1),
      itemBuilder: (_, i) {
        if (i == 0) return _naglowek();
        var k = i - 1;
        if (wstecz == 1) {
          if (k == 0) return _wierszPowrotu();
          k -= 1;
        }
        if (k < kat.length) return _wierszKatalogu(kat[k]);
        k -= kat.length;
        if (k < widoczne) return _fileTile(pliki[k]);
        return _stopka(zostalo);
      },
    );
  }

  /// Powrot na samej gorze — tak jak w kazdym menedzerze plikow.
  Widget _wierszPowrotu() => Card(
        color: AppTheme.card,
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: const Icon(Icons.arrow_back, color: AppTheme.muted),
          title: Text(_folder,
              style: const TextStyle(color: AppTheme.text),
              overflow: TextOverflow.ellipsis),
          subtitle: Text(tr('Wróć wyżej'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          onTap: () => _wejdz(_folder.contains('/')
              ? _folder.substring(0, _folder.lastIndexOf('/'))
              : ''),
        ),
      );

  Widget _wierszKatalogu(String sciezka) {
    final nazwa = sciezka.contains('/')
        ? sciezka.substring(sciezka.lastIndexOf('/') + 1)
        : sciezka;
    final ile = _ilePlikow(sciezka);
    return Card(
      color: AppTheme.card,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.folder, color: AppTheme.teal),
        title: Text(nazwa,
            style: const TextStyle(color: AppTheme.text),
            overflow: TextOverflow.ellipsis),
        subtitle: Text(tr('plików: %s', [ile]),
            style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
        trailing:
            const Icon(Icons.chevron_right, color: AppTheme.muted, size: 20),
        onTap: () => _wejdz(sciezka),
      ),
    );
  }

  Widget _naglowek() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_zablokowany)
          _portfelCard()
        else if (_pkg != null)
          _packageCard()
        else if (_loadFailed)
          _retryCard()
        else
          _capacityCard(),
        if (_busy != null) ...[
          const SizedBox(height: 12),
          Text(_busy!,
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          const SizedBox(height: 6),
          LinearProgressIndicator(
              value: _progress,
              color: AppTheme.teal,
              backgroundColor: AppTheme.surface),
        ],
        if (_error != null)
          Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!,
                  style: const TextStyle(color: AppTheme.amber, fontSize: 12))),
        const SizedBox(height: 16),
        if (_pkg != null && _items.isEmpty && _podkatalogi.isEmpty)
          Text(
              _folder.isEmpty ? tr('Brak plików') : tr('Ten folder jest pusty'),
              style: const TextStyle(color: AppTheme.muted)),
      ]);

  Widget _stopka(int zostalo) => Column(children: [
        if (zostalo > 0) ...[
          const SizedBox(height: 4),
          SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                // Kolejna strona przychodzi Z SERWERA — nie odsłaniamy czegoś, co i tak już mamy
                // w pamięci, tylko dociągamy dokładnie tyle, ile trzeba.
                onPressed: _busy != null || _dociagam
                    ? null
                    : () async {
                        setState(() => _dociagam = true);
                        try {
                          await _refresh(dalej: true);
                        } catch (_) {}
                        if (mounted) setState(() => _dociagam = false);
                      },
                icon: _dociagam
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppTheme.teal))
                    : const Icon(Icons.expand_more, size: 18),
                style: OutlinedButton.styleFrom(foregroundColor: AppTheme.teal),
                label: Text(tr('Pokaż więcej (%s)', [zostalo])),
              )),
        ],
        const SizedBox(height: 72),
      ]);

  Widget _card(List<Widget> children) => Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: AppTheme.card, borderRadius: BorderRadius.circular(12)),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: children));

  /// Widełki wyboru bierzemy z serwera; zapasowe wartości są na wypadek, gdyby `capacity`
  /// jeszcze nie doszło — lepiej pokazać sensowny wybór niż pojedynczy martwy przycisk.
  int _capInt(String klucz, int zapas) {
    final v = _n(_capacity?[klucz]).toInt();
    return v > 0 ? v.clamp(1, 4).toInt() : zapas;
  }

  Widget _packageCard() {
    final limit = _n(_pkg!['limit_b']), used = _n(_pkg!['used_b']);
    final daily = _n(_pkg!['daily']),
        sellers = (_pkg!['sellers'] as List?)?.length ?? 0;
    final chcianeKopii = _n(_pkg!['copies']).toInt().clamp(1, 4).toInt();
    // Cena za GB przychodzi z serwera (service_fees) — nic na sztywno.
    final stepGalu =
        (_n(_pkg!['price_gb'] ?? 0.1) * sellers).toStringAsFixed(1);
    final canShrink = limit > 1073741824 && limit - 1073741824 >= used;
    return _card([
      Text(tr('Pakiet %s GB · zajęte %s GB', [_gb(limit), _gb(used)]),
          style: const TextStyle(
              color: AppTheme.text, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      LinearProgressIndicator(
          value: limit > 0 ? (used / limit).clamp(0, 1).toDouble() : 0,
          color: AppTheme.teal,
          backgroundColor: AppTheme.surface),
      const SizedBox(height: 8),
      Text(
          tr('%s GALU na dobę · kopii: %s',
              [daily.toStringAsFixed(1), sellers]),
          style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
      // Ile kopii pakiet MA MIEĆ, a ile ich naprawdę stoi. Gdy host zamilknie, te liczby się
      // rozjeżdżają — i lepiej to pokazać, niż udawać komplet do czasu odbudowy.
      if (chcianeKopii > sellers)
        Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                tr('Odbudowa: %s z %s kopii na miejscu',
                    [sellers, chcianeKopii]),
                style: const TextStyle(color: AppTheme.amber, fontSize: 12))),
      const SizedBox(height: 10),
      _copiesPicker(_capInt('min_copies', 2), _capInt('max_copies', 4),
          _capInt('default_copies', 3), chcianeKopii, _setCopies),
      if (_n(_pkg!['unpaid_days']) > 0)
        Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                tr('Zaległość: %s dni — wysyłki wstrzymane, doładuj GALU',
                    [_n(_pkg!['unpaid_days']).toInt()]),
                style: const TextStyle(color: AppTheme.amber, fontSize: 12))),
      const SizedBox(height: 10),
      // Jeden pod drugim, na całą szerokość. Obok siebie etykiety nie mieściły się i `FittedBox`
      // zbijał je do nieczytelnego rozmiaru — lepiej dwa wiersze niż czcionka, której nikt nie odczyta.
      SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
              onPressed: _busy == null ? _grow : null,
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('Dokup 1 GB (+%s GALU/dobę)', [stepGalu])),
              style: OutlinedButton.styleFrom(foregroundColor: AppTheme.teal))),
      const SizedBox(height: 8),
      SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
              onPressed: _busy == null && canShrink ? _shrink : null,
              icon: const Icon(Icons.remove, size: 18),
              label: Text(tr('Zmniejsz o 1 GB (−%s GALU/dobę)', [stepGalu])),
              style:
                  OutlinedButton.styleFrom(foregroundColor: AppTheme.muted))),
      // Archiwum pakuje pomiary Z NODÓW. Bez nodów nie ma czego archiwizować, więc
      // przełącznik byłby ofertą na pusto.
      if (context.watch<NodeService>().nodes.isNotEmpty) ...[
        const Divider(height: 24, color: AppTheme.surface),
        _archiveTile(),
      ],
    ]);
  }

  /// Ekran bez pakietu = strona usługi, nie kasa. Kafel na liście nodów tylko tu prowadzi;
  /// decyzja o zakupie zapada dopiero tutaj, gdy widać, o co chodzi i ile to kosztuje.
  /// Kafel archiwum. Trzy stany: wyłączone, działa (z datą ostatniej doby), wstrzymane z powodem.
  /// Powód wstrzymania pokazujemy dosłownie — „pakiet pełny" albo „brak sprzedawców" to jedyne
  /// rzeczy, które właściciel może naprawić sam, a bez tego nie wiedziałby nawet, że stanęło.
  Widget _archiveTile() {
    final on = _archive?['enabled'] == true;
    final last = _archive?['last_day']?.toString();
    final paused = _archive?['paused_reason']?.toString();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
            child: Text(tr('Archiwum pomiarów'),
                style: const TextStyle(
                    color: AppTheme.text, fontWeight: FontWeight.w600))),
        Switch(
            value: on,
            activeColor: AppTheme.teal,
            onChanged: _busy == null ? _setArchive : null),
      ]),
      Text(
          tr(
              'Pomiary z Twoich nodów kasujemy po 48 godzinach. Włącz, a raz na dobę wylądują '
              'w tym pakiecie — zaszyfrowane Twoim kluczem, więc my ich nie odczytamy. Rok '
              'historii jednego noda to kilka MB.'),
          style: const TextStyle(
              color: AppTheme.muted, fontSize: 12, height: 1.35)),
      if (on && paused != null && paused.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
              tr('Wstrzymane: %s — przestaw przełącznik, żeby wznowić.',
                  [paused]),
              style: const TextStyle(color: AppTheme.amber, fontSize: 12)),
        )
      else if (on && last != null && last.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(tr('Ostatnia zapisana doba: %s', [last.split('T').first]),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
        )
      else if (on)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
              tr('Pierwsza paczka pojawi się po najbliższej pełnej dobie.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
        ),
    ]);
  }

  /// Zamknięty portfel: jedno zdanie prawdy i jedno wyjście. Żadnych liczb o sieci — nie znamy
  /// ich, bo bez klucza nie było jak zapytać.
  Widget _portfelCard() => _card([
        Row(children: [
          const Icon(Icons.lock_outline, color: AppTheme.teal, size: 20),
          const SizedBox(width: 8),
          Text(tr('Portfel zablokowany'),
              style: const TextStyle(
                  color: AppTheme.text, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 6),
        Text(
            tr(
                'Twoje pliki szyfruje klucz z portfela, więc bez odblokowania nie ma czym '
                'ich otworzyć ani sprawdzić miejsca w sieci.'),
            style: const TextStyle(
                color: AppTheme.muted, fontSize: 12, height: 1.35)),
        const SizedBox(height: 12),
        SizedBox(
            width: double.infinity,
            child: FilledButton(
                onPressed: _odblokuj,
                style: FilledButton.styleFrom(backgroundColor: AppTheme.teal),
                child: Text(tr('Odblokuj portfel'),
                    style: const TextStyle(color: Colors.black)))),
      ]);

  Widget _capacityCard() {
    final c = _capacity;
    final minC = _capInt('min_copies', 2), maxC = _capInt('max_copies', 4);
    final recC = _capInt('default_copies', 3);
    final copies = (_wantCopies ?? recC).clamp(minC, maxC).toInt();
    // Sufit zależy od liczby kopii — każda musi trafić do innego właściciela, więc im ich więcej,
    // tym mniejszy najsłabszy z potrzebnych. Serwer podaje gotową tabelkę.
    final maxGb =
        _n((c?['max_gb_by_copies'] as Map?)?['$copies'] ?? c?['max_gb'])
            .toInt();
    final priceGb = _n(c?['price_gb_copy'] ?? 0.1) *
        copies; // GALU/GB/dobę przy tym wyborze
    final gb = _wantGb.clamp(1, maxGb < 1 ? 1 : maxGb).toInt();
    return _card([
      Text(tr('Miejsce w sieci'),
          style: const TextStyle(
              color: AppTheme.text, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Text(
          tr(
              'Twoje pliki szyfruje telefon kluczem z portfela. Sprzedawcy trzymają szyfrogram '
              'u różnych właścicieli i nie mogą go odczytać.'),
          style: const TextStyle(
              color: AppTheme.muted, fontSize: 12, height: 1.35)),
      const SizedBox(height: 10),
      if (c != null)
        _copiesPicker(
            minC, maxC, recC, copies, (n) => setState(() => _wantCopies = n)),
      const SizedBox(height: 10),
      if (c != null) ...[
        Text(
            tr('Sprzedawców gotowych: %s · wolne w sieci: %s GB',
                [c['sellers_ready'] ?? 0, c['free_gb'] ?? 0]),
            style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
        if (c['test_mode'] == true)
          Text(tr('Tryb testowy'),
              style: const TextStyle(color: AppTheme.amber, fontSize: 12)),
      ],
      const SizedBox(height: 10),
      if (maxGb > 0) ...[
        Text(
            tr('%s GB · %s GALU na dobę',
                [gb, (gb * priceGb).toStringAsFixed(1)]),
            style: const TextStyle(
                color: AppTheme.text, fontWeight: FontWeight.w600)),
        // Suwak, nie pole tekstowe: na telefonie nikt nie chce klawiatury, a górna granica to
        // realne wolne miejsce, więc nie da się wybrać pakietu, którego nikt nie obsłuży.
        Slider(
          value: gb.toDouble(),
          min: 1,
          max: maxGb.toDouble(),
          divisions: maxGb > 1 ? maxGb - 1 : null,
          label: '$gb GB',
          activeColor: AppTheme.teal,
          onChanged:
              _busy != null ? null : (v) => setState(() => _wantGb = v.round()),
        ),
        Text(tr('Do wyboru teraz: %s GB', [maxGb]),
            style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
        const SizedBox(height: 10),
        SizedBox(
            width: double.infinity,
            child: FilledButton(
                onPressed: _busy == null ? () => _buy(gb, copies) : null,
                style: FilledButton.styleFrom(backgroundColor: AppTheme.teal),
                child: Text(tr('Wykup %s GB', [gb])))),
      ] else
        Text(tr('Brak wolnego miejsca — wróć później'),
            style: const TextStyle(color: AppTheme.amber)),
    ]);
  }

  /// Wybór liczby kopii. Zalecana jest opisana, a nie tylko podświetlona — człowiek ma wiedzieć
  /// DLACZEGO, zanim zapłaci o połowę więcej.
  Widget _copiesPicker(
          int min, int max, int rec, int value, void Function(int) onPick) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Ile kopii'),
            style: const TextStyle(color: AppTheme.text, fontSize: 13)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          for (var n = min; n <= max; n++)
            ChoiceChip(
              selected: value == n,
              onSelected: _busy == null ? (_) => onPick(n) : null,
              selectedColor: AppTheme.teal.withValues(alpha: 0.22),
              backgroundColor: AppTheme.surface,
              side: BorderSide(
                  color: value == n ? AppTheme.teal : AppTheme.border),
              label: Text(n == rec ? tr('%s · zalecane', [n]) : '$n',
                  style: TextStyle(
                      color: value == n ? AppTheme.teal : AppTheme.muted,
                      fontSize: 12)),
            ),
        ]),
        const SizedBox(height: 6),
        Text(
            tr(
                'Host, który zamilknie, wypada z pakietu dopiero po trzech dobach i dopiero wtedy '
                'kopia odbudowuje się gdzie indziej. Przy dwóch kopiach plik wisi przez ten czas '
                'na jednym dysku, przy trzech — na dwóch.'),
            style: const TextStyle(
                color: AppTheme.muted, fontSize: 11, height: 1.35)),
      ]);

  Widget _fileTile(Map<String, dynamic> it) {
    final name = _nazwaPliku(it);
    final copies = _n(it['copies']).toInt();
    final created = DateTime.tryParse('${it['created_at']}')?.toLocal();
    return Card(
      color: AppTheme.card,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading:
            const Icon(Icons.insert_drive_file_outlined, color: AppTheme.teal),
        title: Text(name,
            style: const TextStyle(color: AppTheme.text),
            overflow: TextOverflow.ellipsis),
        subtitle: Text(
            '${_mb(_n(it['size_b']))} · ${tr('kopii: %s', [copies])}'
            '${created != null ? ' · ${created.day}.${created.month.toString().padLeft(2, '0')}' : ''}',
            style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
        trailing: const Icon(Icons.download, color: AppTheme.muted, size: 20),
        onTap: _busy == null ? () => _download(it) : null,
        onLongPress: _busy == null ? () => _delete(it) : null,
      ),
    );
  }
}
