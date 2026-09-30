import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../theme.dart';
import '../../l10n.dart';
import '../../core/core_bloc.dart';
import '../../core/core_event.dart';
import '../../services/wallet_service.dart';
import '../node/node_manager_screen.dart';
import 'package:sensmos_store/sensmos_store.dart';

/// Ekran powitalny (welcome). Nowy start (dodaj node) — albo, jeśli już
/// korzystałeś z SENSMOS: wyszukaj swoje nody w WiFi lub zaimportuj portfel.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  void _addNew(BuildContext context) {
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => const NodeManagerScreen(addOnly: true)));
  }

  void _findExisting(BuildContext context) {
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => const NodeManagerScreen(existingOnly: true)));
  }

  /// Konto bez sprzętu: sam portfel wystarcza do komunikatora, a miejsce w Store kupuje się na
  /// ADRES, nie na node (bramka zdjęta 2026-09-09).
  /// UWAGA: portfel zakładany razem z nodem dostaje zaszyfrowaną kopię NA TYM NODZIE. Tutaj
  /// takiej kopii nie ma i nie będzie — jedyną drogą odzysku jest eksport klucza z ekranu
  /// portfela, więc od razu tam kierujemy.
  Future<void> _walletOnly(BuildContext context) async {
    final ws = context.read<WalletService>();
    final messenger = ScaffoldMessenger.of(context);
    final bloc = context.read<CoreBloc>();
    try {
      final w = await ws.create();
      messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(tr('Portfel gotowy: %s. Zapisz klucz (Portfel → Klucz prywatny) — bez '
                           'noda to jedyna kopia.',
              ['${w.address.substring(0, 6)}…${w.address.substring(w.address.length - 4)}']))));
      bloc.add(WalletImported());
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e'), backgroundColor: const Color(0xFFFF4444)));
    }
  }

  Future<void> _importWallet(BuildContext context) async {
    final ctrl = TextEditingController();
    final pk = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('Importuj portfel'),
            style: const TextStyle(color: AppTheme.text)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Wklej klucz prywatny (np. z MetaMask). Rób to tylko na swoim telefonie.'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          const SizedBox(height: 10),
          TextField(controller: ctrl, autofocus: true, maxLines: 2,
            style: const TextStyle(color: AppTheme.text, fontSize: 13, fontFamily: 'monospace'),
            decoration: const InputDecoration(hintText: '0x…',
                hintStyle: TextStyle(color: AppTheme.muted))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anuluj'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.teal),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('Importuj'), style: const TextStyle(color: Colors.black))),
        ],
      ),
    );
    if (pk == null || pk.isEmpty) return;
    // Wszystko wyłuskane PRZED await; WalletImported (przełącza ekran → dispose) na końcu.
    final ws = context.read<WalletService>();
    final messenger = ScaffoldMessenger.of(context);
    final bloc = context.read<CoreBloc>();
    try {
      final w = await ws.restore(pk);
      messenger.showSnackBar(SnackBar(content: Text(
          tr('Portfel zaimportowany: %s',
             ['${w.address.substring(0,6)}…${w.address.substring(w.address.length-4)}']))));
      bloc.add(WalletImported());
    } catch (_) {
      messenger.showSnackBar(SnackBar(
          content: Text(tr('Nieprawidłowy klucz prywatny')),
          backgroundColor: const Color(0xFFFF4444)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              // Znak i wordmark 1:1 z nagłówka strony — apka i sensmos.com muszą wyglądać jak
              // jedno. Wcześniej był tu sam napis wielkimi literami, czego marka nie przewiduje.
              const SensmosLogo(size: 46, fontSize: 34, textColor: AppTheme.text),
              const SizedBox(height: 14),
              Text(tr('Twoje urządzenia. Twoje dane. Twoja sieć.'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 15)),
              const SizedBox(height: 40),
              // Cztery obietnice wzięte z sekcji „co daje Sensmos" na stronie, żeby człowiek,
              // który tam był, zobaczył tu to samo.
              _bullet(Icons.lock_outline, tr('Twoja domowa sieć z dowolnego miejsca — bez VPN-u')),
              _bullet(Icons.hub_outlined, tr('Home Assistant bez abonamentu')),
              _bullet(Icons.wifi_tethering, tr('LoRa działa, gdy internet nie działa')),
              _bullet(Icons.folder_outlined, tr('Zaszyfrowane miejsce na pliki u innych')),
              const SizedBox(height: 32),

              // ── Nowy start ──
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _addNew(context),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.teal,
                    foregroundColor: AppTheme.bg,
                  ),
                  icon: const Icon(Icons.add),
                  label: Text(tr('Dodaj node')),
                ),
              ),
              const SizedBox(height: 10),
              // Druga droga nowego startu, nie „powrót": albo przychodzisz ze sprzętem,
              // albo korzystasz bez noda (sam portfel).
              _secondary(
                icon: Icons.account_balance_wallet_outlined,
                label: tr('Chcę korzystać bez noda (tylko portfel)'),
                onTap: () => _walletOnly(context),
              ),

              const SizedBox(height: 28),
              Row(children: [
                const Expanded(child: Divider(color: AppTheme.border)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(tr('Korzystałeś już z SENSMOS?'),
                      style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                ),
                const Expanded(child: Divider(color: AppTheme.border)),
              ]),
              const SizedBox(height: 16),

              // ── Powracający ──
              _secondary(
                icon: Icons.wifi_find,
                label: tr('Wyszukaj moje nody w sieci WiFi'),
                onTap: () => _findExisting(context),
              ),
              const SizedBox(height: 12),
              _secondary(
                icon: Icons.download_outlined,
                label: tr('Importuj portfel'),
                onTap: () => _importWallet(context),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  /// Przyciski drugorzędne w kolorze marki: szara ramka na ciemnym tle nie czytała się jako
  /// przycisk — ludzie nie wiedzieli, że to się naciska. Zielona ramka i zielony tekst mówią
  /// „naciśnij", a wypełnienie zostaje zarezerwowane dla akcji głównej, żeby nie konkurowały.
  Widget _secondary(
          {required IconData icon, required String label, required VoidCallback onTap}) =>
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.teal,
            side: const BorderSide(color: AppTheme.teal),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          icon: Icon(icon, size: 20, color: AppTheme.teal),
          label: Text(label, textAlign: TextAlign.center),
        ),
      );

  Widget _bullet(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(children: [
          Icon(icon, color: AppTheme.purple, size: 22),
          const SizedBox(width: 14),
          Expanded(
              child: Text(text,
                  style: const TextStyle(color: AppTheme.text, fontSize: 14))),
        ]),
      );
}
