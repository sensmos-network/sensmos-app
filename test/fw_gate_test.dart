import 'package:flutter_test/flutter_test.dart';
import 'package:sensmos_app/util/fw_gate.dart';

void main() {
  test('node ESP32: próg 0.70', () {
    expect(tunnelCapable('0.70'), isFalse);
    expect(tunnelCapable('0.69'), isFalse);
    expect(tunnelCapable('0.71'), isTrue);
    expect(tunnelCapable('1.10'), isTrue);
    expect(tunnelCapable('0.80-lora6'), isTrue);
    expect(tunnelCapable('1.10-lora2'), isTrue);
  });
  test('Hub ma własną numerację i zawsze umie tunel', () {
    expect(tunnelCapable('hub-0.1.0'), isTrue);
    expect(tunnelCapable('hub-0.1.1'), isTrue);
  });
  test('brak / śmieci', () {
    expect(tunnelCapable(null), isFalse);
    expect(tunnelCapable('?'), isFalse);
    expect(tunnelCapable(''), isFalse);
  });
}
