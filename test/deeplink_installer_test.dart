import 'package:flutter_test/flutter_test.dart';
import 'package:sensmos_app/services/deeplink_service.dart';

void main() {
  const a = '0x09692218bf83a8f9c2979dd80ce299b566bc0511';
  test('zaproszenie instalatora: adres i nazwa', () {
    final i = DeepLinkService.installerInvite('sensmos://open?kind=installer&grant=${a.toUpperCase().replaceFirst('0X', '0x')}&name=Fotowolt%20Kowalski');
    expect(i?.address, a);
    expect(i?.name, 'Fotowolt Kowalski');
    expect(DeepLinkService.kindOf('sensmos://open?kind=installer&grant=$a'), 'installer');
  });
  test('zły adres, obcy schemat albo inny rodzaj linku = brak zaproszenia', () {
    expect(DeepLinkService.installerInvite('sensmos://open?kind=installer&grant=0x123'), isNull);
    expect(DeepLinkService.installerInvite('https://sensmos.com/installer/?grant=$a'), isNull);
    expect(DeepLinkService.installerInvite('sensmos://open?kind=ha&grant=$a'), isNull);
  });
  test('nazwa: znaki sterujące usunięte, max 40 znaków', () {
    final i = DeepLinkService.installerInvite('sensmos://open?kind=installer&grant=$a&name=${Uri.encodeComponent('A\nB${'x' * 80}')}');
    expect(i?.name.contains('\n'), isFalse);
    expect(i?.name.length, 40);
  });
}
