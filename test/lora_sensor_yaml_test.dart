import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sensmos_app/screens/node_config/lora_add_sensor_screen.dart';

// „Dodaj czujnik LoRa”: plik ESPHome z apki. LORA_YAML_OUT=<katalog> zapisuje pliki do sprawdzenia `esphome config`.
void main() {
  for (final board in ['heltec_v3', 'xiao_s3']) {
    test('YAML czujnika: $board, wszystkie rodzaje', () {
      final y = loraSensorYaml(
          board: board, kinds: {'temp', 'door', 'leak'}, name: 'Garaż Zbyszka!', id8: 'a1b2c3d4', sub: 3, key: 'abcde-fghij');
      expect(y, contains('name: gara-zbyszka'));
      expect(y, contains('hub: "a1b2c3d4"'));
      expect(y, contains('sub: 3'));
      expect(y, contains('key: "abcde-fghij"'));
      expect(y, contains('frequency: 868.1MHz'));
      expect(y, contains('crc_enable: true'));
      expect(y, isNot(contains('{')), reason: 'wszystkie piny podstawione');
      expect(RegExp(r'^binary_sensor:', multiLine: true).allMatches(y).length, 1, reason: 'jeden blok binary_sensor');
      expect(y, contains('    - sensor: leak\n      key: leak'));
      final out = Platform.environment['LORA_YAML_OUT'];
      if (out != null) File('$out/$board.yaml').writeAsStringSync(y);
    });
  }
  test('YAML czujnika: sam kontaktron, bez sekcji sensors', () {
    final y = loraSensorYaml(board: 'heltec_v3', kinds: {'door'}, name: '', id8: 'a1b2c3d4', sub: 1, key: '');
    expect(y, contains('key: "TWOJA-FRAZA"'));
    expect(y, isNot(contains('  sensors:')));
    expect(y, isNot(contains('one_wire')));
    expect(y, contains('name: czujnik-lora'));
  });
}
