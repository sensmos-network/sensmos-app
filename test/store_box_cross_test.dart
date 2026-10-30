import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:sensmos_store/sensmos_store.dart';

/// Test krzyżowy: pakuje BE (Node), rozpakowuje apka (Dart).
///
/// Archiwum pomiarów wysyła serwer, a otwiera je telefon — czyli ten sam szyfr jest napisany
/// dwa razy, w dwóch językach. Rozjazd o jeden bajt nie objawia się przy zapisie, tylko przy
/// próbie odczytania pliku sprzed pół roku, gdy jest już za późno.
///
/// Próbkę wytwarza `backend/tools/box_fixture.js`. Po KAŻDEJ zmianie w `store_box.js` albo
/// `store_crypto.dart` wygeneruj ją na nowo i puść ten test.
void main() {
  final f = File('${Platform.environment['SENSMOS_WEKTORY'] ?? '../kontrakt/protokol/wektory'}/store-box.json');
  if (!f.existsSync()) {
    test('próbka z BE', () => fail('brak kontrakt/protokol/wektory/store-box.json — uruchom: node backend/tools/box_fixture.js'));
    return;
  }
  final fx = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  Uint8List hex(String h) => Uint8List.fromList(
      List.generate(h.length ~/ 2, (i) => int.parse(h.substring(2 * i, 2 * i + 2), radix: 16)));

  test('obie strony wyprowadzają TĘ SAMĄ skrzynkę z tego samego podpisu', () async {
    final box = await StoreCrypto.boxKeyPair(hex(fx['sig'] as String));
    final pub = await box.extractPublicKey();
    expect(StoreCrypto.pubHex(pub), fx['box_pub'],
        reason: 'rozjazd w HKDF albo w wyprowadzaniu klucza X25519 z nasienia');
  });

  test('klucz pliku zapakowany przez BE otwiera się kluczem z portfela', () async {
    final box = await StoreCrypto.boxKeyPair(hex(fx['sig'] as String));
    final dek = await StoreCrypto.unwrapDek(fx['wrapped_key'] as String, box);
    expect(dek.length, 32);
    // Nazwa idzie kluczem PLIKU — jeśli odczytamy ją poprawnie, klucz jest właściwy.
    expect(StoreCrypto.decryptName(dek, fx['name_enc'] as String), fx['name']);
  });

  test('szyfrogram z BE odszyfrowuje się co do bajtu', () async {
    final box = await StoreCrypto.boxKeyPair(hex(fx['sig'] as String));
    final dek = await StoreCrypto.unwrapDek(fx['wrapped_key'] as String, box);
    final dir = await Directory.systemTemp.createTemp('sensmos-cross-');
    try {
      final enc = File('${dir.path}/enc.bin')
        ..writeAsBytesSync(base64Decode(fx['cipher_b64'] as String));
      final plain = await StoreCrypto.decryptPath(enc.path, dek);
      expect(plain.length, fx['plain_len']);
      expect(sha256.convert(plain).toString(), fx['plain_sha256'],
          reason: 'rozjazd w ramkach: nonce z licznikiem albo aad');
      // Skróty bloków liczy BE i wysyła w `put` — muszą się zgadzać z tym, co policzyłby telefon.
      final (blocks, digest) = await StoreCrypto.blockHashes(enc);
      expect(blocks, (fx['blocks'] as List).cast<String>());
      expect(digest, fx['sha256']);
    } finally {
      try { dir.deleteSync(recursive: true); } catch (_) {}
    }
  });
}
