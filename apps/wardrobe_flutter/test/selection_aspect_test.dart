import 'package:flutter_test/flutter_test.dart';
import 'package:wardrobe_flutter/ui/intake/selection_aspect.dart';

void main() {
  group('normalizedSelectionAspectRatio', () {
    test(
      'converts viewport aspect ratio into normalized image-space ratio',
      () {
        final ratio = normalizedSelectionAspectRatio(
          viewportAspectRatio: 1072 / 1936,
          imageAspectRatio: 4 / 5,
        );

        expect(ratio, closeTo((1072 / 1936) / (4 / 5), 0.000001));
      },
    );

    test('falls back safely for invalid inputs', () {
      final ratio = normalizedSelectionAspectRatio(
        viewportAspectRatio: 0,
        imageAspectRatio: -2,
      );

      expect(ratio, 1);
    });
  });
}
