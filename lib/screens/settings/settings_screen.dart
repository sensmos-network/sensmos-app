import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../services/node_service.dart';
import '../../services/store_card_pref.dart';
import '../../config.dart';
import '../../theme.dart';
import '../../l10n.dart';
import 'devices_screen.dart';
import 'nodes_location_screen.dart';
import 'logs_screen.dart';
import 'update_check.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Ustawienia'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Nody — TYLKO gdy jakieś są. Konto założone drogą „tylko portfel" nie ma czego tu
          // ustawiać, a ekran współrzędnych i tak pokazałby pustą listę.
          if (context.read<NodeService>().nodes.isNotEmpty) ...[
            _section(tr('Nody')),
            Card(child: Column(children: [
              _tile(
                context,
                icon: Icons.location_on_outlined,
                title: tr('Lokalizacja nodów'),
                sub: tr('współrzędne wszystkich urządzeń'),
                builder: (_) => const NodesLocationScreen(),
              ),
            ])),
            const SizedBox(height: 16),
          ],

          // Aplikacja
          _section(tr('Aplikacja')),
          Card(child: Column(children: [
            ListTile(
              leading: const Icon(Icons.language, color: AppTheme.teal),
              title: Text(tr('Język'), style: const TextStyle(color: AppTheme.text)),
              subtitle: Text(tr('wymuś język aplikacji'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
              trailing: Text(_langLabel(),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
              onTap: () => _pickLang(context),
            ),
            const Divider(color: AppTheme.border, height: 1),
            // Token jest kontowy, nie sklepowy — dlatego mieszka tu, a nie w Storage. Tym samym
            // ekranem damy kiedys komputerowi podglad nodow.
            _tile(
              context,
              icon: Icons.devices_other,
              title: tr('Sparowane urządzenia'),
              sub: tr('komputery i Home Assistant z dostępem do konta'),
              builder: (_) => const DevicesScreen(),
            ),
            const Divider(color: AppTheme.border, height: 1),
            const _StoreCardSwitch(),
            const Divider(color: AppTheme.border, height: 1),
            _tile(
              context,
              icon: Icons.article_outlined,
              title: tr('Logi'),
              sub: tr('błędy i zdarzenia aplikacji'),
              builder: (_) => const LogsScreen(),
            ),
            const Divider(color: AppTheme.border, height: 1),
            ListTile(
              leading: const Icon(Icons.system_update_alt, color: AppTheme.teal),
              title: Text(tr('Sprawdź aktualizację'),
                  style: const TextStyle(color: AppTheme.text)),
              subtitle: Text(tr('nowa wersja i lista zmian'),
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
              onTap: () => checkForUpdate(context),
            ),
            const Divider(color: AppTheme.border, height: 1),
            ListTile(
              leading: const Icon(Icons.info_outline, color: AppTheme.muted),
              title: Text(tr('Wersja'), style: const TextStyle(color: AppTheme.text)),
              trailing: Text(Config.appVersion,
                  style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
            ),
            const Divider(color: AppTheme.border, height: 1),
            const ListTile(
              leading: Icon(Icons.code, color: AppTheme.muted),
              title: Text('Sensmos Network',
                  style: TextStyle(color: AppTheme.text)),
              subtitle: Text('sensmos.com',
                  style: TextStyle(color: AppTheme.muted, fontSize: 12)),
            ),
          ])),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String sub,
    required WidgetBuilder builder,
  }) =>
      ListTile(
        leading: Icon(icon, color: AppTheme.teal),
        title: Text(title, style: const TextStyle(color: AppTheme.text)),
        subtitle: Text(sub,
            style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
        trailing: const Icon(Icons.chevron_right, color: AppTheme.muted),
        onTap: () =>
            Navigator.push(context, MaterialPageRoute(builder: builder)),
      );

  String _langLabel() => switch (L10n.mode) {
        'pl' => 'Polski',
        'en' => 'English',
        'de' => 'Deutsch',
        'pt' => 'Português (BR)',
        _    => tr('Systemowy'),
      };

  void _pickLang(BuildContext context) => showDialog(
        context: context,
        builder: (ctx) => SimpleDialog(
          backgroundColor: AppTheme.card,
          title: Text(tr('Język'), style: const TextStyle(color: AppTheme.text)),
          children: [
            _langOption(ctx, 'system', tr('Systemowy')),
            _langOption(ctx, 'pl', 'Polski'),
            _langOption(ctx, 'en', 'English'),
            _langOption(ctx, 'de', 'Deutsch'),
            _langOption(ctx, 'pt', 'Português (BR)'),
          ],
        ),
      );

  Widget _langOption(BuildContext ctx, String mode, String label) {
    final sel = L10n.mode == mode;
    return SimpleDialogOption(
      onPressed: () { L10n.setMode(mode); Navigator.pop(ctx); },
      child: Row(children: [
        Icon(sel ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            size: 20, color: sel ? AppTheme.teal : AppTheme.muted),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: AppTheme.text)),
      ]),
    );
  }

  Widget _section(String label) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(label.toUpperCase(),
            style: const TextStyle(
                color: AppTheme.muted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1)),
      );
}

/// Karta Storage pod listą nodów: X na karcie ją chowa, tu się ją przywraca. Jeden pref,
/// jeden przełącznik — bez osobnych stanów „skonfigurowane / nie".
class _StoreCardSwitch extends StatelessWidget {
  const _StoreCardSwitch();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: StoreCardPref.hidden,
        builder: (_, hidden, __) => SwitchListTile(
          secondary: const Icon(Icons.sd_storage_outlined, color: AppTheme.teal),
          title: Text(tr('Storage na ekranie nodów'), style: const TextStyle(color: AppTheme.text)),
          subtitle: Text(tr('karta pakietu pod listą nodów'),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
          activeThumbColor: AppTheme.teal,
          value: !hidden,
          onChanged: (v) => StoreCardPref.set(!v),
        ),
      );
}
