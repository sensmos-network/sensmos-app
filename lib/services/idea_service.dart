import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import '../l10n.dart';

/// Pomysły od użytkowników: jedno pytanie w apce → ten sam rejestr co formularz na
/// sensmos.com/roadmap (BE `POST /v1/roadmap/ideas`, bez zmian w backendzie).
/// Anonimowo: losowy token jak na stronie roadmapy, bez portfela i bez danych noda.
class IdeaService {
  static const _kToken = 'idea_token';
  static const _kFirstSeen = 'idea_first_seen';
  static const _kLastPrompt = 'idea_last_prompt';

  /// Pierwsze pytanie po 3 dniach używania, potem najwyżej raz na 30 dni.
  static const firstAfter = Duration(days: 3);
  static const every = Duration(days: 30);

  /// Pytania rotują co miesiąc; kod trafia na koniec opisu, żeby przegląd pomysłów
  /// wiedział, na co ktoś odpowiadał.
  static const questions = <(String, String)>[
    ('brakuje', 'Czego Ci brakuje w Sensmosie?'),
    ('irytuje', 'Co w Sensmosie najbardziej Cię irytuje?'),
    ('uzycie', 'Do czego używasz swojego noda albo do czego chciałbyś go używać?'),
  ];

  static (String, String) questionOfMonth([DateTime? now]) {
    final d = now ?? DateTime.now();
    return questions[(d.year * 12 + d.month) % questions.length];
  }

  static Future<String> _token(SharedPreferences p) async {
    var t = p.getString(_kToken);
    if (t != null && t.isNotEmpty) return t;
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    t = '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
    await p.setString(_kToken, t);
    return t;
  }

  /// Czy pokazać pytanie teraz. Pierwsze wywołanie tylko zapamiętuje datę startu.
  static Future<bool> shouldPrompt() async {
    try {
      final p = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final first = p.getInt(_kFirstSeen);
      if (first == null) {
        await p.setInt(_kFirstSeen, now);
        return false;
      }
      if (now - first < firstAfter.inMilliseconds) return false;
      final last = p.getInt(_kLastPrompt) ?? 0;
      return now - last >= every.inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  /// Zapamiętuje, że pytanie było pokazane (także gdy ktoś kliknął „Nie teraz").
  static Future<void> markPrompted() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kLastPrompt, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  /// Tytuł = początek odpowiedzi (serwer: 3–80 znaków), opis = cała odpowiedź + kod pytania
  /// (serwer: 10–600 znaków, bez linków).
  static (String, String) buildPayload(String answer, String code) {
    final a = answer.trim().replaceAll(RegExp(r'\s+'), ' ');
    var title = a;
    if (title.length > 80) {
      final cut = title.substring(0, 77);
      final sp = cut.lastIndexOf(' ');
      title = '${sp > 40 ? cut.substring(0, sp) : cut}...';
    }
    final tag = ' #app-$code';
    final body = a.length + tag.length > 600 ? a.substring(0, 600 - tag.length) : a;
    return (title, '$body$tag');
  }

  /// null = wysłane, inaczej komunikat dla użytkownika.
  static Future<String?> send(String answer, String code) async {
    final a = answer.trim();
    if (a.length < 10) return tr('Napisz choć jedno zdanie (min. 10 znaków).');
    if (RegExp(r'https?://|www\.', caseSensitive: false).hasMatch(a)) {
      return tr('Bez linków, proszę. Opisz pomysł słowami.');
    }
    try {
      final p = await SharedPreferences.getInstance();
      final (title, text) = buildPayload(a, code);
      final res = await http
          .post(Uri.parse('${Config.beUrl}/v1/roadmap/ideas'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'title': title,
                'text': text,
                'lang': L10n.lang == 'pl' ? 'pl' : 'en',
                'token': await _token(p),
              }))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode >= 200 && res.statusCode < 300) return null;
      if (res.statusCode == 429) return tr('Na dziś wystarczy, dziękujemy! Spróbuj jutro.');
      String? err;
      try {
        err = (jsonDecode(res.body) as Map<String, dynamic>)['error'] as String?;
      } catch (_) {}
      // BE zwraca kody (np. title_length), nie zdania — tłumaczymy znane, resztę pokazujemy jako kod.
      final e = err ?? '';
      if (e.contains('length')) return tr('Napisz choć jedno zdanie (min. 10 znaków).');
      if (e.contains('link') || e.contains('url')) return tr('Bez linków, proszę. Opisz pomysł słowami.');
      if (e.contains('limit') || e.contains('rate')) return tr('Na dziś wystarczy, dziękujemy! Spróbuj jutro.');
      return tr('Nie udało się wysłać (%s).', [e.isEmpty ? res.statusCode : e]);
    } catch (_) {
      return tr('Brak połączenia z serwerem. Spróbuj później.');
    }
  }
}
