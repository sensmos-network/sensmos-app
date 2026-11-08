import 'package:flutter/material.dart';
import '../l10n.dart';
import '../services/idea_service.dart';
import '../theme.dart';

/// Jedno pytanie „Czego brakuje?" w arkuszu od dołu. Wywoływane z Ustawień i raz na 30 dni
/// z panelu głównego (AppShell). Odpowiedź ląduje w pomysłach na sensmos.com/roadmap.
Future<void> showIdeaSheet(BuildContext context, {bool auto = false}) async {
  final (code, question) = IdeaService.questionOfMonth();
  if (auto) await IdeaService.markPrompted();
  if (!context.mounted) return;
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.card,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => _IdeaSheet(code: code, question: tr(question)),
  );
  if (sent == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('Dziękujemy! Twój pomysł jest na sensmos.com/roadmap.'))));
  }
}

class _IdeaSheet extends StatefulWidget {
  const _IdeaSheet({required this.code, required this.question});
  final String code;
  final String question;

  @override
  State<_IdeaSheet> createState() => _IdeaSheetState();
}

class _IdeaSheetState extends State<_IdeaSheet> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await IdeaService.send(_ctrl.text, widget.code);
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20, 16 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.lightbulb_outline, color: AppTheme.teal),
              const SizedBox(width: 10),
              Expanded(
                child: Text(widget.question,
                    style: const TextStyle(
                        color: AppTheme.text, fontSize: 17, fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 6),
            Text(
                tr('Jedno zdanie wystarczy. Pomysły widać publicznie na sensmos.com/roadmap, najpopularniejsze trafiają do planu.'),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
            const SizedBox(height: 14),
            TextField(
              controller: _ctrl,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              maxLength: 560,
              style: const TextStyle(color: AppTheme.text),
              decoration: InputDecoration(
                hintText: tr('np. chcę widzieć temperaturę z mojej stacji pogodowej w apce'),
                hintStyle: const TextStyle(color: AppTheme.muted, fontSize: 13),
                filled: true,
                fillColor: AppTheme.surface,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppTheme.border)),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, style: const TextStyle(color: AppTheme.red, fontSize: 12)),
              ),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context, false),
                child: Text(tr('Nie teraz'), style: const TextStyle(color: AppTheme.muted)),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.teal, foregroundColor: AppTheme.bg),
                onPressed: _busy ? null : _send,
                child: _busy
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.bg))
                    : Text(tr('Wyślij')),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
