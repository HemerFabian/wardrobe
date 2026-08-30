import 'package:flutter_test/flutter_test.dart';

import 'package:wardrobe_flutter/main.dart';

void main() {
  testWidgets('app boots the home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const WardrobeApp());

    expect(find.byType(WardrobeHomeScreen), findsOneWidget);
  });
}
