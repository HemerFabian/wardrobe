import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wardrobe_flutter/services/content_pack_service.dart';
import 'package:wardrobe_flutter/services/intake_workspace_service.dart';
import 'package:wardrobe_flutter/ui/edit_clothing_item_screen.dart';

void main() {
  testWidgets(
    'shows capped preview above the name field and opens zoom dialog',
    (WidgetTester tester) async {
      final tempRoot = Directory.systemTemp.createTempSync(
        'wardrobe_edit_item_test_',
      );
      addTearDown(() {
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      });

      final previewFile = File('${tempRoot.path}/preview.png');
      previewFile.writeAsBytesSync(_tinyPngBytes(), flush: true);

      final service = _FakeIntakeWorkspaceService(
        metadata: EditableWardrobeItemMetadata(
          name: 'Preview Top',
          category: 'top',
          subcategory: 'shirt',
          colorPrimary: 'white',
          material: 'cotton',
          styleOccasion: 'casual',
          patternDesign: 'solid',
          tags: const <String>['summer'],
          previewImagePath: previewFile.path,
        ),
        suggestions: const IntakeTagSuggestions(tags: <String>['summer']),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: EditClothingItemScreen(
            workspaceService: service,
            category: 'top',
            itemId: 'preview-top',
          ),
        ),
      );
      await _settleScreen(tester);

      final previewFinder = find.byKey(const Key('edit-item-preview'));
      expect(previewFinder, findsOneWidget);
      expect(
        tester.getSize(previewFinder).height,
        moreOrLessEquals(168, epsilon: 0.01),
      );

      final previewBottom = tester.getBottomLeft(previewFinder).dy;
      final nameLabelTop = tester.getTopLeft(find.text('Name')).dy;
      expect(nameLabelTop, greaterThan(previewBottom));

      await tester.tap(previewFinder);
      await _settleScreen(tester);

      expect(find.byKey(const Key('edit-item-preview-dialog')), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);

      await tester.tap(find.byKey(const Key('edit-item-preview-close')));
      await _settleScreen(tester);

      expect(find.byKey(const Key('edit-item-preview-dialog')), findsNothing);

      await tester.tap(previewFinder);
      await _settleScreen(tester);
      expect(find.byKey(const Key('edit-item-preview-dialog')), findsOneWidget);

      await tester.tapAt(const Offset(5, 5));
      await _settleScreen(tester);

      expect(find.byKey(const Key('edit-item-preview-dialog')), findsNothing);
    },
  );

  testWidgets(
    'shows placeholder and does not open dialog when preview is missing',
    (WidgetTester tester) async {
      final service = _FakeIntakeWorkspaceService(
        metadata: const EditableWardrobeItemMetadata(
          name: 'Missing Preview',
          category: 'top',
          subcategory: 'shirt',
          colorPrimary: 'white',
          material: 'cotton',
          styleOccasion: 'casual',
          patternDesign: 'solid',
          tags: <String>[],
          previewImagePath: '/definitely/missing.png',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: EditClothingItemScreen(
            workspaceService: service,
            category: 'top',
            itemId: 'missing-preview',
          ),
        ),
      );
      await _settleScreen(tester);

      expect(find.byKey(const Key('edit-item-preview')), findsOneWidget);
      expect(find.byIcon(Icons.image_not_supported), findsOneWidget);

      await tester.tap(find.byKey(const Key('edit-item-preview')));
      await _settleScreen(tester);

      expect(find.byKey(const Key('edit-item-preview-dialog')), findsNothing);
    },
  );
}

class _FakeIntakeWorkspaceService extends IntakeWorkspaceService {
  _FakeIntakeWorkspaceService({
    required this.metadata,
    this.suggestions = const IntakeTagSuggestions(),
  }) : super(
         ContentPackService(
           appDirectoryProvider: () async => Directory.systemTemp,
         ),
       );

  final EditableWardrobeItemMetadata metadata;
  final IntakeTagSuggestions suggestions;

  @override
  Future<EditableWardrobeItemMetadata> loadEditableItemMetadata({
    required String category,
    required String itemId,
  }) async {
    return metadata;
  }

  @override
  Future<IntakeTagSuggestions> loadTagSuggestions() async {
    return suggestions;
  }
}

List<int> _tinyPngBytes() {
  return base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlH0X8AAAAASUVORK5CYII=',
  );
}

Future<void> _settleScreen(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}
