import 'package:flutter/material.dart';
import '../l10n.dart';
import '../theme.dart';
import '../screens/settings/tester_screen.dart';

/// Odczyt falownika (FW 1.13) jest w becie: wartości i znak baterii nie są jeszcze potwierdzone na prawdziwym
/// falowniku. Przycisk prowadzi do programu testów (scenariusz fw-113-deye).
class BetaInverterNote extends StatelessWidget {
  const BetaInverterNote({super.key});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(border: Border.all(color: AppTheme.amber), borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Beta: niezweryfikowane na prawdziwym falowniku. Zgłoś, czy wartości i kierunek baterii się zgadzają.'),
              style: const TextStyle(color: AppTheme.text, fontSize: 13, height: 1.35)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TesterScreen())),
              child: Text(tr('Zgłoś wynik'), style: const TextStyle(color: AppTheme.amber)),
            ),
          ),
        ]),
      );
}
