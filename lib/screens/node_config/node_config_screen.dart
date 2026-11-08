import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/node_service.dart';
import '../../core/core_bloc.dart';
import '../../core/core_event.dart';
import '../scripts/scripts_screen.dart';
import '../message_actions/message_actions_screen.dart';
import '../messages/messages_screen.dart';
import '../../services/pairing_service.dart';
import '../../util/pair_gate.dart';
import 'trust_screen.dart';
import 'service_screen.dart';
import 'mqtt_screen.dart';
import 'change_pin_screen.dart';
import 'lora_screen.dart';
import 'hub_sensors_screen.dart';
import 'modbus_screen.dart';
import 'installer_share_screen.dart';

class NodeConfigScreen extends StatefulWidget {
  final SavedNode node;
  const NodeConfigScreen({super.key, required this.node});

  @override
  State<NodeConfigScreen> createState() => _NodeConfigScreenState();
}

class _NodeConfigScreenState extends State<NodeConfigScreen> {
  String? _city;
  String? _fw;
  String? _pinOverride;
  bool _paired = false;
  // Kafel LoRa tylko dla noda z radiem: od FW lora9 /info niesie pole `lora`
  // (obecne wyłącznie, gdy sonda pinów znalazła SX1262). Brak pola/odpowiedzi = bez kafla.
  bool _hasLora = false;

  SavedNode get node => widget.node;
  String get pin => _pinOverride ?? widget.node.pin;
  String get _short =>
      node.id.length > 8 ? '${node.id.substring(0, 8)}...' : node.id;

  @override
  void initState() {
    super.initState();
    _loadInfo();
    _loadPairing();
  }

  Future<void> _loadPairing() async {
    final has = await PairingService().hasAccess(node.id);
    if (!mounted) return;
    setState(() => _paired = has);
  }

  /// Jedyne miejsce zarządzania zdalnym dostępem. Terminal i panel HA tylko UŻYWAJĄ klucza —
  /// gdyby każda integracja miała własny krok parowania, przy trzeciej powielalibyśmy to samo
  /// po raz trzeci, a user i tak nie wiedziałby, gdzie tego szukać.
  Future<void> _togglePairing() async {
    if (!_paired) {
      final acc = await ensurePaired(context, node.id);
      if (!mounted) return;
      setState(() => _paired = acc.ok);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('Wyłączyć zdalny dostęp?'), style: const TextStyle(color: AppTheme.text)),
        content: Text(
          tr('Node skasuje wszystkie klucze — terminal i panel HA przestaną działać ze WSZYSTKICH '
             'telefonów, także innych domowników. Ponowne włączenie wymaga bycia w sieci noda.'),
          style: const TextStyle(color: AppTheme.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anuluj'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF6666)),
            onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Wyłącz'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final err = await PairingService().unpair(node.id, node.ip, pin);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    setState(() => _paired = false);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Zdalny dostęp wyłączony.'))));
  }

  Future<void> _loadInfo() async {
    try {
      final res = await http
          .get(Uri.parse('http://${node.ip}/info'))
          .timeout(const Duration(seconds: 4));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _city = j['city'] as String?;
        _fw = (j['version'] ?? j['firmware']) as String?;
        _hasLora = j['lora'] is Map;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Ustawienia noda'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.sensors, color: AppTheme.teal),
              title: Text(_city ?? node.label,
                  style: const TextStyle(color: AppTheme.text)),
              subtitle: Text('$_short · FW ${_fw ?? "?"}',
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
            ),
          ),
          const SizedBox(height: 12),
          _tile(
            icon: Icons.inbox_outlined,
            title: tr('Odebrane'),
            sub: tr('odebrane wiadomości na nodzie'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => MessagesScreen(ip: node.ip, pin: pin)),
            ),
          ),
          _tile(
            icon: Icons.alt_route,
            title: tr('Akcje'),
            sub: tr('akcje na odebrane wiadomości (webhook, encje)'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => MessageActionsScreen(ip: node.ip, pin: pin)),
            ),
          ),
          _tile(
            icon: Icons.code,
            title: tr('Skrypty'),
            sub: tr('automatyzacje noda'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => ScriptsScreen(ip: node.ip, pin: pin)),
            ),
          ),
          if (_fwAtLeast(1, 13))   // Modbus RS485 od FW 1.13
            _tile(
              icon: Icons.settings_input_component_outlined,
              title: 'Modbus RS485',
              sub: tr('most Modbus TCP dla HA i odczyt dowolnych rejestrów (falownik, licznik, pompa ciepła)'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ModbusScreen(node: node, pin: pin)),
              ),
            ),
          _tile(
            icon: Icons.engineering_outlined,
            title: tr('Udostępnij instalatorowi'),
            sub: tr('instalator PV widzi produkcję, baterię i alarmy (tylko podgląd)'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => InstallerShareScreen(node: node)),
            ),
          ),
          if ((_fw ?? '').toLowerCase().startsWith('hub-'))
            _tile(
              icon: Icons.sensors,
              title: tr('Czujniki Huba'),
              sub: tr('czujniki z Home Assistanta i wybór, które udostępnić'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => HubSensorsScreen(node: node, pin: pin)),
              ),
            ),
          _tile(
            icon: Icons.location_on_outlined,
            title: tr('Lokalizacja i weryfikacja'),
            sub: tr('ceremonia BLE + GPS — ustawia pozycję i potwierdza urządzenie'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => TrustScreen(node: node, pin: pin)),
            ),
          ),
          _tile(
            icon: Icons.webhook_outlined,
            title: tr('Integracja (webhook)'),
            sub: tr('URL wywoływany przy zdarzeniach noda'),
            onTap: _editIntegration,
          ),
          _tile(
            icon: Icons.hub_outlined,
            title: tr('MQTT (lokalny broker)'),
            sub: tr('publikacja statusu i encji do Mosquitto / Home Assistant'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => MqttScreen(node: node, pin: pin)),
            ),
          ),
          if (_hasLora)
            _tile(
              icon: Icons.cell_tower,
              title: tr('LoRa'),
              sub: tr('awaryjne, odbiór czujników, wysyłka, inbox'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => LoraScreen(node: node, pin: pin)),
              ),
            ),
          // Zdalny dostęp — JEDNO centralne miejsce. Klucz da się zapisać w nodzie wyłącznie
          // po LAN, więc user musi się o tym dowiedzieć TERAZ, gdy jest w domu, a nie dopiero
          // przy próbie użycia terminala czy panelu HA z wakacji, gdzie nie ma jak tego zrobić.
          _tile(
            icon: _paired ? Icons.verified_user_outlined : Icons.shield_outlined,
            title: tr('Zdalny dostęp'),
            sub: _paired
                ? tr('sparowany — terminal i panel HA działają z dowolnego miejsca')
                : tr('NIESPAROWANY — sparuj teraz, będąc w sieci noda'),
            onTap: _togglePairing,
          ),
          _tile(
            icon: Icons.vpn_key_outlined,
            title: tr('Zmień PIN'),
            sub: tr('PIN dostępu do noda'),
            onTap: _changePin,
          ),
          _tile(
            icon: Icons.copy,
            title: tr('Kopiuj ID noda'),
            sub: node.id,
            onTap: () {
              Clipboard.setData(ClipboardData(text: node.id));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(tr('ID skopiowane: %s', [node.id])),
                  duration: const Duration(seconds: 2)));
            },
          ),
          _tile(
            icon: Icons.bluetooth_searching,
            title: tr('Tryb serwisowy (Bluetooth)'),
            sub: tr('zmiana WiFi / odzyskiwanie portfela'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ServiceScreen(node: node)),
            ),
          ),
          const SizedBox(height: 8),
          const Divider(color: Color(0xFF2A2A2A)),
          const SizedBox(height: 8),
          ListTile(
            leading:
                const Icon(Icons.delete_outline, color: Color(0xFFFF4444)),
            title: Text(tr('Usuń node z listy'),
                style: const TextStyle(color: Color(0xFFFF4444))),
            subtitle: Text(tr('Usuwa node tylko z tej apki'),
                style: const TextStyle(color: Color(0xFF888888), fontSize: 12)),
            onTap: _removeFromApp,
          ),
        ],
      ),
    );
  }

  Future<void> _removeFromApp() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('Usunąć z tej apki?')),
        content: Text(tr('Node zniknie tylko z tego telefonu — zostaje w sieci '
            'i dalej nalicza nagrody. Żeby usunąć go z sieci, użyj „Usuń z sieci”.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anuluj'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Usuń z apki'),
                  style: const TextStyle(color: Color(0xFFFF4444)))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    context.read<CoreBloc>().add(NodeRemoved(node.id));
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  // FW ESP32 ≥ major.minor (np. '1.13', '1.13-lora2'); Hub (hub-*) i nieznana wersja = false.
  bool _fwAtLeast(int major, int minor) {
    final m = RegExp(r'^(d+).(d+)').firstMatch((_fw ?? '').trim());
    if (m == null) return false;
    final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
    return a > major || (a == major && b >= minor);
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String sub,
    required VoidCallback onTap,
  }) =>
      Card(
        child: ListTile(
          leading: Icon(icon, color: AppTheme.purple),
          title: Text(title, style: const TextStyle(color: AppTheme.text)),
          subtitle: sub.isEmpty
              ? null
              : Text(sub,
                  style:
                      const TextStyle(color: AppTheme.muted, fontSize: 12)),
          trailing: const Icon(Icons.chevron_right, color: AppTheme.muted),
          onTap: onTap,
        ),
      );

  Future<void> _editIntegration() async {
    final messenger = ScaffoldMessenger.of(context);
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $pin',
    };

    // Pobierz aktualny URL
    String current = '';
    try {
      final res = await http
          .get(Uri.parse('http://${node.ip}/config'), headers: headers)
          .timeout(const Duration(seconds: 5));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      current = (j['integration_url'] ?? '').toString();
    } catch (_) {}
    if (!mounted) return;

    final ctrl = TextEditingController(text: current);
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(tr('Integracja (webhook)'),
            style: const TextStyle(color: AppTheme.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                tr('Node POST-uje tu zdarzenia (message_received, batch_sent, '
                    'sub_received, ws_connected). Puste = wyłączone.'),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              style: const TextStyle(
                  color: AppTheme.text, fontSize: 13, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                hintText: 'https://...',
                hintStyle: TextStyle(color: AppTheme.muted),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Anuluj'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.teal),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('Zapisz'), style: const TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
    if (url == null) return; // anulowane (pusty string = świadome wyłączenie)

    try {
      final res = await http
          .post(Uri.parse('http://${node.ip}/config'),
              headers: headers, body: jsonEncode({'integration_url': url}))
          .timeout(const Duration(seconds: 5));
      messenger.showSnackBar(SnackBar(
        content: Text(res.statusCode == 200
            ? (url.isEmpty ? tr('Integracja wyłączona') : tr('Webhook zapisany'))
            : tr('Błąd %s', [res.statusCode])),
        backgroundColor: res.statusCode == 200 ? null : AppTheme.red,
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(tr('Błąd: %s', [e])), backgroundColor: AppTheme.red));
    }
  }

  Future<void> _changePin() async {
    final nodeService = context.read<NodeService>();
    final messenger = ScaffoldMessenger.of(context);
    // Ekran, nie okienko: pól jest dwa (obecny PIN + nowy), a przy błędzie trzeba pokazać
    // konkretny powód — w AlertDialogu nie ma na to miejsca.
    final newPin = await Navigator.push<String>(
      context,
      MaterialPageRoute(
          builder: (_) => ChangePinScreen(nodeIp: node.ip, currentPin: pin)),
    );
    if (newPin == null || !mounted) return;
    await nodeService.updateNodePin(node.id, newPin);
    if (mounted) setState(() => _pinOverride = newPin);
    messenger.showSnackBar(SnackBar(content: Text(tr('PIN zmieniony'))));
  }

}
