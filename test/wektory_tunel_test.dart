// Wektor tunelu v2 (kontrakt/protokol/wektory/tunel-v2.json, spec tunel.md) przeciw TunnelCrypto.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:sensmos_app/services/tunnel_crypto.dart';

Uint8List hex(String s) =>
    Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

void main() {
  final dir = Platform.environment['SENSMOS_WEKTORY'] ?? '../kontrakt/protokol/wektory';
  final v = jsonDecode(File('$dir/tunel-v2.json').readAsStringSync()) as Map<String, dynamic>;
  final frames = (v['frames'] as List).cast<Map<String, dynamic>>();
  final ts = v['ts'] as int;
  TunnelCrypto tc() => TunnelCrypto(hex(v['pair_key']), ts);

  test('apka odszyfrowuje ramki od noda', () {
    final t = tc();
    for (final f in frames.where((f) => f['dir'] == 0)) {
      expect(utf8.decode(t.open(hex(f['frame']))), f['pt'], reason: f['opis']);
    }
  });

  test('apka odrzuca powtórkę i ramki zmienione', () {
    final t = tc();
    t.open(hex(frames[0]['frame']));
    expect(() => t.open(hex(frames[0]['frame'])), throwsA(anything));
    for (final b in (v['bad'] as List).cast<Map<String, dynamic>>()) {
      expect(() => tc().open(hex(b['frame'])), throwsA(anything), reason: b['opis']);
    }
  });

  test('ramka apki da się otworzyć kluczem i AAD ze specyfikacji', () {
    final sealed = tc().seal(Uint8List.fromList(utf8.encode('GET / HTTP/1.1\r\n\r\n')));
    final seq = ByteData.sublistView(sealed, 0, 8).getUint64(0, Endian.big);
    final aad = BytesBuilder()
      ..add('tun2'.codeUnits)
      ..add(Uint8List(4)..buffer.asByteData().setUint32(0, ts, Endian.big))
      ..addByte(1)
      ..add(Uint8List(8)..buffer.asByteData().setUint64(0, seq, Endian.big));
    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(hex(v['session_key'])), 128,
          Uint8List.sublistView(sealed, 8, 20), aad.toBytes()));
    expect(utf8.decode(gcm.process(Uint8List.sublistView(sealed, 20))), 'GET / HTTP/1.1\r\n\r\n');
  });
}
