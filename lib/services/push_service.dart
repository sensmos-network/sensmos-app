import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import 'owner_token_service.dart';
import 'wallet_service.dart';

/// PushService — token FCM rejestrowany w BE (przebudowa 2026-08-24).
/// Jedno źródło prawdy: BE trzyma tokeny per wallet (podpis właściciela), wysyła
/// wszystkie powiadomienia — zarówno te z akcji nodów, jak i alerty o padzie noda
/// (LoRa awaryjne), których martwy node z definicji sam nie wyśle.
/// Stara ścieżka (token na nodzie przez POST /config) wycofana z apki; stare FW
/// dokleja token z NVS jako fallback i BE go użyje, dopóki wallet nie ma rejestracji.
class PushService {
  /// Globalny messenger apki — pushe FCM w foregroundzie Android NIE pokazuje sam
  /// (oddaje je do onMessage), więc rysujemy własny baner. main.dart wpina ten klucz
  /// w MaterialApp.scaffoldMessengerKey.
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();

  String? _token;
  bool _inited = false;
  WalletService? _wallet;   // do re-rejestracji przy rotacji tokenu
  DateTime? _registeredAt;

  String? get token => _token;
  bool get registered => _registeredAt != null;

  /// Inicjalizacja po Firebase.initializeApp(). Zwraca token (lub null).
  Future<String?> init() async {
    if (_inited) return _token;
    _inited = true;
    final fm = FirebaseMessaging.instance;
    try {
      await fm.requestPermission(alert: true, badge: true, sound: true);
      _token = await fm.getToken();
      fm.onTokenRefresh.listen((t) {
        _token = t;
        final w = _wallet;
        if (w != null) registerToBackend(w);   // rotacja tokenu → cicha re-rejestracja
      });
      // Foreground: system nie pokaże banera — rysujemy własny (emergency na bursztynowo).
      FirebaseMessaging.onMessage.listen((msg) => _show(msg, tapped: false));
      // Tapnięcie w powiadomienie (apka w tle albo zamknięta): pokaż pełną treść, bo system
      // ucina ją do dwóch linii, a przy „nod ucichł" to właśnie w ogonie są kroki naprawy.
      FirebaseMessaging.onMessageOpenedApp.listen((msg) => _show(msg, tapped: true));
      FirebaseMessaging.instance.getInitialMessage().then((msg) { if (msg != null) _show(msg, tapped: true); });
    } catch (_) {
      _token = null;
    }
    return _token;
  }

  void _show(RemoteMessage msg, {required bool tapped}) {
    final n = msg.notification;
    if (n == null) return;
    final emerg = msg.data['type'] == 'lora_emerg';
    final body = n.body ?? '';
    messengerKey.currentState?.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: tapped ? 12 : (emerg ? 8 : 5)),
      backgroundColor: emerg ? Colors.amber.shade800 : null,
      content: Text('${n.title ?? ''}${body.isNotEmpty ? '\n$body' : ''}',
          maxLines: tapped ? 8 : 4, overflow: TextOverflow.ellipsis),
    ));
  }

  /// Czemu ostatnia rejestracja padła: 'no_fcm' | 'locked' | 'net' (null = poszło).
  String? get reason => _reason;
  String? _reason;

  /// Rejestracja tokenu FCM w BE. Najpierw tokenem ownera (portfel może być zamknięty),
  /// dopiero potem podpisem — bo podpis wymaga OTWARTEGO portfela, a apka woła to przy
  /// starcie. Wcześniej user z hasłem nie rejestrował się nigdy: wyjątek z signMessage
  /// lądował w pustym catch i pushy po prostu nie było.
  Future<bool> registerToBackend(WalletService wallet) async {
    _wallet = wallet;
    final tok = _token;
    if (tok == null || tok.isEmpty) { _reason = 'no_fcm'; return false; }

    final owner = (await wallet.load())?.address;
    final ownerToken = owner == null ? null : await OwnerTokenService().cached(owner);
    if (ownerToken != null) {
      if (await _post({'token': tok, 'owner_token': ownerToken})) return true;
      if (_reason != 'auth') return false;           // sieć padła — token trzymamy
      await OwnerTokenService().forget(owner!);      // odwołany/wygasł — nie trzymamy trupa
    }

    if (!await wallet.isUnlocked()) { _reason = 'locked'; return false; }
    try {
      final ts = (DateTime.now().millisecondsSinceEpoch / 1000).round();
      final sig = await wallet.signMessage('sensmos:push:$tok:$ts');
      return _post({'token': tok, 'ts': ts, 'sig': sig});
    } catch (_) {
      _reason = 'locked';
      return false;
    }
  }

  Future<bool> _post(Map<String, dynamic> body) async {
    try {
      final res = await http
          .post(Uri.parse('${Config.beUrl}/v1/nodes/push-token'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({...body, 'app_version': Config.appVersion}))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        _registeredAt = DateTime.now();
        _reason = null;
        return true;
      }
      _reason = res.statusCode == 401 ? 'auth' : 'net';
    } catch (_) {
      _reason = 'net';
    }
    return false;
  }
}
