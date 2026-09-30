import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme.dart';
import '../../l10n.dart';
import '../../services/kom_ble.dart';

/// PIN komunikatora na pełnym ekranie: podanie przy podłączeniu (`set: false`) albo nowy PIN
/// z ustawień (`set: true`). Telefon zapamiętuje go w obu przypadkach.
class KomPinScreen extends StatefulWidget {
  final KomBle kom;
  final bool set;
  const KomPinScreen({super.key, required this.kom, this.set = false});

  @override
  State<KomPinScreen> createState() => _KomPinScreenState();
}

class _KomPinScreenState extends State<KomPinScreen> {
  final _c = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final v = _c.text;
    if (!RegExp(r'^\d{6}$').hasMatch(v)) {
      setState(() => _error = tr('PIN to dokładnie 6 cyfr.'));
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      widget.set ? await widget.kom.setPin(v) : await widget.kom.auth(v);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = komErrText(e); });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.set ? tr('Nowy PIN komunikatora') : tr('PIN komunikatora'))),
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const SizedBox(height: 8),
            Text(
                widget.set
                    ? tr('Telefony, które nie znają PIN-u, poproszą o niego przy podłączeniu. Ten telefon zapamięta go sam.')
                    : tr('Ten komunikator ma PIN. Podaj go raz — telefon go zapamięta.'),
                style: const TextStyle(color: AppTheme.muted, fontSize: 14, height: 1.4)),
            const SizedBox(height: 20),
            TextField(
              controller: _c,
              autofocus: true,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.text, fontSize: 28, letterSpacing: 8),
              decoration: InputDecoration(hintText: '······', errorText: _error),
              onChanged: (_) { if (_error != null) setState(() => _error = null); },
              onSubmitted: (_) => _go(),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _go,
              style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.teal,
                  foregroundColor: AppTheme.bg,
                  padding: const EdgeInsets.symmetric(vertical: 16)),
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(widget.set ? tr('Zapisz PIN') : tr('Podłącz'),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ]),
        ),
      );
}
