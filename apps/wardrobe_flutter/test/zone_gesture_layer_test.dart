import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

import 'package:wardrobe_flutter/ui/zone_gesture_layer.dart';

void main() {
  const mapper = ZoneMapper();
  const size = Size(100, 200);

  test('maps y zones to expected categories', () {
    expect(mapper.mapPointToCategory(const Offset(50, 0), size), 'headwear');
    expect(mapper.mapPointToCategory(const Offset(50, 80), size), 'top');
    expect(mapper.mapPointToCategory(const Offset(50, 140), size), 'bottom');
    expect(mapper.mapPointToCategory(const Offset(50, 199), size), 'shoes');
  });

  test('horizontal direction uses threshold', () {
    expect(
      mapper.horizontalDirection(
        start: const Offset(10, 10),
        end: const Offset(20, 10),
      ),
      0,
    );
    expect(
      mapper.horizontalDirection(
        start: const Offset(10, 10),
        end: const Offset(40, 10),
      ),
      1,
    );
    expect(
      mapper.horizontalDirection(
        start: const Offset(40, 10),
        end: const Offset(10, 10),
      ),
      -1,
    );
  });

  test('horizontal direction accepts shorter swipes than before', () {
    expect(
      mapper.horizontalDirection(
        start: const Offset(10, 10),
        end: const Offset(22, 10),
      ),
      1,
    );
  });

  testWidgets('long press reports the touched category', (
    WidgetTester tester,
  ) async {
    final reportedCategories = <String>[];

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 100,
            height: 200,
            child: ZoneGestureLayer(
              onCategorySwipe: (String category, int direction) {},
              onCategoryLongPress: (String category) {
                reportedCategories.add(category);
              },
            ),
          ),
        ),
      ),
    );

    final origin = tester.getTopLeft(find.byType(ZoneGestureLayer));

    await tester.longPressAt(origin + const Offset(50, 10));
    await tester.pump();
    await tester.longPressAt(origin + const Offset(50, 190));
    await tester.pump();

    expect(reportedCategories, <String>['headwear', 'shoes']);
  });
}
