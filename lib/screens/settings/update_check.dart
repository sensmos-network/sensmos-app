import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../../config.dart';
import '../../l10n.dart';
import '../../theme.dart';

/// Build do Google Play (`--dart-define=STORE=play`): Play zabrania aktualizacji spoza Play,
/// więc tam nie ma „Sprawdź aktualizację" — wersję zmienia sklep. Build z GitHuba bez zmian.
const bool kPlayStore = String.fromEnvironment('STORE') == 'play';

/// Self-update APK: manifest z BE (wersja + changelog PL/EN + URL APK z GitHub Releases).
/// Dialog pokazuje skumulowane notki wszystkich wersji nowszych niż zainstalowana;
/// „Pobierz" otwiera bezpośredni link do APK — Android po pobraniu proponuje instalację.
Future<void> checkForUpdate(BuildContext context) async {
  try {
    final res = await http
        .get(Uri.parse(Config.updateManifestUrl))
        .timeout(const Duration(seconds: 8));
    final m = jsonDecode(res.body) as Map<String, dynamic>;
    final latest = (m['version'] ?? '') as String;
    final url = (m['url'] ?? '') as String;
    if (!context.mounted) return;

    if (_cmpVer(latest, Config.appVersion) <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Masz najnowszą wersję (%s)', [Config.appVersion]))));
      return;
    }

    // notki wszystkich wersji nowszych niż zainstalowana, od najnowszej
    final notes = (m['notes'] as Map<String, dynamic>? ?? {});
    final newer = notes.keys
        .where((v) => _cmpVer(v, Config.appVersion) > 0)
        .toList()
      ..sort((a, b) => _cmpVer(b, a));
    final lang = L10n.lang;   // notki w języku apki; brak tej wersji językowej w manifeście → fallback EN

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('Dostępna aktualizacja %s', [latest]),
            style: const TextStyle(color: AppTheme.text, fontSize: 17)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final v in newer) ...[
                Text(v,
                    style: const TextStyle(
                        color: AppTheme.teal,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                for (final line in (((notes[v] as Map<String, dynamic>?)?[lang] ??
                        (notes[v] as Map<String, dynamic>?)?['en'])
                        as List<dynamic>? ??
                    []))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('•  ',
                          style: TextStyle(color: AppTheme.muted, fontSize: 13)),
                      Expanded(
                          child: Text('$line',
                              style: const TextStyle(
                                  color: AppTheme.text, fontSize: 13, height: 1.35))),
                    ]),
                  ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Później'),
                style: const TextStyle(color: AppTheme.muted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.teal),
            onPressed: () {
              Navigator.pop(ctx);
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
            },
            child: Text(tr('Pobierz'),
                style: const TextStyle(color: Color(0xFF06231F))),
          ),
        ],
      ),
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('Nie udało się sprawdzić aktualizacji'))));
  }
}

/// porównanie wersji po członach: "1.4.10" > "1.4.5" (parseFloat by tu kłamał)
int _cmpVer(String a, String b) {
  final pa = a.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  final pb = b.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  for (var i = 0; i < 3; i++) {
    final d = (i < pa.length ? pa[i] : 0) - (i < pb.length ? pb[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}
