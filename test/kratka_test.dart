import 'package:flutter_test/flutter_test.dart';
import 'package:sensmos_app/services/attest_service.dart';

void main() {
  test('kratka 0,05°: środek komórki, 6 miejsc, ujemne współrzędne', () {
    expect(AttestService.kratka(52.229676), '52.225000');
    expect(AttestService.kratka(21.012229), '21.025000');
    expect(AttestService.kratka(52.2001), AttestService.kratka(52.2499));
    expect(AttestService.kratka(-3.70379), '-3.725000');
    expect(AttestService.kratka(-23.5505), '-23.575000');
  });
}
