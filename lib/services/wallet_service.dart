import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';
import 'package:web3dart/web3dart.dart';
import '../config.dart';
import '../l10n.dart';
import '../models/wallet.dart';

/// WalletService — generowanie, przechowywanie, podpis (opcja C).
/// Klucz w secure storage telefonu (Keychain/Keystore).
/// Backup do ESP NVS robi NodeService osobno.
class WalletService {
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // Ochrona hasłem (opt-in). Gdy włączona: w storage leży tylko `wallet_enc`
  // (blob AES-GCM(PBKDF2(hasło))), a `sensmos_wallet_privkey` NIE istnieje —
  // klucz w spoczynku jest nieodczytywalny bez hasła, którego apka nie zna.
  // Po odblokowaniu klucz żyje TYLKO w RAM (`_sessionKey`) na czas sesji.
  static const _kPwProt = 'sensmos_wallet_pwprot';   // '1' = portfel pod hasłem
  static const _kWalletEnc = 'sensmos_wallet_enc';    // blob zaszyfrowany hasłem
  String? _sessionKey;                                // odszyfrowany privkey (RAM, sesja)

  Future<bool> isPasswordProtected() async =>
      await _storage.read(key: _kPwProt) == '1';

  /// Czy da się teraz podpisać: portfel bez hasła ZAWSZE, z hasłem tylko po unlock.
  Future<bool> isUnlocked() async =>
      !(await isPasswordProtected()) || _sessionKey != null;

  /// Czy wallet już istnieje (jawny albo zaszyfrowany hasłem)
  Future<bool> exists() async =>
      await _storage.read(key: Config.kWalletKey) != null ||
      await _storage.read(key: _kWalletEnc) != null;

  // Surowy klucz do użycia TERAZ: z RAM (gdy pod hasłem) albo z storage (gdy jawny).
  // Zwraca null, gdy portfel jest pod hasłem i zablokowany.
  Future<String?> _rawKey() async {
    if (await isPasswordProtected()) return _sessionKey;
    return _storage.read(key: Config.kWalletKey);
  }

  /// Wczytaj istniejący wallet. Gdy pod hasłem i zablokowany — privateKeyHex = '' (UI sprawdza isUnlocked).
  Future<AppWallet?> load() async {
    final addr = await _storage.read(key: Config.kWalletAddr);
    if (addr == null) return null;
    final pk = await _rawKey();
    return AppWallet(address: addr, privateKeyHex: pk ?? '');
  }

  /// Stwórz nowy wallet (przy pierwszym uruchomieniu — niewidoczne dla usera)
  Future<AppWallet> create() async {
    final rng = Random.secure();
    final priv = EthPrivateKey.createRandom(rng);
    final addr = priv.address.eip55With0x;
    // Kanoniczne 64 hex z liczby klucza. web3dart (encodeBigInt, ze znakiem) zapisuje
    // klucz jako 33 bajty (wiodący 00 gdy najwyższy bit = 1, ~50% przypadków) lub <32
    // (wiodące zero); przez privateKeyInt dostajemy zawsze dokładnie 32 bajty — inaczej
    // MetaMask odrzuca import ("couldn't import that private key").
    final pkHex = priv.privateKeyInt.toRadixString(16).padLeft(64, '0');

    await _storage.write(key: Config.kWalletKey, value: pkHex);
    await _storage.write(key: Config.kWalletAddr, value: addr);

    return AppWallet(address: addr, privateKeyHex: pkHex);
  }

  /// Podpisz wiadomość kluczem walleta (personal_sign)
  Future<String> signMessage(String message) async {
    final pk = await _rawKey();
    if (pk == null || pk.isEmpty) {
      // Portfel pod hasłem i zablokowany — najpierw unlock (UI: PIN/hasło gate).
      throw Exception(await isPasswordProtected()
          ? tr('Portfel zablokowany — odblokuj hasłem, aby wykonać operację.')
          : tr('Brak portfela'));
    }
    final priv = EthPrivateKey.fromHex(pk);
    final sig = priv.signPersonalMessageToUint8List(
      Uint8List.fromList(message.codeUnits),
    );
    return bytesToHex(sig, include0x: true);
  }

  // ── Ochrona hasłem: włącz / wyłącz / odblokuj ─────────────────
  /// Włącz hasło: zaszyfruj bieżący klucz, usuń jawny z storage. Portfel zostaje odblokowany.
  Future<void> enablePassword(String password) async {
    final pk = await _rawKey();
    if (pk == null || pk.isEmpty) throw Exception('Brak klucza do zaszyfrowania');
    final salt = _randomBytes(16), iv = _randomBytes(12);
    final key = _deriveKey(password, salt);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final ct = gcm.process(Uint8List.fromList(utf8.encode(pk)));
    await _storage.write(key: _kWalletEnc, value: base64.encode(Uint8List.fromList([...salt, ...iv, ...ct])));
    await _storage.delete(key: Config.kWalletKey);   // jawny klucz znika ze spoczynku
    await _storage.write(key: _kPwProt, value: '1');
    _sessionKey = pk;                                 // sesja pozostaje odblokowana
  }

  /// Wyłącz hasło: odszyfruj i zapisz z powrotem jawny klucz (do Keystore).
  Future<void> disablePassword(String password) async {
    final pk = await _decryptWithPassword(password);  // rzuca przy złym haśle
    await _storage.write(key: Config.kWalletKey, value: pk);
    await _storage.delete(key: _kWalletEnc);
    await _storage.delete(key: _kPwProt);
    _sessionKey = pk;
  }

  /// Odblokuj sesję hasłem (klucz ląduje w RAM na czas sesji). Rzuca przy złym haśle.
  Future<void> unlock(String password) async {
    _sessionKey = await _decryptWithPassword(password);
  }

  /// Zablokuj — usuń klucz z RAM (np. przy zejściu apki w tło).
  void lock() { _sessionKey = null; }

  // Odszyfruj blob hasłem + zweryfikuj, że klucz pasuje do zapisanego adresu.
  Future<String> _decryptWithPassword(String password) async {
    final blob = await _storage.read(key: _kWalletEnc);
    if (blob == null) throw Exception('Brak zaszyfrowanego portfela');
    final raw = base64.decode(blob);
    final salt = Uint8List.fromList(raw.sublist(0, 16));
    final iv = Uint8List.fromList(raw.sublist(16, 28));
    final ct = Uint8List.fromList(raw.sublist(28));
    final key = _deriveKey(password, salt);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final String pk;
    try {
      pk = utf8.decode(gcm.process(ct));   // GCM tag = weryfikacja: zły PIN/hasło → wyjątek
    } catch (_) {
      throw Exception(tr('Błędne hasło'));
    }
    // Druga warstwa: adres z klucza musi zgadzać się z zapisanym (jawnym) adresem.
    final addr = await _storage.read(key: Config.kWalletAddr);
    if (addr != null && (await addressOf(pk)).toLowerCase() != addr.toLowerCase()) {
      throw Exception(tr('Błędne hasło'));
    }
    return pk;
  }

  /// DEBUG (test): pełny cykl szyfrowanie→odszyfrowanie→match adresu, bez ruszania storage.
  /// Sprawdza też, że BŁĘDNE hasło jest odrzucane. Zwraca czytelny raport.
  Future<String> debugSelfTest(String password) async {
    final pk = await _rawKey();
    if (pk == null || pk.isEmpty) return 'BŁĄD: brak odblokowanego klucza do testu';
    try {
      final salt = _randomBytes(16), iv = _randomBytes(12);
      final key = _deriveKey(password, salt);
      final enc = GCMBlockCipher(AESEngine())
        ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
      final ct = enc.process(Uint8List.fromList(utf8.encode(pk)));
      // odszyfruj dobrym hasłem
      final dec = GCMBlockCipher(AESEngine())
        ..init(false, AEADParameters(KeyParameter(_deriveKey(password, salt)), 128, iv, Uint8List(0)));
      final back = utf8.decode(dec.process(ct));
      final okKey = back == pk;
      final okAddr = (await addressOf(back)) == (await addressOf(pk));
      // odszyfruj ZŁYM hasłem — musi rzucić
      bool wrongRejected = false;
      try {
        final bad = GCMBlockCipher(AESEngine())
          ..init(false, AEADParameters(KeyParameter(_deriveKey('$password#zle', salt)), 128, iv, Uint8List(0)));
        bad.process(ct);
      } catch (_) { wrongRejected = true; }
      return 'Test hasła:\n'
          '• odszyfrowanie dobrym hasłem: ${okKey ? "OK" : "BŁĄD"}\n'
          '• adres po odszyfrowaniu zgodny: ${okAddr ? "OK" : "BŁĄD"}\n'
          '• błędne hasło odrzucone: ${wrongRejected ? "OK" : "BŁĄD"}\n'
          '${okKey && okAddr && wrongRejected ? "✓ Szyfrowanie działa poprawnie" : "✗ Coś nie gra — NIE włączaj hasła"}';
    } catch (e) {
      return 'BŁĄD testu: $e';
    }
  }

  /// Zapisz wallet z surowego klucza (po recovery z noda)
  // Adres z klucza BEZ zapisu do storage — podglad przed nadpisaniem walleta.
  Future<String> addressOf(String privateKeyHex) async {
    final clean = privateKeyHex.trim();
    var pk = clean.startsWith('0x') ? clean.substring(2) : clean;
    pk = pk.length > 64 ? pk.substring(pk.length - 64) : pk.padLeft(64, '0');
    return EthPrivateKey.fromHex(pk).address.eip55With0x;
  }

  Future<AppWallet> restore(String privateKeyHex) async {
    final clean = privateKeyHex.trim();
    var pk = clean.startsWith('0x') ? clean.substring(2) : clean;
    // Normalizuj do 64 hex: obetnij wiodący bajt znaku (00) albo dopełnij zerami.
    pk = pk.length > 64 ? pk.substring(pk.length - 64) : pk.padLeft(64, '0');
    final priv = EthPrivateKey.fromHex(pk);
    final addr = priv.address.eip55With0x;
    await _storage.write(key: Config.kWalletKey, value: pk);
    await _storage.write(key: Config.kWalletAddr, value: addr);
    // Recovery przez BLE RESETUJE hasło: node oddał surowy klucz (zaszyfrowany PIN-em,
    // nie hasłem), więc po odzysku portfel jest jawny — user ustawia nowe hasło od nowa.
    await _storage.delete(key: _kWalletEnc);
    await _storage.delete(key: _kPwProt);
    _sessionKey = null;
    return AppWallet(address: addr, privateKeyHex: pk);
  }

  /// Zaszyfruj klucz prywatny PIN-em noda → blob do kopii na ESP NVS.
  /// blob = base64(salt[16] || iv[12] || ciphertext+tag). AES-GCM, klucz=PBKDF2.
  Future<String?> exportEncrypted(String pin) async {
    final pk = await _storage.read(key: Config.kWalletKey);
    if (pk == null) return null;
    final salt = _randomBytes(16);
    final iv = _randomBytes(12);
    final key = _deriveKey(pin, salt);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final ct = gcm.process(Uint8List.fromList(utf8.encode(pk)));
    return base64.encode(Uint8List.fromList([...salt, ...iv, ...ct]));
  }

  /// Odszyfruj blob z noda PIN-em i zapisz wallet. Rzuca przy złym PIN-ie.
  Future<AppWallet> importEncrypted(String blob, String pin) async {
    final raw = base64.decode(blob);
    if (raw.length < 28 + 16) throw Exception('Uszkodzona kopia');
    final salt = Uint8List.fromList(raw.sublist(0, 16));
    final iv = Uint8List.fromList(raw.sublist(16, 28));
    final ct = Uint8List.fromList(raw.sublist(28));
    final key = _deriveKey(pin, salt);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final Uint8List pt;
    try {
      pt = gcm.process(ct); // InvalidCipherText przy złym PIN-ie/tagu
    } catch (_) {
      throw Exception(tr('Błędny PIN lub uszkodzona kopia'));
    }
    return restore(utf8.decode(pt));
  }

  Uint8List _deriveKey(String pin, Uint8List salt) {
    final d = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, 100000, 32));
    return d.process(Uint8List.fromList(utf8.encode(pin)));
  }

  Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  /// Usuń wallet (reset)
  Future<void> wipe() async {
    await _storage.delete(key: Config.kWalletKey);
    await _storage.delete(key: Config.kWalletAddr);
    await _storage.delete(key: _kWalletEnc);
    await _storage.delete(key: _kPwProt);
    _sessionKey = null;
  }
}
