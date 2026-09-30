import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import '../l10n.dart';
import '../log.dart';
import 'kom_ble.dart';
import 'kom_frames.dart';
import 'wallet_service.dart';

/// Wiadomość w rozmowie. `via`: 'net' (internet) albo 'radio' (ramka przez komunikator).
class KomChatMsg {
  final String id, text, via;
  final bool out;
  final DateTime at;
  final String? from;                 // nadawca w grupie (ID)
  String status;                      // wysłane: 'sent' | 'delivered' | 'failed'
  KomChatMsg(this.id, this.text, this.via, this.out, this.at, {this.from, this.status = 'sent'});
  Map<String, dynamic> toJson() => {'id': id, 't': text, 'v': via, 'o': out, 'a': at.millisecondsSinceEpoch, 'f': from, 's': status};
  static KomChatMsg of(Map<String, dynamic> j) => KomChatMsg('${j['id']}', '${j['t']}', '${j['v']}', j['o'] == true,
      DateTime.fromMillisecondsSinceEpoch((j['a'] as num).toInt()), from: j['f'] as String?, status: '${j['s'] ?? 'sent'}');
}

class KomContact {
  final String id8, pub;
  String name;
  KomContact(this.id8, this.pub, this.name);
  Map<String, dynamic> toJson() => {'id8': id8, 'pub': pub, 'name': name};
}

class KomGroupDef {
  final String gid8, keyHex, keyText;
  String name;
  KomGroupDef(this.gid8, this.keyHex, this.keyText, this.name);
  Map<String, dynamic> toJson() => {'gid8': gid8, 'key': keyHex, 'text': keyText, 'name': name};
}

// Nazwa nadawcy w treści wiadomości: pierwszy bajt < 0x20 to długość nazwy — tekst nie zawiera
// znaków sterujących, więc wiadomość bez nazwy nie kosztuje ani bajta.
String komWithName(String name, String text) => '${String.fromCharCode(utf8.encode(name).length)}$name$text';

(String?, String) komSplitName(String s) {
  final b = utf8.encode(s);
  if (b.isEmpty || b[0] == 0 || b[0] >= 0x20 || 1 + b[0] > b.length) return (null, s);
  try {
    return (utf8.decode(b.sublist(1, 1 + b[0])), utf8.decode(b.sublist(1 + b[0])));
  } catch (_) {
    return (null, s);
  }
}

/// Rozmowy i grupy komunikatora w apce. Tożsamość (klucz X25519, ID) wynika z portfela, więc po
/// reinstalacji wraca to samo ID. Wysyłka: automatycznie = najpierw internet, bez internetu przez
/// podłączony komunikator; „radio” = zawsze przez komunikator. Odbiór: skrzynka serwera i ramki
/// z komunikatora — wiadomość ma oznaczenie, którą drogą przyszła.
class KomChat extends ChangeNotifier {
  KomChat._();
  static final instance = KomChat._();

  // Klucz publiczny serwera (GET /v1/ldev/key) — ten sam co w FW komunikatora.
  static final _bePub = komUnhex('a0a5230559529a5e26058e7415d3235bfbad71c3052bbe7765189bc213c60f51');
  static const _headers = {'Content-Type': 'application/json', 'X-App-Key': Config.appKey};
  static const _secure = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

  KomKeys? me;
  KomBle? ble;
  String mode = 'auto';
  String myName = '';
  final contacts = <String, KomContact>{};
  final groups = <String, KomGroupDef>{};
  final names = <String, String>{};           // nazwy innych, poznane z ich wiadomości i ogłoszeń
  final _msgs = <String, List<KomChatMsg>>{};
  final _seen = <String>{};
  // Moja nazwa idzie w wiadomościach do kontaktu, aż potwierdzi jedną z nich; w grupie z pierwszą
  // wiadomością po starcie apki i potem najwyżej raz na godzinę.
  final _nameOk = <String>{};
  final _named = <String>{};
  final _grpNamedAt = <String, DateTime>{};
  int _since = 0, _ctr = 0;
  Timer? _poll;
  StreamSubscription? _evSub;
  bool _starting = false;
  String? error;

  List<KomChatMsg> messages(String conv) => _msgs[conv] ?? const [];

  /// conv: 'c:<id8>' (kontakt) albo 'g:<gid8>' (grupa).
  DateTime? lastAt(String conv) => (_msgs[conv]?.isNotEmpty ?? false) ? _msgs[conv]!.last.at : null;

  Future<void> start(WalletService wallet, KomBle kom) async {
    ble = kom;
    if (me != null || _starting) return;
    _starting = true;
    try {
      var seed = await _secure.read(key: 'kom_app_seed');
      if (seed == null) {
        if (!await wallet.isUnlocked()) { error = 'wallet'; notifyListeners(); return; }
        seed = komHex(komSha(utf8.encode(await wallet.signMessage('sensmos:kom-id:v1'))));
        await _secure.write(key: 'kom_app_seed', value: seed);
      }
      me = await KomKeys.fromSeed(komUnhex(seed), _bePub);
      await _load();
      error = null;
      _evSub = kom.events.listen((j) {
        if (j['ev'] == 'frame' && j['hex'] is String) _process('${j['hex']}', 'radio');
      });
      kom.link.addListener(_onLink);
      _onLink();
      unawaited(register());
      _poll = Timer.periodic(const Duration(seconds: 5), (_) => pollBox());
      unawaited(pollBox());
      notifyListeners();
    } catch (e) {
      error = '$e';
      Log.w('kom', 'start: $e');
      notifyListeners();
    } finally {
      _starting = false;
    }
  }

  // Podłączony komunikator ma nasłuchiwać ramek do mnie i do moich grup, a zebrane bez telefonu oddać.
  // Ogłasza też mnie (moje HELLO z nazwą) i nosi moją nazwę.
  Future<void> _onLink() async {
    final k = ble, m = me;
    if (k == null || m == null || k.link.value != KomLink.ready) return;
    try {
      await k.request('watch', {'ids': [m.id8], 'gids': groups.keys.toList()});
      // Zebrane bez telefonu: komunikator z kopią moich kluczy już je potwierdził — nie potwierdzamy drugi raz.
      final devAcked = k.info.value?['keys_id8'] == m.id8;
      while (true) {
        final r = await k.request('frames');
        final hex = r['hex'];
        if (hex is String && hex.isNotEmpty) _process(hex, 'radio', acked: devAcked);
        if (r['more'] != true) break;
      }
    } catch (e) {
      Log.w('kom', 'watch: $e');
    }
    try {
      final want = <String, dynamic>{};
      if (myName.isNotEmpty && k.info.value?['name'] != myName) want['name'] = myName;
      if (k.info.value?['lang'] is String && k.info.value?['lang'] != L10n.lang) want['lang'] = L10n.lang;   // napisy ekranu w języku telefonu
      if (want.isNotEmpty) {
        await k.request('set', want);
        await k.refreshInfo();
      }
      final p = await SharedPreferences.getInstance();
      var adv = p.getString('kom_chat_adv');
      if (adv == null) {
        adv = komHex(m.hello(await _nextCtr(), 1, name: myName.isEmpty ? null : myName));
        await p.setString('kom_chat_adv', adv);
      }
      await k.request('advert', {'hex': adv});
    } catch (e) {
      Log.w('kom', 'advert: $e');
    }
    try {
      await _syncKeys(k, m);
    } catch (e) {
      Log.w('kom', 'keys: $e');
    }
  }

  // UTF-8 do `max` bajtów bez cięcia znaku.
  static List<int> _bytes(String s, int max) {
    var b = utf8.encode(s);
    while (b.length > max) { s = s.substring(0, s.length - 1); b = utf8.encode(s); }
    return b;
  }

  // Kopia kluczy do komunikatora (FW ≥ 0.15): czyta wiadomości sam, pokazuje je na ekranie, a bez
  // telefonu potwierdza odbiór. Pakiety szyfrowane do klucza urządzenia (`info.pub`). Licznik ramek
  // idzie w obie strony — obie tożsamości nadają tym samym ID, więc żadna nie może cofnąć licznika.
  Future<void> _syncKeys(KomBle k, KomKeys m) async {
    var info = k.info.value;
    if (info?['pub'] is! String) { await k.refreshInfo(); info = k.info.value; }
    final devPub = info?['pub'];
    if (devPub is! String || devPub.length != 64) return;          // starszy komunikator — bez kopii kluczy
    final dp = komUnhex(devPub);
    final devCtr = (info?['keys_ctr'] as num?)?.toInt() ?? 0;
    if (devCtr > _ctr) { _ctr = devCtr; await (await SharedPreferences.getInstance()).setInt('kom_chat_ctr', _ctr); }
    final c = _ctr, nm = _bytes(myName, 20);
    await k.request('keys', {'hex': komHex(await KomKeys.sealFor(dp, [...await m.seed(), (c >> 24) & 255, (c >> 16) & 255, (c >> 8) & 255, c & 255, nm.length, ...nm]))});
    await k.request('gkey', {'hex': ''});
    for (final g in groups.values) {
      final gn = _bytes(g.name, 16);
      await k.request('gkey', {'hex': komHex(await KomKeys.sealFor(dp, [...komUnhex(g.keyHex), gn.length, ...gn]))});
    }
    await k.request('cname', {'id8': ''});
    final ids = <String>{...contacts.keys, ...names.keys}.take(24);
    for (final id8 in ids) {
      final n = nameOf(id8);
      if (n != id8) await k.request('cname', {'id8': id8, 'name': String.fromCharCodes(utf8.decode(_bytes(n, 20)).runes)});
    }
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    mode = p.getString('kom_chat_mode') ?? 'auto';
    myName = p.getString('kom_chat_my_name') ?? '';
    names.addAll(Map<String, String>.from(jsonDecode(p.getString('kom_chat_names') ?? '{}')));
    _nameOk.addAll(p.getStringList('kom_chat_name_ok') ?? const []);
    _since = p.getInt('kom_chat_since') ?? 0;
    _ctr = p.getInt('kom_chat_ctr') ?? 0;
    for (final j in List<Map<String, dynamic>>.from(jsonDecode(p.getString('kom_chat_contacts') ?? '[]'))) {
      contacts[j['id8']] = KomContact(j['id8'], j['pub'], j['name'] ?? '');
    }
    for (final j in List<Map<String, dynamic>>.from(jsonDecode(await _secure.read(key: 'kom_chat_groups') ?? '[]'))) {
      groups[j['gid8']] = KomGroupDef(j['gid8'], j['key'], j['text'] ?? '', j['name'] ?? '');
    }
    for (final k in p.getKeys().where((k) => k.startsWith('kom_chat_m_'))) {
      final conv = k.substring('kom_chat_m_'.length);
      // Niewysłane (z wersji, która je zapisywała) nigdy nie wyszły z telefonu — nie ma ich w rozmowie.
      _msgs[conv] = [for (final j in List<Map<String, dynamic>>.from(jsonDecode(p.getString(k)!))) KomChatMsg.of(j)]
        ..removeWhere((m) => m.status == 'failed');
      _seen.addAll(_msgs[conv]!.map((m) => m.id));
    }
  }

  Future<void> _saveConv(String conv) async {
    final l = _msgs[conv]!;
    if (l.length > 300) l.removeRange(0, l.length - 300);
    await (await SharedPreferences.getInstance()).setString('kom_chat_m_$conv', jsonEncode(l.map((m) => m.toJson()).toList()));
  }

  Future<void> _saveContacts() async => (await SharedPreferences.getInstance())
      .setString('kom_chat_contacts', jsonEncode(contacts.values.map((c) => c.toJson()).toList()));

  Future<void> _saveGroups() async =>
      _secure.write(key: 'kom_chat_groups', value: jsonEncode(groups.values.map((g) => g.toJson()).toList()));

  Future<void> setMode(String m) async {
    mode = m;
    await (await SharedPreferences.getInstance()).setString('kom_chat_mode', m);
    notifyListeners();
  }

  /// Moja nazwa (do 10 znaków): kontakty i grupy dostaną ją od nowa, komunikator ogłasza nową.
  Future<void> setMyName(String n) async {
    myName = n;
    _nameOk.clear();
    _grpNamedAt.clear();
    final p = await SharedPreferences.getInstance();
    await p.setString('kom_chat_my_name', n);
    await p.remove('kom_chat_name_ok');
    await p.remove('kom_chat_adv');
    notifyListeners();
    unawaited(register());
    unawaited(_onLink());
  }

  Future<void> learnName(String id8, String name) async {
    if (name.isEmpty || names[id8] == name) return;
    names[id8] = name;
    await (await SharedPreferences.getInstance()).setString('kom_chat_names', jsonEncode(names));
    notifyListeners();
  }

  /// Ludzie z „W pobliżu” (ogłoszenia z kluczem): ich nazwy.
  void learnNear(List<Map<String, dynamic>> near) {
    for (final e in near) {
      final n = e['name'];
      if (e['kind'] == 'kom' && e['pub'] is String && n is String) unawaited(learnName('${e['id8']}', n));
    }
  }

  // Licznik ramek rośnie też po reinstalacji (ziarno z portfela) — dlatego nie niższy niż czas UNIX.
  Future<int> _nextCtr() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _ctr = _ctr + 1 > now ? _ctr + 1 : now;
    await (await SharedPreferences.getInstance()).setInt('kom_chat_ctr', _ctr);
    return _ctr;
  }

  /// null = serwer przyjął; inaczej przyczyna do pokazania.
  Future<String?> _post(Uint8List f) async {
    try {
      final res = await http.post(Uri.parse('${Config.beUrl}/v1/ldev/frame'),
          headers: _headers, body: jsonEncode({'hex': komHex(f)})).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) return null;
      String why = 'HTTP ${res.statusCode}';
      try { why = '${(jsonDecode(res.body) as Map)['error'] ?? why}'; } catch (_) {}
      return tr('Serwer odrzucił wiadomość (%s).', [why]);
    } catch (_) {
      return tr('Brak internetu i podłączonego komunikatora — wiadomość nie wyszła.');
    }
  }

  /// „Zawsze radiem” obowiązuje tylko z dodanym komunikatorem — bez niego zostaje internet.
  bool get radioOnly => mode == 'radio' && ble?.saved.value != null;

  /// Nadanie ramki: (droga 'net'|'radio', null) albo (null, przyczyna do pokazania).
  Future<(String?, String?)> _send(Uint8List f) async {
    String? why;
    if (!radioOnly) {
      why = await _post(f);
      if (why == null) return ('net', null);
    }
    final k = ble;
    if (k != null && k.link.value == KomLink.ready) {
      try {
        await k.request('raw', {'hex': komHex(f)}, const Duration(seconds: 20));
        return ('radio', null);
      } catch (e) {
        Log.w('kom', 'raw: $e');
        return (null, komErrText(e));
      }
    }
    return (null, radioOnly ? tr('Ustawione „Zawsze radiem”, a komunikator nie jest podłączony — wiadomość nie wyszła.') : why);
  }

  /// Ogłoszenie apki w sieci: klucz (żeby inni mogli do niej pisać) i odciski grup.
  Future<void> register() async {
    final m = me;
    if (m == null) return;
    await _send(m.hello(await _nextCtr(), 1,
        name: myName.isEmpty ? null : myName, groups: [for (final g in groups.keys) komUnhex(g)]));
  }

  Future<void> pollBox() async {
    final m = me;
    if (m == null) return;
    try {
      final res = await http.get(Uri.parse('${Config.beUrl}/v1/ldev/box')
          .replace(queryParameters: {'id': m.id8, 'since': '$_since'}), headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      for (final f in List<Map<String, dynamic>>.from(j['frames'] ?? const [])) {
        await _process('${f['hex']}', 'net');
      }
      final next = (j['next'] as num?)?.toInt() ?? _since;
      if (next != _since) {
        _since = next;
        await (await SharedPreferences.getInstance()).setInt('kom_chat_since', _since);
      }
    } catch (_) {}
  }

  void _add(String conv, KomChatMsg msg) {
    (_msgs[conv] ??= []).add(msg);
    _seen.add(msg.id);
    unawaited(_saveConv(conv));
    notifyListeners();
  }

  Future<void> _process(String hex, String via, {bool acked = false}) async {
    final m = me;
    final f = KomFrame.parse(komUnhex(hex));
    if (m == null || f == null || f.src8 == m.id8) return;
    if (_seen.contains(f.key)) return;
    if (f.mode == komModePriv && f.dst8 == m.id8) {
      final got = await f.openPriv(m);
      if (got == null) return;
      final (pub, raw) = got;
      final (name, text) = komSplitName(raw);
      if (name != null) await learnName(f.src8, name);
      if (!contacts.containsKey(f.src8)) {
        contacts[f.src8] = KomContact(f.src8, komHex(pub), '');
        await _saveContacts();
      }
      _add('c:${f.src8}', KomChatMsg(f.key, text, via, false, DateTime.now()));
      if (!acked) unawaited(m.ack(pub, await _nextCtr(), [f.ctr]).then(_send));
    } else if (f.mode == komModeAck && f.dst8 == m.id8) {
      final c = contacts[f.src8];
      if (c == null) return;
      final refs = await f.openAck(m, komUnhex(c.pub));
      if (refs == null) return;
      _seen.add(f.key);
      for (final msg in messages('c:${f.src8}')) {
        if (msg.out && refs.any((r) => msg.id == '${m.id8}:$r')) msg.status = 'delivered';
      }
      if (refs.any((r) => _named.contains('${f.src8}:$r')) && _nameOk.add(f.src8)) {
        await (await SharedPreferences.getInstance()).setStringList('kom_chat_name_ok', _nameOk.toList());
      }
      unawaited(_saveConv('c:${f.src8}'));
      notifyListeners();
    } else if (f.mode == komModeGroup) {
      final g = groups[f.dst8];
      final raw = g == null ? null : f.openGroup(komUnhex(g.keyHex));
      if (raw == null) return;
      final (name, text) = komSplitName(raw);
      if (name != null) await learnName(f.src8, name);
      _add('g:${f.dst8}', KomChatMsg(f.key, text, via, false, DateTime.now(), from: f.src8));
    }
  }

  /// Wysłanie wiadomości do kontaktu albo grupy. Zwraca null albo przyczynę, dla której nie wyszła —
  /// wtedy wiadomość nie trafia do rozmowy (tekst zostaje w polu).
  Future<String?> send(String conv, String text) async {
    final m = me;
    if (m == null) return tr('Odblokuj portfel, żeby uruchomić rozmowy.');
    final ctr = await _nextCtr();
    final id = conv.substring(2), now = DateTime.now();
    final Uint8List f;
    var named = false;
    if (conv.startsWith('c:')) {
      final c = contacts[id];
      if (c == null) return tr('Nie ma już tego kontaktu.');
      named = myName.isNotEmpty && !_nameOk.contains(id);
      f = await m.priv(komUnhex(c.pub), ctr, named ? komWithName(myName, text) : text);
    } else {
      final g = groups[id];
      if (g == null) return tr('Nie ma już tej grupy.');
      final t = _grpNamedAt[id];
      named = myName.isNotEmpty && (t == null || now.difference(t) > const Duration(hours: 1));
      f = m.group(komUnhex(g.keyHex), ctr, named ? komWithName(myName, text) : text);
    }
    final (via, why) = await _send(f);
    if (via == null) return why;
    if (named) {
      if (conv.startsWith('c:')) {
        _named.add('$id:$ctr');
      } else {
        _grpNamedAt[id] = now;
      }
    }
    _add(conv, KomChatMsg('${m.id8}:$ctr', text, via, true, DateTime.now(),
        status: conv.startsWith('g:') ? 'delivered' : 'sent'));
    return null;
  }

  Future<void> addContact(String id8, String pub, String name) async {
    contacts[id8] = KomContact(id8, pub, name);
    await _saveContacts();
    notifyListeners();
    unawaited(_onLink());
  }

  Future<void> removeContact(String id8) async {
    contacts.remove(id8);
    _msgs.remove('c:$id8');
    await _saveContacts();
    await (await SharedPreferences.getInstance()).remove('kom_chat_m_c:$id8');
    notifyListeners();
  }

  /// Klucz publiczny po ID z serwera (widoczne komunikatory i apki).
  Future<Map<String, dynamic>?> lookup(String id8) async {
    try {
      final res = await http.get(Uri.parse('${Config.beUrl}/v1/ldev/pub/$id8'), headers: _headers)
          .timeout(const Duration(seconds: 8));
      return res.statusCode == 200 ? jsonDecode(res.body) as Map<String, dynamic> : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> addGroup(Uint8List key, String keyText, String name) async {
    final gid8 = komHex(komGroupId(key));
    groups[gid8] = KomGroupDef(gid8, komHex(key), keyText, name);
    await _saveGroups();
    notifyListeners();
    unawaited(register());
    unawaited(_onLink());
    return gid8;
  }

  Future<void> removeGroup(String gid8) async {
    groups.remove(gid8);
    _msgs.remove('g:$gid8');
    await _saveGroups();
    await (await SharedPreferences.getInstance()).remove('kom_chat_m_g:$gid8');
    notifyListeners();
    unawaited(register());
    unawaited(_onLink());
  }

  Future<void> renameGroup(String gid8, String name) async {
    final g = groups[gid8];
    if (g == null) return;
    g.name = name;
    await _saveGroups();
    notifyListeners();
  }

  /// Nazwa, którą sam nadałeś kontaktowi, a bez niej ta, którą ktoś sam sobie nadał.
  String nameOf(String id8) {
    final c = contacts[id8];
    return c != null && c.name.isNotEmpty ? c.name : names[id8] ?? id8;
  }

  @override
  void dispose() {
    _poll?.cancel();
    _evSub?.cancel();
    super.dispose();
  }
}
