import 'package:flutter_test/flutter_test.dart';
import 'package:sensmos_app/services/idea_service.dart';

void main() {
  test('krótka odpowiedź: tytuł = odpowiedź, opis z kodem pytania', () {
    final (t, x) = IdeaService.buildPayload('  Chcę  widżet\nstanu nodów  ', 'brakuje');
    expect(t, 'Chcę widżet stanu nodów');
    expect(x, 'Chcę widżet stanu nodów #app-brakuje');
  });

  test('długa odpowiedź mieści się w limitach serwera (tytuł 3–80, opis 10–600)', () {
    final long = List.filled(200, 'słowo').join(' ');
    final (t, x) = IdeaService.buildPayload(long, 'uzycie');
    expect(t.length, lessThanOrEqualTo(80));
    expect(t.endsWith('...'), isTrue);
    expect(x.length, lessThanOrEqualTo(600));
    expect(x.endsWith('#app-uzycie'), isTrue);
  });

  test('pytania rotują co miesiąc', () {
    final a = IdeaService.questionOfMonth(DateTime(2026, 11, 8)).$1;
    final b = IdeaService.questionOfMonth(DateTime(2026, 12, 1)).$1;
    final c = IdeaService.questionOfMonth(DateTime(2027, 1, 1)).$1;
    expect({a, b, c}.length, 3);
  });
}
