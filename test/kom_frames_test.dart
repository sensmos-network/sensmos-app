import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sensmos_app/services/kom_chat.dart';
import 'package:sensmos_app/services/kom_frames.dart';

/// Ramki apki = ramki komunikatora i serwera: wektory z BE/test/ldev_fixture.json (tools/ldev_fixture.js).
void main() {
  final v = jsonDecode(File('../BE/test/ldev_fixture.json').readAsStringSync()) as Map<String, dynamic>;
  final bePub = komUnhex(v['be_pub']);
  final nonce = komUnhex('0001020304050607');

  test('tożsamość: ID i K_net jak na serwerze', () async {
    final a = await KomKeys.fromSeed(komUnhex(v['dev_priv']), bePub);
    expect(komHex(a.pub), v['dev_pub']);
    expect(a.id8, v['dev_id8']);
    expect(komHex(a.knet), v['k_net']);
  });

  test('HELLO pełne, prywatna z kluczem, grupa — bajt w bajt', () async {
    final a = await KomKeys.fromSeed(komUnhex(v['dev_priv']), bePub);
    expect(komHex(a.hello(2, 2, name: 'Heltec V3')), v['hello_full']);
    expect(komHex(await a.priv(komUnhex(v['peer_pub']), 4, 'Test 2', nonce: nonce)), v['priv_pub']);
    expect(komHex(a.group(komUnhex(v['group_key']), 9, 'Grupa zażółć', nonce: nonce)), v['group']);
    expect(komHex(komGroupId(komUnhex(v['group_key']))), v['group_id']);
  });

  test('odczyt: prywatna u adresata, grupa, ACK E2E', () async {
    final a = await KomKeys.fromSeed(komUnhex(v['dev_priv']), bePub);
    final b = await KomKeys.fromSeed(komUnhex(v['peer_priv']), bePub);
    final f = KomFrame.parse(komUnhex(v['priv_pub']))!;
    final got = await f.openPriv(b);
    expect(got?.$2, 'Test 2');
    expect(komHex(got!.$1), v['dev_pub']);
    expect(await f.openPriv(a), isNull);                             // nie do mnie
    expect(KomFrame.parse(komUnhex(v['group']))!.openGroup(komUnhex(v['group_key'])), 'Grupa zażółć');
    expect(KomFrame.parse(komUnhex(v['group']))!.openGroup(komUnhex('33' * 32)), isNull);
    expect(await KomFrame.parse(komUnhex(v['ack']))!.openAck(a, b.pub), [3, 4]);
    final mine = await b.ack(a.pub, 7, [5]);
    expect(await KomFrame.parse(mine)!.openAck(a, b.pub), [5]);
  });

  test('nazwa nadawcy w treści: pierwszy bajt = długość, bez nazwy zero bajtów', () {
    final w = komWithName('Łłżźćśąęóń', 'Cześć');
    expect(utf8.encode(w).length, 1 + 20 + utf8.encode('Cześć').length);
    expect(komSplitName(w), ('Łłżźćśąęóń', 'Cześć'));
    expect(komSplitName('Cześć'), (null, 'Cześć'));
    expect(komSplitName('	ab'), (null, '	ab'));            // długość ponad treść
  });
}
