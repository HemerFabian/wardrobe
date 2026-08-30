import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wardrobe_flutter/services/wardrobe_repository.dart';
import 'package:wardrobe_flutter/ui/outfit_view.dart';

void main() {
  testWidgets('shows placeholder when base image is missing', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: OutfitView(
            composition: OutfitComposition(
              baseImagePath: null,
              overlays: <String>[],
            ),
            aspectRatio: 9 / 16,
          ),
        ),
      ),
    );

    expect(
      find.text('No render available for this combination.'),
      findsNothing,
    );
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
  });

  testWidgets('renders base image with contain fit to avoid cropping', (
    WidgetTester tester,
  ) async {
    const tinyPngDataUri =
        'data:image/png;base64,'
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO9X2TQAAAAASUVORK5CYII=';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: OutfitView(
            composition: OutfitComposition(
              baseImagePath: tinyPngDataUri,
              overlays: <String>[],
            ),
            aspectRatio: 9 / 16,
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.fit, BoxFit.contain);
    expect(image.gaplessPlayback, isTrue);
  });

  testWidgets(
    'keeps the previous base image visible while the next frame is loading',
    (WidgetTester tester) async {
      const tinyPngDataUri =
          'data:image/png;base64,'
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO9X2TQAAAAASUVORK5CYII=';

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: OutfitView(
              composition: OutfitComposition(
                baseImagePath: tinyPngDataUri,
                overlays: <String>[],
              ),
              aspectRatio: 9 / 16,
            ),
          ),
        ),
      );

      final image = tester.widget<Image>(find.byType(Image).first);
      final frameBuilder = image.frameBuilder;
      expect(frameBuilder, isNotNull);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (BuildContext context) {
              return frameBuilder!(
                context,
                const SizedBox(key: ValueKey<String>('loading-child')),
                null,
                false,
              );
            },
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('loading-child')),
        findsOneWidget,
      );
      expect(find.byType(AnimatedOpacity), findsNothing);
      expect(find.byType(Stack), findsOneWidget);
    },
  );
}
