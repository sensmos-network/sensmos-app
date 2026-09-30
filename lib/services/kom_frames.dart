import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart' as cg;
import 'package:pointycastle/export.dart' show AESEngine, CTRStreamCipher, KeyParameter, ParametersWithIV;

/// Ramka urządzenia E0 04 po stronie apki — to samo co komunikator (FW src/kom/kom_frame.cpp) i serwer
/// (BE services/ldev.js, tools/ldev_fixture.js): apka jest komunikatorem, który nadaje przez internet
/// albo przez podłączony komunikator.
const komModePriv = 0, komModeGroup = 1, komModeHello = 2, komModeAck = 3;

Uint8List _u8(List<int> b) => Uint8List.fromList(b);
Uint8List _cat(List<List<int>> parts) => _u8([for (final p in parts) ...p]);
Uint8List komHmac(List<int> k, List<int> d) => _u8(c.Hmac(c.sha256, k).convert(d).bytes);
Uint8List komSha(List<int> d) => _u8(c.sha256.convert(d).bytes);
String komHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List komUnhex(String h) => _u8([for (var i = 0; i + 1 < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

// HKDF-SHA256 (RFC 5869), sól 32×0 jak wszędzie w E0 04.
Uint8List komHkdf(List<int> ikm, List<int> info, int len) {
  final prk = komHmac(Uint8List(32), ikm);
  final out = <int>[];
  var t = <int>[];
  for (var i = 1; out.length < len; i++) {
    t = komHmac(prk, [...t, ...info, i]);
    out.addAll(t);
  }
  return _u8(out.sublist(0, len));
}

Uint8List _ctr(List<int> key, List<int> nonce8, List<int> src4, List<int> data) {
  final ci = CTRStreamCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(_u8(key)), _cat([nonce8, src4, Uint8List(4)])));
  return ci.process(_u8(data));
}

Uint8List _u32(int n) => _u8([(n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255]);
int _rd32(List<int> b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

/// Tożsamość: para X25519 z 32 B ziarna; ID = SHA-256(pub)[0:4]; K_net wspólny z serwerem.
class KomKeys {
  final cg.SimpleKeyPair pair;
  final Uint8List pub, id4, knet;
  KomKeys._(this.pair, this.pub, this.id4, this.knet);
  String get id8 => komHex(id4);

  static final _x = cg.X25519();

  static Future<KomKeys> fromSeed(List<int> seed, List<int> bePub) async {
    final kp = await _x.newKeyPairFromSeed(seed);
    final pub = _u8((await kp.extractPublicKey()).bytes);
    final ss = await _dh(kp, bePub);
    final knet = komHkdf(ss, _cat([utf8.encode('sensmos-ldev-net-v1'), pub, bePub]), 32);
    return KomKeys._(kp, pub, komSha(pub).sublist(0, 4), knet);
  }

  static Future<Uint8List> _dh(cg.SimpleKeyPair kp, List<int> peer) async => _u8(await (await _x.sharedSecretKey(
      keyPair: kp, remotePublicKey: cg.SimplePublicKey(peer, type: cg.KeyPairType.x25519))).extractBytes());

  /// Ziarno = klucz prywatny X25519 (32 B) — kopia dla komunikatora.
  Future<Uint8List> seed() async => _u8(await pair.extractPrivateKeyBytes());

  /// Pakiet dla komunikatora (FW `keys`/`gkey`): ephPub ‖ nonce8 ‖ AES-CTR(plain) ‖ HMAC[0:8],
  /// klucz = HKDF(X25519(eph, devPub), "sensmos-kom-keys-v1" ‖ ephPub ‖ devPub). Podsłuch BLE nic nie dostaje.
  static Future<Uint8List> sealFor(List<int> devPub, List<int> plain) async {
    final eph = await _x.newKeyPair();
    final ephPub = _u8((await eph.extractPublicKey()).bytes);
    final okm = komHkdf(await _dh(eph, devPub), _cat([utf8.encode('sensmos-kom-keys-v1'), ephPub, devPub]), 64);
    final n8 = _rnd8();
    final body = _cat([ephPub, n8, _ctr(okm.sublist(0, 32), n8, Uint8List(4), plain)]);
    return _cat([body, komHmac(okm.sublist(32), body).sublist(0, 8)]);
  }

  // Klucze E2E kierunku nadawca → adresat: HKDF(X25519, "sensmos-ldev-e2e-v1" ‖ pub nadawcy ‖ pub adresata).
  Future<Uint8List> e2e(List<int> senderPub, List<int> recipientPub, List<int> peerPub) async =>
      komHkdf(await _dh(pair, peerPub), _cat([utf8.encode('sensmos-ldev-e2e-v1'), senderPub, recipientPub]), 64);

  Uint8List _header(int flags, List<int> dst4, int ctr) => _cat([[0xE0, 0x04, flags], dst4, id4, _u32(ctr)]);
  Uint8List _seal(List<int> body) => _cat([body, komHmac(knet, body).sublist(0, 4)]);

  /// HELLO z kluczem (zawsze — apka nie wie, czy serwer już ją zna), nazwą i odciskami grup (null = bez pola).
  Uint8List hello(int ctr, int vis, {String? name, List<Uint8List>? groups}) {
    final n = name == null || name.isEmpty ? null : utf8.encode(name);
    var hf = (vis & 3) | 0x04;
    if (n != null) hf |= 0x10;
    if (groups != null) hf |= 0x20;
    return _seal(_cat([
      _header(komModeHello, [0xFF, 0xFF, 0xFF, 0xFF], ctr), [hf], pub,
      if (n != null) [n.length, ...n],
      if (groups != null) [groups.length, for (final g in groups) ...g],
    ]));
  }

  /// Wiadomość prywatna z kluczem nadawcy (PUB) — adresat nie musi nas znać wcześniej.
  Future<Uint8List> priv(List<int> peerPub, int ctr, String text, {List<int>? nonce}) async {
    final okm = await e2e(pub, peerPub, peerPub);
    final n8 = nonce ?? _rnd8();
    final pre = _cat([_header(0x10, komSha(peerPub).sublist(0, 4), ctr), pub, n8,
                      _ctr(okm.sublist(0, 32), n8, id4, utf8.encode(text))]);
    return _seal(_cat([pre, komHmac(okm.sublist(32), pre).sublist(0, 8)]));
  }

  /// Potwierdzenie E2E (tryb 3) do nadawcy wiadomości: refs = jego liczniki.
  Future<Uint8List> ack(List<int> peerPub, int ctr, List<int> refs) async {
    final okm = await e2e(pub, peerPub, peerPub);
    final pre = _cat([_header(komModeAck, komSha(peerPub).sublist(0, 4), ctr), for (final r in refs) _u32(r)]);
    return _seal(_cat([pre, komHmac(okm.sublist(32), pre).sublist(0, 8)]));
  }

  Uint8List group(List<int> key, int ctr, String text, {List<int>? nonce}) {
    final okm = komHkdf(key, utf8.encode('sensmos-grp-msg-v1'), 64);
    final n8 = nonce ?? _rnd8();
    final pre = _cat([_header(komModeGroup, komGroupId(key), ctr), n8, _ctr(okm.sublist(0, 32), n8, id4, utf8.encode(text))]);
    return _seal(_cat([pre, komHmac(okm.sublist(32), pre).sublist(0, 8)]));
  }
}

Uint8List komGroupId(List<int> key) => komHmac(key, utf8.encode('sensmos-grp-id-v1')).sublist(0, 4);

final _rng = Random.secure();
List<int> _rnd8() => List.generate(8, (_) => _rng.nextInt(256));

/// Nagłówek przeczytanej ramki (bez sprawdzania kluczy).
class KomFrame {
  final Uint8List b;
  final int mode, ctr;
  final bool hasPub;
  final String dst8, src8;
  KomFrame._(this.b, this.mode, this.ctr, this.hasPub, this.dst8, this.src8);

  static KomFrame? parse(List<int> raw) {
    if (raw.length < 19 || raw.length > 204 || raw[0] != 0xE0 || raw[1] != 0x04 || raw[2] & 0xCC != 0) return null;
    final b = _u8(raw);
    return KomFrame._(b, b[2] & 3, _rd32(b, 11), b[2] & 0x10 != 0, komHex(b.sublist(3, 7)), komHex(b.sublist(7, 11)));
  }

  String get key => '$src8:$ctr';
  Uint8List get src4 => b.sublist(7, 11);

  /// Prywatna do mnie: (pub nadawcy, tekst) albo null.
  Future<(Uint8List, String)?> openPriv(KomKeys me) async {
    if (mode != komModePriv || !hasPub || b.length < 15 + 32 + 8 + 1 + 12) return null;
    final sender = b.sublist(15, 47);
    if (komHex(komSha(sender).sublist(0, 4)) != src8) return null;
    final okm = await me.e2e(sender, me.pub, sender);
    final end = b.length - 4;
    if (komHex(komHmac(okm.sublist(32), b.sublist(0, end - 8)).sublist(0, 8)) != komHex(b.sublist(end - 8, end))) return null;
    try {
      return (sender, utf8.decode(_ctr(okm.sublist(0, 32), b.sublist(47, 55), src4, b.sublist(55, end - 8))));
    } catch (_) {
      return null;
    }
  }

  /// Potwierdzenie E2E od kontaktu `peerPub`: liczniki moich wiadomości albo null.
  Future<List<int>?> openAck(KomKeys me, List<int> peerPub) async {
    if (mode != komModeAck) return null;
    final okm = await me.e2e(peerPub, me.pub, peerPub);
    final end = b.length - 4, tagAt = end - 8;
    if ((tagAt - 15) % 4 != 0 || tagAt <= 15) return null;
    if (komHex(komHmac(okm.sublist(32), b.sublist(0, tagAt)).sublist(0, 8)) != komHex(b.sublist(tagAt, end))) return null;
    return [for (var o = 15; o < tagAt; o += 4) _rd32(b, o)];
  }

  String? openGroup(List<int> key) {
    if (mode != komModeGroup || b.length < 36 || komHex(komGroupId(key)) != dst8) return null;
    final okm = komHkdf(key, utf8.encode('sensmos-grp-msg-v1'), 64);
    final end = b.length - 4;
    if (komHex(komHmac(okm.sublist(32), b.sublist(0, end - 8)).sublist(0, 8)) != komHex(b.sublist(end - 8, end))) return null;
    try {
      return utf8.decode(_ctr(okm.sublist(0, 32), b.sublist(15, 23), src4, b.sublist(23, end - 8)));
    } catch (_) {
      return null;
    }
  }
}
