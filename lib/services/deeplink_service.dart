import 'package:flutter/services.dart';

/// Skróty z widgetu na pulpicie: `sensmos://open?kind=ha|term|app`.
///
/// Widget nie zna żadnych sekretów — otwiera tylko apkę pod adresem, a co dalej, decyduje
/// już apka (który node, czy jest sparowany, czy ma token ownera).
class DeepLinkService {
  static const _ch = MethodChannel('sensmos/deeplink');

  /// Adres, z którym apka wstała (albo null). Zwracany JEDEN raz.
  static Future<String?> initial() async {
    try {
      return await _ch.invokeMethod<String>('getInitial');
    } catch (_) {
      return null;   // iOS / brak kanału — skróty są androidowe
    }
  }

  /// Kolejne stuknięcia w widget, gdy apka już żyje.
  static void listen(void Function(String link) onLink) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) onLink(call.arguments as String);
      return null;
    });
  }

  /// `sensmos://open?kind=ha` → 'ha'. Zwraca null dla obcych adresów.
  static String? kindOf(String link) {
    final u = Uri.tryParse(link);
    if (u == null || u.scheme != 'sensmos') return null;
    return u.queryParameters['kind'] ?? 'app';
  }

  /// Zaproszenie z panelu instalatora: `sensmos://open?kind=installer&grant=0x…&name=…`.
  /// Zwraca (adres, nazwa) albo null, gdy adres nie jest poprawnym adresem portfela.
  static ({String address, String name})? installerInvite(String link) {
    final u = Uri.tryParse(link);
    if (u == null || u.scheme != 'sensmos' || u.queryParameters['kind'] != 'installer') return null;
    final a = (u.queryParameters['grant'] ?? '').trim().toLowerCase();
    if (!RegExp(r'^0x[0-9a-f]{40}$').hasMatch(a)) return null;
    final n = (u.queryParameters['name'] ?? '').replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return (address: a, name: n.length > 40 ? n.substring(0, 40) : n);
  }
}
