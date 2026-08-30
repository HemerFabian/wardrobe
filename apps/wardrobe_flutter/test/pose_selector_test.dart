import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wardrobe_flutter/ui/pose_selector.dart';

void main() {
  testWidgets('shows chips and triggers selection callback', (
    WidgetTester tester,
  ) async {
    String? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PoseSelector(
            poseIds: const <String>['pose_a', 'pose_b'],
            selectedPoseId: 'pose_a',
            onSelected: (String poseId) {
              selected = poseId;
            },
          ),
        ),
      ),
    );

    expect(find.text('pose_a'), findsOneWidget);
    expect(find.text('pose_b'), findsOneWidget);

    await tester.tap(find.text('pose_b'));
    await tester.pump();

    expect(selected, 'pose_b');
  });
}
