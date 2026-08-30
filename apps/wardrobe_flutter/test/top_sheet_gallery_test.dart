import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import 'package:wardrobe_flutter/models/wardrobe.dart';
import 'package:wardrobe_flutter/services/wardrobe_repository.dart';
import 'package:wardrobe_flutter/ui/top_sheet_gallery.dart';

void main() {
  Rect clothesViewportRect(WidgetTester tester) {
    return tester.getRect(find.byKey(const Key('top-sheet-clothes-viewport')));
  }

  double clothesViewportTop(WidgetTester tester) {
    return clothesViewportRect(tester).top;
  }

  bool isVisibleInClothesViewport(WidgetTester tester, Finder finder) {
    final viewportRect = clothesViewportRect(tester);
    final candidateRect = tester.getRect(finder.first);
    return candidateRect.bottom > viewportRect.top &&
        candidateRect.top < viewportRect.bottom;
  }

  void expectNearClothesViewportTop(
    WidgetTester tester,
    Finder finder, {
    double maxDelta = 32,
  }) {
    final delta =
        tester.getTopLeft(finder.first).dy - clothesViewportTop(tester);
    expect(delta, greaterThanOrEqualTo(0));
    expect(delta, lessThanOrEqualTo(maxDelta));
  }

  void expectInUpperHalfOfClothesViewport(
    WidgetTester tester,
    Finder finder, {
    double maxFraction = 0.55,
  }) {
    final viewportRect = clothesViewportRect(tester);
    final candidateRect = tester.getRect(finder.first);
    final delta = candidateRect.top - viewportRect.top;
    expect(delta, greaterThanOrEqualTo(0));
    expect(delta, lessThanOrEqualTo(viewportRect.height * maxFraction));
  }

  Positioned positionedAncestorOf(WidgetTester tester, Finder finder) {
    return tester.widget<Positioned>(
      find.ancestor(of: finder, matching: find.byType(Positioned)).first,
    );
  }

  WardrobeManifest buildManifest() {
    return WardrobeManifest.empty().copyWith(
      categories: const <String, List<WardrobeItem>>{
        'headwear': <WardrobeItem>[],
        'top': <WardrobeItem>[
          WardrobeItem(
            id: 'top-a',
            category: 'top',
            colorPrimary: 'white',
            subcategory: 't-shirt',
            tags: <String>[],
            renderReady: true,
          ),
          WardrobeItem(
            id: 'top-b',
            category: 'top',
            colorPrimary: 'blue',
            subcategory: 'hoodie',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'bottom': <WardrobeItem>[
          WardrobeItem(
            id: 'bottom-a',
            category: 'bottom',
            colorPrimary: 'black',
            subcategory: 'jeans',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'shoes': <WardrobeItem>[],
      },
    );
  }

  WardrobeManifest buildLongManifest() {
    final topItems = List<WardrobeItem>.generate(18, (int index) {
      final number = index + 1;
      return WardrobeItem(
        id: 'top-$number',
        category: 'top',
        colorPrimary: 'white',
        subcategory: 'type-$number',
        tags: const <String>[],
        renderReady: true,
      );
    });

    return WardrobeManifest.empty().copyWith(
      categories: <String, List<WardrobeItem>>{
        'headwear': const <WardrobeItem>[],
        'top': topItems,
        'bottom': const <WardrobeItem>[
          WardrobeItem(
            id: 'bottom-target',
            category: 'bottom',
            colorPrimary: 'black',
            subcategory: 'jeans',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'shoes': const <WardrobeItem>[],
      },
    );
  }

  WardrobeManifest buildUnevenSectionsManifest() {
    final headwearItems = List<WardrobeItem>.generate(30, (int index) {
      final number = index + 1;
      return WardrobeItem(
        id: 'headwear-$number',
        category: 'headwear',
        colorPrimary: 'black',
        tags: const <String>[],
        renderReady: true,
      );
    });
    final topItems = List<WardrobeItem>.generate(30, (int index) {
      final number = index + 1;
      return WardrobeItem(
        id: 'top-bulk-$number',
        category: 'top',
        colorPrimary: 'white',
        subcategory: 'tee',
        tags: const <String>[],
        renderReady: true,
      );
    });

    return WardrobeManifest.empty().copyWith(
      categories: <String, List<WardrobeItem>>{
        'headwear': headwearItems,
        'top': topItems,
        'bottom': const <WardrobeItem>[
          WardrobeItem(
            id: 'bottom-target',
            category: 'bottom',
            colorPrimary: 'black',
            subcategory: 'jeans',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'shoes': const <WardrobeItem>[
          WardrobeItem(
            id: 'shoe-target',
            category: 'shoes',
            colorPrimary: 'white',
            subcategory: 'sneaker',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'outerwear': const <WardrobeItem>[
          WardrobeItem(
            id: 'outerwear-target',
            category: 'outerwear',
            colorPrimary: 'green',
            subcategory: 'jacket',
            tags: <String>[],
            renderReady: true,
          ),
        ],
      },
    );
  }

  WardrobeManifest buildOptionalClothesManifest() {
    return WardrobeManifest.empty().copyWith(
      categories: const <String, List<WardrobeItem>>{
        'headwear': <WardrobeItem>[
          WardrobeItem(
            id: 'beanie',
            category: 'headwear',
            colorPrimary: 'black',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'top': <WardrobeItem>[
          WardrobeItem(
            id: 'top-a',
            category: 'top',
            colorPrimary: 'white',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'bottom': <WardrobeItem>[
          WardrobeItem(
            id: 'bottom-a',
            category: 'bottom',
            colorPrimary: 'black',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'shoes': <WardrobeItem>[
          WardrobeItem(
            id: 'sneaker-red',
            category: 'shoes',
            colorPrimary: 'red',
            tags: <String>[],
            renderReady: true,
          ),
        ],
      },
    );
  }

  testWidgets('shows filter summary and edit action icon', (
    WidgetTester tester,
  ) async {
    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: buildManifest(),
        packRoot: Directory.systemTemp,
      )
      ..selectCategory('top');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopSheetGallery(
            repository: repo,
            onEditClothingItem:
                ({required String category, required String itemId}) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(MdiIcons.tshirtCrew).first);
    await tester.pumpAndSettle();

    expect(find.byTooltip('Filter clothes'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsWidgets);
  });

  testWidgets('item action icon sits flush with the card corner', (
    WidgetTester tester,
  ) async {
    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: buildManifest(),
        packRoot: Directory.systemTemp,
      )
      ..selectCategory('top');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopSheetGallery(
            repository: repo,
            onEditClothingItem:
                ({required String category, required String itemId}) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final positioned = positionedAncestorOf(
      tester,
      find.byTooltip('Item actions').first,
    );

    expect(positioned.top, 0);
    expect(positioned.left, 0);
  });

  testWidgets('pose action icon sits flush with the card corner', (
    WidgetTester tester,
  ) async {
    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: WardrobeManifest.empty().copyWith(
          poses: const <WardrobePose>[
            WardrobePose(id: 'pose-1', name: 'Pose 1', renderReady: true),
          ],
        ),
        packRoot: Directory.systemTemp,
      );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopSheetGallery(
            repository: repo,
            onEditPose:
                ({required String poseId, required String name}) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Poses'));
    await tester.pumpAndSettle();

    final positioned = positionedAncestorOf(
      tester,
      find.byIcon(Icons.info_outline).first,
    );

    expect(positioned.top, 0);
    expect(positioned.left, 0);
  });

  testWidgets('edits pose name via callback from pose card', (
    WidgetTester tester,
  ) async {
    String? editedPoseId;
    String? editedName;

    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: buildManifest().copyWith(
          poses: const <WardrobePose>[
            WardrobePose(id: 'pose-1', name: 'Pose 1', renderReady: true),
          ],
        ),
        packRoot: Directory.systemTemp,
      )
      ..selectCategory('top');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopSheetGallery(
            repository: repo,
            onEditPose: ({required String poseId, required String name}) async {
              editedPoseId = poseId;
              editedName = name;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Poses'));
    await tester.pumpAndSettle();

    expect(find.text('Pose 1'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.info_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Street Pose');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(editedPoseId, 'pose-1');
    expect(editedName, 'Street Pose');
  });

  testWidgets(
    'clothing item info menu shows regenerate state and triggers callback',
    (WidgetTester tester) async {
      String? toggledItemId;
      ClothingRegenerationScope? toggledScope;

      final repo = WardrobeRepository()
        ..setContentPack(
          manifest: buildManifest().copyWith(
            regeneration: const WardrobeRegenerationQueue(
              items: <WardrobeRegenerationRequest>[
                WardrobeRegenerationRequest(
                  category: 'top',
                  itemId: 'top-a',
                  requestedAt: '2026-03-01T10:00:00Z',
                ),
                WardrobeRegenerationRequest(
                  category: 'top',
                  itemId: 'top-b',
                  requestedAt: '2026-03-01T10:01:00Z',
                ),
              ],
            ),
          ),
          packRoot: Directory.systemTemp,
        )
        ..selectCategory('top');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TopSheetGallery(
              repository: repo,
              onToggleClothingRegeneration:
                  ({
                    required String category,
                    required String itemId,
                    required ClothingRegenerationScope scope,
                  }) async {
                    toggledItemId = itemId;
                    toggledScope = scope;
                  },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(MdiIcons.tshirtCrew).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.info_outline).first);
      await tester.pumpAndSettle();
      expect(find.text('Regenerate…'), findsOneWidget);

      await tester.tap(find.text('Regenerate…'));
      await tester.pumpAndSettle();
      expect(find.text('All poses'), findsOneWidget);

      await tester.tap(find.text('All poses'));
      await tester.pumpAndSettle();
      expect(toggledItemId, anyOf('top-a', 'top-b'));
      expect(toggledScope, ClothingRegenerationScope.allPoses);
    },
  );

  testWidgets('deletes pose via info menu after confirmation', (
    WidgetTester tester,
  ) async {
    String? deletedPoseId;

    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: buildManifest().copyWith(
          poses: const <WardrobePose>[
            WardrobePose(id: 'pose-1', name: 'Pose 1', renderReady: true),
          ],
        ),
        packRoot: Directory.systemTemp,
      )
      ..selectCategory('top');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopSheetGallery(
            repository: repo,
            onEditPose:
                ({required String poseId, required String name}) async {},
            onDeletePose: ({required String poseId}) async {
              deletedPoseId = poseId;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Poses'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.info_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete pose?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(deletedPoseId, 'pose-1');
  });

  testWidgets('deletes pending pose via info menu after confirmation', (
    WidgetTester tester,
  ) async {
    String? deletedPoseId;

    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: buildManifest().copyWith(
          poses: const <WardrobePose>[
            WardrobePose(
              id: 'pose-1',
              name: 'Pending pose',
              renderReady: false,
            ),
          ],
        ),
        packRoot: Directory.systemTemp,
      )
      ..selectCategory('top');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopSheetGallery(
            repository: repo,
            onEditPose:
                ({required String poseId, required String name}) async {},
            onDeletePose: ({required String poseId}) async {
              deletedPoseId = poseId;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Poses'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.info_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete pose?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(deletedPoseId, 'pose-1');
  });

  testWidgets('deletes uncategorized pending item via info menu', (
    WidgetTester tester,
  ) async {
    String? deletedCategory;
    String? deletedItemId;

    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: WardrobeManifest.empty().copyWith(
          categories: const <String, List<WardrobeItem>>{
            'headwear': <WardrobeItem>[],
            'top': <WardrobeItem>[],
            'bottom': <WardrobeItem>[],
            'shoes': <WardrobeItem>[],
          },
          intakeQueue: const <WardrobePendingIntakeItem>[
            WardrobePendingIntakeItem(
              id: 'pending-1',
              path: 'items/intake_queue/pending-1/image.png',
              thumbPath: 'items/intake_queue/pending-1/thumb.jpg',
              metaPath: 'items/intake_queue/pending-1/item.yaml',
              createdAt: '2026-02-24T12:00:00Z',
            ),
          ],
        ),
        packRoot: Directory.systemTemp,
      )
      ..selectCategory(WardrobeRepository.uncategorizedIntakeCategory);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopSheetGallery(
            repository: repo,
            onDeleteClothingItem:
                ({required String category, required String itemId}) async {
                  deletedCategory = category;
                  deletedItemId = itemId;
                },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.question_mark_rounded).first);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.info_outline).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete clothing item?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(deletedCategory, WardrobeRepository.uncategorizedIntakeCategory);
    expect(deletedItemId, 'pending-1');
  });

  testWidgets('shows blocked swipe hint when no filtered matches exist', (
    WidgetTester tester,
  ) async {
    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: buildManifest(),
        packRoot: Directory.systemTemp,
      )
      ..selectCategory('top');
    repo.toggleGlobalFilterValue(WardrobeGlobalFilterField.color, 'pink');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TopSheetGallery(repository: repo)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(
      find.byType(TopSheetGallery),
      const Offset(-500, 0),
      1200,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('No items match active filters.'), findsOneWidget);
    expect(find.text('Clear filters'), findsOneWidget);
  });

  testWidgets(
    'hides blocked swipe hint when filters are cleared from summary',
    (WidgetTester tester) async {
      final repo = WardrobeRepository()
        ..setContentPack(
          manifest: buildManifest(),
          packRoot: Directory.systemTemp,
        )
        ..selectCategory('top');
      repo.toggleGlobalFilterValue(WardrobeGlobalFilterField.color, 'pink');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TopSheetGallery(repository: repo)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.fling(
        find.byType(TopSheetGallery),
        const Offset(-500, 0),
        1200,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('No items match active filters.'), findsOneWidget);

      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();

      expect(repo.hasActiveFilters, isFalse);
      expect(find.text('No items match active filters.'), findsNothing);
    },
  );

  testWidgets('auto-dismisses blocked swipe hint quickly', (
    WidgetTester tester,
  ) async {
    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: buildManifest(),
        packRoot: Directory.systemTemp,
      )
      ..selectCategory('top');
    repo.toggleGlobalFilterValue(WardrobeGlobalFilterField.color, 'pink');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TopSheetGallery(repository: repo)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(
      find.byType(TopSheetGallery),
      const Offset(-500, 0),
      1200,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No items match active filters.'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2500));
    await tester.pumpAndSettle();

    expect(find.text('No items match active filters.'), findsNothing);
  });

  testWidgets('updates pending selection after selecting a different item', (
    WidgetTester tester,
  ) async {
    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: buildManifest(),
        packRoot: Directory.systemTemp,
      )
      ..selectCategory('top');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TopSheetGallery(repository: repo)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(MdiIcons.tshirtCrew).first);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Top B').first);
    await tester.pump();

    expect(repo.pendingSelectionFor('top'), 'top-b');
  });

  testWidgets(
    'headwear and shoes toggle off by tapping selected item without a none tile',
    (WidgetTester tester) async {
      final repo = WardrobeRepository()
        ..setContentPack(
          manifest: buildOptionalClothesManifest(),
          packRoot: Directory.systemTemp,
        )
        ..selectCategory('headwear');
      final headwearLabel = repo
          .itemsForCategory('headwear')
          .firstWhere((GalleryItem item) => item.id == 'beanie')
          .label;
      final shoesLabel = repo
          .itemsForCategory('shoes')
          .firstWhere((GalleryItem item) => item.id == 'sneaker-red')
          .label;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TopSheetGallery(repository: repo)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(MdiIcons.hatFedora).first);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('None'), findsNothing);

      await tester.tap(find.bySemanticsLabel(headwearLabel).first);
      await tester.pump();
      expect(repo.pendingSelectionFor('headwear'), 'beanie');

      await tester.tap(find.bySemanticsLabel(headwearLabel).first);
      await tester.pump();
      expect(repo.pendingSelectionFor('headwear'), isNull);

      await tester.tap(find.byIcon(MdiIcons.shoeSneaker).first);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('None'), findsNothing);

      await tester.tap(find.bySemanticsLabel(shoesLabel).first);
      await tester.pump();
      expect(repo.pendingSelectionFor('shoes'), 'sneaker-red');

      await tester.tap(find.bySemanticsLabel(shoesLabel).first);
      await tester.pump();
      expect(repo.pendingSelectionFor('shoes'), isNull);
    },
  );

  testWidgets('jumps to offscreen category when rail icon is tapped', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: buildLongManifest(),
        packRoot: Directory.systemTemp,
      )
      ..selectCategory('top');
    final bottomLabel = repo
        .itemsForCategory('bottom')
        .firstWhere((GalleryItem item) => item.id == 'bottom-target')
        .label;
    final bottomSectionLabel = repo
        .clothesSections()
        .firstWhere((ClothesNavSection section) => section.category == 'bottom')
        .displayLabel;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TopSheetGallery(repository: repo)),
      ),
    );
    await tester.pumpAndSettle();

    final bottomItemFinder = find.bySemanticsLabel(bottomLabel);

    expect(isVisibleInClothesViewport(tester, bottomItemFinder), isFalse);
    expect(find.byType(PantsIcon), findsWidgets);

    await tester.tap(find.byType(PantsIcon).first);
    await tester.pumpAndSettle();
    expect(isVisibleInClothesViewport(tester, bottomItemFinder), isTrue);
    expectNearClothesViewportTop(
      tester,
      find.descendant(
        of: find.byKey(const Key('top-sheet-clothes-viewport')),
        matching: find.text(bottomSectionLabel),
      ),
      maxDelta: 28,
    );

    await tester.tap(find.byIcon(MdiIcons.hatFedora).first);
    await tester.pumpAndSettle();

    expect(isVisibleInClothesViewport(tester, bottomItemFinder), isFalse);
  });

  testWidgets(
    'does not snap back to the top when a mid-list rail target starts offscreen',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = WardrobeRepository()
        ..setContentPack(
          manifest: buildUnevenSectionsManifest(),
          packRoot: Directory.systemTemp,
        )
        ..selectCategory('top');
      final bottomLabel = repo
          .itemsForCategory('bottom')
          .firstWhere((GalleryItem item) => item.id == 'bottom-target')
          .label;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TopSheetGallery(repository: repo)),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        isVisibleInClothesViewport(tester, find.bySemanticsLabel(bottomLabel)),
        isFalse,
      );

      await tester.tap(find.byType(PantsIcon).first);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 150));

      expect(
        isVisibleInClothesViewport(tester, find.bySemanticsLabel(bottomLabel)),
        isTrue,
      );
    },
  );

  testWidgets(
    'jumps to an offscreen rail target even while filters are active',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = WardrobeRepository()
        ..setContentPack(
          manifest: buildUnevenSectionsManifest(),
          packRoot: Directory.systemTemp,
        )
        ..selectCategory('top');
      repo.toggleGlobalFilterValue(WardrobeGlobalFilterField.color, 'black');
      final bottomLabel = repo
          .itemsForCategory('bottom')
          .firstWhere((GalleryItem item) => item.id == 'bottom-target')
          .label;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TopSheetGallery(repository: repo)),
        ),
      );
      await tester.pumpAndSettle();

      expect(repo.hasActiveFilters, isTrue);
      expect(find.text('Color: black'), findsOneWidget);
      expect(
        isVisibleInClothesViewport(tester, find.bySemanticsLabel(bottomLabel)),
        isFalse,
      );

      await tester.tap(find.byType(PantsIcon).first);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 150));

      expect(
        isVisibleInClothesViewport(tester, find.bySemanticsLabel(bottomLabel)),
        isTrue,
      );
    },
  );

  testWidgets(
    'subcategory rail dots align their target section beneath the clothes viewport',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = WardrobeRepository()
        ..setContentPack(
          manifest: buildLongManifest(),
          packRoot: Directory.systemTemp,
        )
        ..selectCategory('top');
      final topRailNode = repo.clothesRailNodes().firstWhere(
        (ClothesRailNode node) => node.category == 'top',
      );
      final targetSubcategory = topRailNode.subcategories[2];
      final targetSectionLabel = repo
          .clothesSections()
          .firstWhere(
            (ClothesNavSection section) =>
                section.key == targetSubcategory.sectionKey,
          )
          .displayLabel;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TopSheetGallery(repository: repo)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.byType(TopSheetGallery), const Offset(0, -120));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byTooltip('Jump to Top / ${targetSubcategory.label}'),
      );
      await tester.pumpAndSettle();

      expectNearClothesViewportTop(
        tester,
        find.descendant(
          of: find.byKey(const Key('top-sheet-clothes-viewport')),
          matching: find.text(targetSectionLabel),
        ),
        maxDelta: 28,
      );
    },
  );

  testWidgets(
    'restores the focused clothes section when the sheet is reopened',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = WardrobeRepository()
        ..setContentPack(
          manifest: buildUnevenSectionsManifest(),
          packRoot: Directory.systemTemp,
        );
      var viewState = TopSheetGalleryViewState.initial;

      Future<void> pumpGallery() {
        return tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TopSheetGallery(
                repository: repo,
                initialViewState: viewState,
                onViewStateChanged: (TopSheetGalleryViewState nextViewState) {
                  viewState = nextViewState;
                },
              ),
            ),
          ),
        );
      }

      await pumpGallery();
      await tester.pumpAndSettle();

      await tester.fling(
        find.byType(TopSheetGallery),
        const Offset(0, -1800),
        1600,
      );
      await tester.pumpAndSettle();

      final focusedSectionKey = repo.clothesFocus?.sectionKey;
      expect(focusedSectionKey, isNotNull);
      final focusedSectionLabel = repo
          .clothesSections()
          .firstWhere(
            (ClothesNavSection section) => section.key == focusedSectionKey,
          )
          .displayLabel;

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      await pumpGallery();
      await tester.pumpAndSettle();

      expectNearClothesViewportTop(
        tester,
        find.descendant(
          of: find.byKey(const Key('top-sheet-clothes-viewport')),
          matching: find.text(focusedSectionLabel),
        ),
        maxDelta: 28,
      );
    },
  );

  testWidgets(
    'aligns the viewport with the active category when no scroll offset is saved',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = WardrobeRepository()
        ..setContentPack(
          manifest: buildUnevenSectionsManifest(),
          packRoot: Directory.systemTemp,
        )
        ..selectCategory('top');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TopSheetGallery(repository: repo)),
        ),
      );
      await tester.pumpAndSettle();

      expectNearClothesViewportTop(
        tester,
        find.descendant(
          of: find.byKey(const Key('top-sheet-clothes-viewport')),
          matching: find.text('Top / tee'),
        ),
        maxDelta: 28,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 200));
    },
  );

  testWidgets('aligns the viewport with the repository clothes focus', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: buildUnevenSectionsManifest(),
        packRoot: Directory.systemTemp,
      );
    repo.setClothesFocus(category: 'top', sectionKey: 'top::tee');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TopSheetGallery(repository: repo)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    expectNearClothesViewportTop(
      tester,
      find.descendant(
        of: find.byKey(const Key('top-sheet-clothes-viewport')),
        matching: find.text('Top / tee'),
      ),
      maxDelta: 28,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets(
    'opens on the focused bottom item instead of keeping the headwear section visible',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = WardrobeRepository()
        ..setContentPack(
          manifest: buildUnevenSectionsManifest(),
          packRoot: Directory.systemTemp,
        );
      repo.setClothesFocus(
        category: 'bottom',
        sectionKey: repo.sectionKeyForCategoryItem(
          category: 'bottom',
          itemId: 'bottom-target',
        ),
        itemId: 'bottom-target',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TopSheetGallery(repository: repo)),
        ),
      );
      await tester.pumpAndSettle();
      final bottomItemFinder = find.bySemanticsLabel('Bottom Target');
      final initialItemTop = tester.getTopLeft(bottomItemFinder.first).dy;

      expectNearClothesViewportTop(
        tester,
        find.descendant(
          of: find.byKey(const Key('top-sheet-clothes-viewport')),
          matching: find.text('Bottom / jeans'),
        ),
        maxDelta: 28,
      );
      expect(isVisibleInClothesViewport(tester, bottomItemFinder), isTrue);
      expectInUpperHalfOfClothesViewport(tester, bottomItemFinder);

      await tester.pump(const Duration(milliseconds: 400));
      expect(
        (tester.getTopLeft(bottomItemFinder.first).dy - initialItemTop).abs(),
        lessThanOrEqualTo(1),
      );
    },
  );

  testWidgets('shows an overflow badge and jumps to hidden subcategories', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: buildLongManifest(),
        packRoot: Directory.systemTemp,
      )
      ..selectCategory('top');
    final hiddenSubcategory = repo
        .clothesRailNodes()
        .firstWhere((ClothesRailNode node) => node.category == 'top')
        .subcategories[3];
    final targetSectionLabel = repo
        .clothesSections()
        .firstWhere(
          (ClothesNavSection section) =>
              section.key == hiddenSubcategory.sectionKey,
        )
        .displayLabel;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TopSheetGallery(repository: repo)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('rail-overflow-top')), findsOneWidget);
    expect(find.text('+15'), findsOneWidget);

    await tester.tap(find.byKey(const Key('rail-overflow-top')));
    await tester.pumpAndSettle();

    expect(find.text(hiddenSubcategory.label), findsOneWidget);

    await tester.tap(find.text(hiddenSubcategory.label));
    await tester.pumpAndSettle();

    expectNearClothesViewportTop(
      tester,
      find.descendant(
        of: find.byKey(const Key('top-sheet-clothes-viewport')),
        matching: find.text(targetSectionLabel),
      ),
      maxDelta: 28,
    );
    expect(repo.clothesFocus?.sectionKey, hiddenSubcategory.sectionKey);
  });

  testWidgets(
    'marks the overflow badge active when a hidden section is focused',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = WardrobeRepository()
        ..setContentPack(
          manifest: buildLongManifest(),
          packRoot: Directory.systemTemp,
        );
      repo.setClothesFocus(category: 'top', sectionKey: 'top::type-4');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TopSheetGallery(repository: repo)),
        ),
      );
      await tester.pumpAndSettle();

      final badgeText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('rail-overflow-top')),
          matching: find.text('+15'),
        ),
      );
      expect(badgeText.style?.color, isNot(equals(Colors.grey.shade700)));
    },
  );
}
