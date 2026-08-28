import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/widgets/bounded_network_image.dart';

void main() {
  group('BoundedNetworkImage.cacheWidthFor', () {
    test(
      'rounds a fractional physical width up so the paint never stretches',
      () {
        expect(BoundedNetworkImage.cacheWidthFor(160.2, 1.0), 161);
        expect(BoundedNetworkImage.cacheWidthFor(100, 1.25), 125);
        expect(BoundedNetworkImage.cacheWidthFor(101, 1.25), 127);
      },
    );

    test('caps the pixel ratio where the server requests cap it', () {
      expect(BoundedNetworkImage.cacheWidthFor(100, 3.0), 200);
      expect(BoundedNetworkImage.cacheWidthFor(100, 0.5), 100);
    });

    test('keeps the caller bounds', () {
      expect(BoundedNetworkImage.cacheWidthFor(10, 2.0), 64);
      expect(BoundedNetworkImage.cacheWidthFor(900, 2.0), 1024);
      expect(BoundedNetworkImage.cacheWidthFor(900, 2.0, maxWidth: 640), 640);
    });
  });
}
