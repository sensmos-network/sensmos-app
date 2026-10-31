import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../theme.dart';
import '../../l10n.dart';
import '../../core/core_bloc.dart';
import '../../services/wallet_service.dart';
import '../../services/pairing_service.dart';
import '../../services/terminal_relay.dart';
import '../../services/integrations/http_over_tunnel.dart';
import '../../services/integrations/integration_store.dart';
import '../../util/owner_token_gate.dart';
import '../../services/owner_token_service.dart';

/// Panel LAN: WebView ładujący panel z sieci noda PRZEZ TUNEL. WebView nie umie sam
/// gadać tunelem, więc stawiamy lokalne proxy: HttpServer na 127.0.0.1, każdy request
/// z WebView jest przepychany HttpOverTunnel-em do hosta w LAN i odpowiedź wraca.
/// Ograniczenia v1 (świadome): tylko HTTP, jeden Set-Cookie per odpowiedź, bez WebSocketów
/// — czyli lekkie panele (router, drukarka, Pi-hole), nie SPA typu UniFi/HA.
class LanWebScreen extends StatefulWidget {
  final String deviceId;
  final LanPanel panel;
  const LanWebScreen({super.key, required this.deviceId, required this.panel});

  @override
  State<LanWebScreen> createState() => _LanWebScreenState();
}

class _LanWebScreenState extends State<LanWebScreen> {
  TerminalRelay? _relay;
  HttpOverTunnel? _tunnel;
  HttpServer? _proxy;
  WebViewController? _web;
  String _status = '';
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() { _status = tr('Otwieram tunel do noda…'); _error = false; });
    try {
      final wallet = context.read<CoreBloc>().state.wallet;
      if (wallet == null) throw Exception(tr('Brak portfela w apce'));
      final svc = PairingService();
      final pairKey = await svc.keyFor(widget.deviceId);
      if (pairKey == null) {
        throw Exception(tr('Node niesparowany — tunel nie ruszy. Sparuj, będąc w jego sieci WiFi.'));
      }
      if (!mounted) return;
      final token = await ensureOwnerToken(context, wallet.address, label: 'Ten telefon');
      if (!mounted) return;

      final relay = TerminalRelay(
        deviceId: widget.deviceId,
        owner: wallet.address,
        signMessage: (m) => context.read<WalletService>().signMessage(m),
        ownerToken: token,
        onTokenRejected: () => OwnerTokenService().forget(wallet.address),
        pairKey: pairKey,
      );
      _relay = relay;
      await relay.connect();
      if (!relay.nodeOnline) {
        throw Exception(tr('Node jest offline — nie połączysz się z nim, dopóki nie wróci do sieci.'));
      }
      final sock = await relay.openTunnel(widget.panel.host, widget.panel.port);
      _tunnel = HttpOverTunnel(sock, '${widget.panel.host}:${widget.panel.port}');

      // Lokalne proxy dla WebView. Port efemeryczny, tylko loopback.
      _proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _proxy!.listen(_handle, onError: (_) {});

      final ctrl = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(AppTheme.surface)
        ..loadRequest(Uri.parse('http://127.0.0.1:${_proxy!.port}/'));
      if (!mounted) return;
      setState(() { _web = ctrl; _status = ''; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _status = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  // Jeden request WebView → tunel → odpowiedź. HttpOverTunnel serializuje requesty na
  // jednym sockecie, więc równoległe zasoby strony i tak idą sznureczkiem — to OK,
  // tunel przez ESP32 nie zyskałby na równoległości.
  Future<void> _handle(HttpRequest req) async {
    try {
      final tun = _tunnel;
      if (tun == null) throw Exception('tunnel gone');
      String? body;
      if (req.method != 'GET' && req.method != 'HEAD') {
        body = await utf8.decodeStream(req);
        if (body.isEmpty) body = null;
      }
      final headers = <String, String>{};
      req.headers.forEach((k, v) {
        final lk = k.toLowerCase();
        // host/connection ustawia HttpOverTunnel; accept-encoding wycinamy (nie dekodujemy gzip)
        if (lk == 'host' || lk == 'connection' || lk == 'accept-encoding' ||
            lk == 'content-length') return;
        headers[k] = v.join(', ');
      });
      headers['Accept-Encoding'] = 'identity';
      final resp = await tun.request(req.method, req.uri.toString(),
          headers: headers, body: body);

      req.response.statusCode = resp.status == 0 ? 502 : resp.status;
      for (final e in resp.headers.entries) {
        final lk = e.key;
        if (lk == 'transfer-encoding' || lk == 'content-length' || lk == 'connection') continue;
        if (lk == 'location') {
          // Absolutny redirect na hosta w LAN → z powrotem we względny (przez proxy).
          var loc = e.value;
          final pfx = 'http://${widget.panel.host}';
          if (loc.startsWith(pfx)) {
            loc = loc.substring(pfx.length);
            if (loc.startsWith(':${widget.panel.port}')) {
              loc = loc.substring(':${widget.panel.port}'.length);
            }
            if (loc.isEmpty) loc = '/';
          }
          req.response.headers.set('location', loc);
          continue;
        }
        req.response.headers.set(e.key, e.value);
      }
      req.response.add(resp.body);
    } catch (e) {
      final target = '${widget.panel.host}:${widget.panel.port}';
      final msg = '$e'.contains('zamknięty')
          ? tr('Urządzenie %s zamknęło połączenie bez odpowiedzi. Sprawdź adres IP i port oraz czy urządzenie działa po zwykłym HTTP (HTTPS przez tunel nie działa).', [target])
          : tr('Nie udało się połączyć z %s przez tunel.', [target]);
      req.response.statusCode = 502;
      req.response.headers.contentType = ContentType.html;
      req.response.write('<html><body style="font-family:sans-serif;padding:16px;background:#fff;color:#111">'
          '<p>${const HtmlEscape().convert(msg)}</p>'
          '<p style="color:#666;font-size:12px">${const HtmlEscape().convert('$e')}</p></body></html>');
    }
    try { await req.response.close(); } catch (_) {}
  }

  @override
  void dispose() {
    try { _proxy?.close(force: true); } catch (_) {}
    try { _tunnel?.close(); } catch (_) {}
    try { _relay?.dispose(); } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${tr('HTTP w LAN')} · ${widget.panel.name}'),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _web?.reload()),
        ],
      ),
      body: _web != null
          ? WebViewWidget(controller: _web!)
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (!_error) const CircularProgressIndicator(color: AppTheme.teal),
                  if (_error) const Icon(Icons.link_off, color: AppTheme.red, size: 36),
                  const SizedBox(height: 14),
                  Text(_status,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: _error ? AppTheme.red : AppTheme.muted, fontSize: 13)),
                  if (_error) ...[
                    const SizedBox(height: 12),
                    OutlinedButton(onPressed: _start, child: Text(tr('Spróbuj ponownie'))),
                  ],
                ]),
              ),
            ),
    );
  }
}
