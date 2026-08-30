import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wardrobe_flutter/models/favorite_outfit.dart';
import 'package:wardrobe_flutter/models/wardrobe.dart';
import 'package:wardrobe_flutter/services/wardrobe_repository.dart';

void main() {
  late WardrobeManifest manifest;
  late Directory packRoot;

  setUp(() {
    final file = File('assets/builtin_pack/wardrobe_pack.zip');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'Expected built-in wardrobe_pack.zip',
    );

    final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
    final manifestEntry = archive.files.firstWhere(
      (ArchiveFile file) => file.name == 'wardrobe.json',
    );
    manifest = WardrobeManifest.fromString(
      utf8.decode(manifestEntry.content as List<int>),
    );
    packRoot = Directory.systemTemp;
  });

  WardrobeManifest buildFilterManifest() {
    return WardrobeManifest.empty().copyWith(
      categories: const <String, List<WardrobeItem>>{
        'headwear': <WardrobeItem>[],
        'top': <WardrobeItem>[
          WardrobeItem(
            id: 'tee-white',
            category: 'top',
            subcategory: 't-shirt',
            colorPrimary: 'white',
            material: 'cotton',
            styleOccasion: 'casual',
            patternDesign: 'solid',
            tags: <String>['summer'],
            renderReady: true,
          ),
          WardrobeItem(
            id: 'tee-gray',
            category: 'top',
            subcategory: 't-shirt',
            colorPrimary: 'gray',
            material: 'wool',
            styleOccasion: 'casual',
            patternDesign: 'graphic',
            tags: <String>['winter'],
            renderReady: true,
          ),
          WardrobeItem(
            id: 'hoodie-gray',
            category: 'top',
            subcategory: 'hoodie',
            colorPrimary: 'gray',
            material: 'cotton',
            styleOccasion: 'street',
            patternDesign: 'solid',
            tags: <String>['winter'],
            renderReady: true,
          ),
          WardrobeItem(
            id: 'tee-blue',
            category: 'top',
            subcategory: 't-shirt',
            colorPrimary: 'blue',
            material: 'cotton',
            styleOccasion: 'sport',
            patternDesign: 'solid',
            tags: <String>['gym'],
            renderReady: true,
          ),
        ],
        'bottom': <WardrobeItem>[
          WardrobeItem(
            id: 'jeans-white',
            category: 'bottom',
            subcategory: 'jeans',
            colorPrimary: 'white',
            material: 'cotton',
            styleOccasion: 'casual',
            patternDesign: 'solid',
            tags: <String>['summer'],
            renderReady: true,
          ),
          WardrobeItem(
            id: 'shorts-black',
            category: 'bottom',
            subcategory: 'shorts',
            colorPrimary: 'black',
            material: 'nylon',
            styleOccasion: 'sport',
            patternDesign: 'solid',
            tags: <String>['gym'],
            renderReady: true,
          ),
        ],
        'shoes': <WardrobeItem>[],
      },
    );
  }

  WardrobeManifest buildTwoPoseFavoritesManifest() {
    return WardrobeManifest.empty().copyWith(
      poses: const <WardrobePose>[
        WardrobePose(id: 'pose-1', name: 'Pose 1', renderReady: true),
        WardrobePose(id: 'pose-2', name: 'Pose 2', renderReady: true),
      ],
      categories: const <String, List<WardrobeItem>>{
        'headwear': <WardrobeItem>[],
        'top': <WardrobeItem>[
          WardrobeItem(
            id: 'top-a',
            category: 'top',
            tags: <String>[],
            renderReady: true,
          ),
          WardrobeItem(
            id: 'top-b',
            category: 'top',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'bottom': <WardrobeItem>[
          WardrobeItem(
            id: 'bottom-a',
            category: 'bottom',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'shoes': <WardrobeItem>[],
      },
      renders: const <WardrobeRender>[
        WardrobeRender(
          poseId: 'pose-1',
          topId: 'top-a',
          bottomId: 'bottom-a',
          path: 'renders/pose-1/top-a__bottom-a.png',
          size: <int>[1080, 1920],
        ),
        WardrobeRender(
          poseId: 'pose-2',
          topId: 'top-a',
          bottomId: 'bottom-a',
          path: 'renders/pose-2/top-a__bottom-a.png',
          size: <int>[1080, 1920],
        ),
      ],
    );
  }

  test('initial defaults pick first top and first bottom', () {
    final repo = WardrobeRepository()
      ..setContentPack(manifest: manifest, packRoot: packRoot);

    final topSelection = repo.committedSelectionFor('top');
    final bottomSelection = repo.committedSelectionFor('bottom');

    expect(topSelection, manifest.categories['top']!.first.id);
    expect(bottomSelection, manifest.categories['bottom']!.first.id);
  });

  test('uses item name as gallery label when available', () {
    final customManifest = WardrobeManifest.empty().copyWith(
      categories: const <String, List<WardrobeItem>>{
        'headwear': <WardrobeItem>[],
        'top': <WardrobeItem>[
          WardrobeItem(
            id: 'top-a',
            name: 'Fancy Top',
            category: 'top',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'bottom': <WardrobeItem>[
          WardrobeItem(
            id: 'bottom-a',
            name: 'Classic Bottom',
            category: 'bottom',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'shoes': <WardrobeItem>[],
      },
    );
    final repo = WardrobeRepository()
      ..setContentPack(manifest: customManifest, packRoot: packRoot);

    final topLabel = repo.itemsForCategory('top').first.label;
    expect(topLabel, 'Fancy Top');
  });

  test('pending selections apply only after applyPendingSelection', () {
    final repo = WardrobeRepository()
      ..setContentPack(manifest: manifest, packRoot: packRoot);

    final secondTop = manifest.categories['top']![1].id;

    repo.beginPendingSelection();
    repo.selectPendingItem('top', secondTop);

    expect(repo.pendingSelectionFor('top'), secondTop);
    expect(repo.committedSelectionFor('top'), isNot(secondTop));

    repo.applyPendingSelection();

    expect(repo.committedSelectionFor('top'), secondTop);
  });

  test('cycling headwear rotates through none and item', () {
    final repo = WardrobeRepository()
      ..setContentPack(manifest: manifest, packRoot: packRoot);

    expect(repo.committedSelectionFor('headwear'), isNull);

    repo.cycleCategory('headwear', 1);
    expect(repo.committedSelectionFor('headwear'), isNotNull);

    repo.cycleCategory('headwear', -1);
    expect(repo.committedSelectionFor('headwear'), isNull);
  });

  test('clearCategorySelection clears optional categories only', () {
    final repo = WardrobeRepository()
      ..setContentPack(manifest: manifest, packRoot: packRoot);

    repo.cycleCategory('headwear', 1);
    expect(repo.committedSelectionFor('headwear'), isNotNull);

    expect(repo.clearCategorySelection('headwear'), isTrue);
    expect(repo.committedSelectionFor('headwear'), isNull);
    expect(repo.pendingSelectionFor('headwear'), isNull);

    final topSelection = repo.committedSelectionFor('top');
    expect(repo.clearCategorySelection('top'), isFalse);
    expect(repo.committedSelectionFor('top'), topSelection);
  });

  test('cycleCategory updates the clothes focus', () {
    final repo = WardrobeRepository()
      ..setContentPack(manifest: manifest, packRoot: packRoot);

    repo.cycleCategory('headwear', 1);

    final focus = repo.clothesFocus;
    expect(focus, isNotNull);
    expect(focus!.category, 'headwear');
    expect(focus.itemId, repo.committedSelectionFor('headwear'));
    expect(
      focus.sectionKey,
      repo.sectionKeyForCategoryItem(
        category: 'headwear',
        itemId: repo.committedSelectionFor('headwear'),
      ),
    );
    expect(repo.activeCategory, 'headwear');
  });

  test('selectPendingItem overwrites the clothes focus', () {
    final repo = WardrobeRepository()
      ..setContentPack(manifest: manifest, packRoot: packRoot);
    final secondTop = manifest.categories['top']![1].id;

    repo.cycleCategory('headwear', 1);

    repo.selectPendingItem('top', secondTop);

    final focus = repo.clothesFocus;
    expect(focus, isNotNull);
    expect(focus!.category, 'top');
    expect(focus.itemId, secondTop);
    expect(
      focus.sectionKey,
      repo.sectionKeyForCategoryItem(category: 'top', itemId: secondTop),
    );
    expect(repo.activeCategory, 'top');
  });

  test(
    'clearCategorySelection clears the focused item but keeps the category',
    () {
      final repo = WardrobeRepository()
        ..setContentPack(manifest: manifest, packRoot: packRoot);

      repo.cycleCategory('headwear', 1);
      expect(repo.clearCategorySelection('headwear'), isTrue);

      final focus = repo.clothesFocus;
      expect(focus, isNotNull);
      expect(focus!.category, 'headwear');
      expect(focus.itemId, isNull);
      expect(focus.sectionKey, repo.firstSectionKeyForCategory('headwear'));
      expect(repo.activeCategory, 'headwear');
    },
  );

  test('current outfit favorite state is derived from pose-agnostic keys', () {
    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: buildTwoPoseFavoritesManifest(),
        packRoot: packRoot,
      );

    final favorite = repo.currentFavoriteDraft();
    expect(favorite, isNotNull);
    expect(repo.isCurrentOutfitFavorited, isFalse);

    repo.setFavorites(<FavoriteOutfit>[favorite!]);

    expect(repo.isCurrentOutfitFavorited, isTrue);
    repo.selectPose('pose-2');
    expect(repo.currentFavoriteDraft()!.key, favorite.key);
    expect(repo.isCurrentOutfitFavorited, isTrue);
    expect(repo.favoriteItems(), isNotEmpty);
  });

  test('selectPendingFavorite restores selection but keeps current pose', () {
    final repo = WardrobeRepository()
      ..setContentPack(
        manifest: buildTwoPoseFavoritesManifest(),
        packRoot: packRoot,
      );

    final favorite = repo.currentFavoriteDraft()!;
    repo.selectPose('pose-2');
    expect(repo.activePoseId, 'pose-2');

    repo.beginPendingSelection();
    repo.selectPendingItem('top', 'top-b');
    expect(repo.pendingSelectionFor('top'), 'top-b');

    repo.setFavorites(<FavoriteOutfit>[favorite]);
    repo.selectPendingFavorite(favorite.key);

    expect(repo.activePoseId, 'pose-2');
    expect(repo.pendingSelectionFor('top'), favorite.selection['top']);
    expect(repo.pendingSelectionFor('bottom'), favorite.selection['bottom']);
  });

  test('setContentPack can preserve the current pose and selection', () {
    final initialManifest = WardrobeManifest.empty().copyWith(
      poses: const <WardrobePose>[
        WardrobePose(id: 'pose-1', name: 'Pose 1', renderReady: true),
        WardrobePose(id: 'pose-2', name: 'Pose 2', renderReady: true),
      ],
      categories: const <String, List<WardrobeItem>>{
        'headwear': <WardrobeItem>[],
        'top': <WardrobeItem>[
          WardrobeItem(
            id: 'top-a',
            category: 'top',
            tags: <String>[],
            renderReady: true,
          ),
          WardrobeItem(
            id: 'top-b',
            category: 'top',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'bottom': <WardrobeItem>[
          WardrobeItem(
            id: 'bottom-a',
            category: 'bottom',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'shoes': <WardrobeItem>[],
      },
      renders: const <WardrobeRender>[
        WardrobeRender(
          poseId: 'pose-1',
          topId: 'top-a',
          bottomId: 'bottom-a',
          path: 'renders/pose-1/top-a__bottom-a.png',
          size: <int>[1080, 1920],
        ),
        WardrobeRender(
          poseId: 'pose-1',
          topId: 'top-b',
          bottomId: 'bottom-a',
          path: 'renders/pose-1/top-b__bottom-a.png',
          size: <int>[1080, 1920],
        ),
        WardrobeRender(
          poseId: 'pose-2',
          topId: 'top-a',
          bottomId: 'bottom-a',
          path: 'renders/pose-2/top-a__bottom-a.png',
          size: <int>[1080, 1920],
        ),
        WardrobeRender(
          poseId: 'pose-2',
          topId: 'top-b',
          bottomId: 'bottom-a',
          path: 'renders/pose-2/top-b__bottom-a.png',
          size: <int>[1080, 1920],
        ),
      ],
    );
    final updatedManifest = initialManifest.copyWith(
      regeneration: const WardrobeRegenerationQueue(
        targets: <WardrobeRegenerationTarget>[
          WardrobeRegenerationTarget.render(
            poseId: 'pose-2',
            topId: 'top-b',
            bottomId: 'bottom-a',
            requestedAt: '2026-03-11T10:00:00Z',
          ),
        ],
      ),
    );

    final repo = WardrobeRepository()
      ..setContentPack(manifest: initialManifest, packRoot: packRoot);

    repo.selectPose('pose-2');
    repo.beginPendingSelection();
    repo.selectPendingItem('top', 'top-b');
    repo.applyPendingSelection();

    repo.setContentPack(
      manifest: updatedManifest,
      packRoot: packRoot,
      preserveCurrentState: true,
    );

    expect(repo.activePoseId, 'pose-2');
    expect(repo.committedSelectionFor('top'), 'top-b');
    expect(repo.committedSelectionFor('bottom'), 'bottom-a');
  });

  test(
    'randomizeOutfit picks a valid render pair and syncs pending selection',
    () {
      final repo = WardrobeRepository()
        ..setContentPack(manifest: manifest, packRoot: packRoot);

      final initialTop = repo.committedSelectionFor('top');
      final initialBottom = repo.committedSelectionFor('bottom');
      final changed = repo.randomizeOutfit(random: Random(42));

      expect(changed, isTrue);

      final top = repo.committedSelectionFor('top');
      final bottom = repo.committedSelectionFor('bottom');
      final activePose = repo.activePoseId;
      expect(activePose, isNotNull);
      final render = manifest.findRender(
        poseId: activePose!,
        topId: top,
        bottomId: bottom,
      );
      expect(render, isNotNull);

      for (final category in manifest.orderedCategories) {
        expect(
          repo.pendingSelectionFor(category),
          repo.committedSelectionFor(category),
        );
      }

      final distinctPairs = manifest.renders
          .where((WardrobeRender render) => render.poseId == activePose)
          .map((WardrobeRender render) => '${render.topId}__${render.bottomId}')
          .toSet();
      if (distinctPairs.length > 1) {
        expect(top == initialTop && bottom == initialBottom, isFalse);
      }
    },
  );

  test('isActivePosePending is true for a non-render-ready active pose', () {
    final pendingPose = manifest.poses.first.copyWith(renderReady: false);
    final pendingManifest = manifest.copyWith(
      poses: <WardrobePose>[pendingPose, ...manifest.poses.skip(1)],
    );
    final repo = WardrobeRepository()
      ..setContentPack(manifest: pendingManifest, packRoot: packRoot);

    expect(repo.isActivePosePending, isTrue);
  });

  test(
    'hides default content when intake queue is non-empty even with id collisions',
    () {
      final collidingId = manifest.itemsForCategory('top').first.id;
      final manifestWithPendingIntake = manifest.copyWith(
        intakeQueue: <WardrobePendingIntakeItem>[
          WardrobePendingIntakeItem(
            id: collidingId,
            path: 'items/intake_queue/$collidingId/image.png',
            thumbPath: 'items/intake_queue/$collidingId/thumb.jpg',
            metaPath: 'items/intake_queue/$collidingId/item.yaml',
            createdAt: '2026-02-24T12:00:00Z',
          ),
        ],
      );
      final repo = WardrobeRepository()
        ..setContentPack(
          manifest: manifestWithPendingIntake,
          packRoot: packRoot,
        );

      expect(repo.hidesDefaultPackContent, isTrue);
    },
  );

  test(
    'clothesSections groups by subcategory and keeps root item section for optional categories',
    () {
      final customManifest = WardrobeManifest.empty().copyWith(
        categories: <String, List<WardrobeItem>>{
          'headwear': <WardrobeItem>[
            const WardrobeItem(
              id: 'beanie',
              category: 'headwear',
              subcategory: 'Beanie',
              tags: <String>[],
              renderReady: true,
            ),
            const WardrobeItem(
              id: 'visor',
              category: 'headwear',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'top': <WardrobeItem>[
            const WardrobeItem(
              id: 'hoodie',
              category: 'top',
              subcategory: 'Hoodie',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'bottom': const <WardrobeItem>[],
          'shoes': const <WardrobeItem>[],
        },
      );
      final repo = WardrobeRepository()
        ..setContentPack(manifest: customManifest, packRoot: packRoot);

      final sections = repo.clothesSections();
      final headwearSections = sections
          .where((ClothesNavSection section) => section.category == 'headwear')
          .toList(growable: false);

      expect(headwearSections, hasLength(2));
      final rootSection = headwearSections.firstWhere(
        (ClothesNavSection section) => section.subcategoryKey == null,
      );
      expect(rootSection.items.any((GalleryItem item) => item.isNone), isFalse);
      expect(
        rootSection.items.map((GalleryItem item) => item.id),
        contains('visor'),
      );
      final beanieSection = headwearSections.firstWhere(
        (ClothesNavSection section) => section.subcategoryKey == 'beanie',
      );
      expect(
        beanieSection.items.map((GalleryItem item) => item.id).toList(),
        contains('beanie'),
      );
    },
  );

  test(
    'cycleCategory follows the same item order shown in wardrobe sections',
    () {
      final customManifest = WardrobeManifest.empty().copyWith(
        categories: <String, List<WardrobeItem>>{
          'headwear': <WardrobeItem>[
            const WardrobeItem(
              id: 'visor',
              category: 'headwear',
              subcategory: 'Zeta',
              tags: <String>[],
              renderReady: true,
            ),
            const WardrobeItem(
              id: 'cap',
              category: 'headwear',
              tags: <String>[],
              renderReady: true,
            ),
            const WardrobeItem(
              id: 'beanie',
              category: 'headwear',
              subcategory: 'Alpha',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'top': <WardrobeItem>[
            const WardrobeItem(
              id: 'tee',
              category: 'top',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'bottom': <WardrobeItem>[
            const WardrobeItem(
              id: 'jeans',
              category: 'bottom',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'shoes': const <WardrobeItem>[],
        },
      );
      final repo = WardrobeRepository()
        ..setContentPack(manifest: customManifest, packRoot: packRoot);

      final displayedHeadwearIds = repo
          .clothesSections()
          .where((ClothesNavSection section) => section.category == 'headwear')
          .expand((ClothesNavSection section) => section.items)
          .where((GalleryItem item) => !item.isNone && !item.isDisabled)
          .map((GalleryItem item) => item.id)
          .whereType<String>()
          .toList(growable: false);

      expect(displayedHeadwearIds, <String>['cap', 'beanie', 'visor']);

      repo.cycleCategory('headwear', 1);
      expect(repo.committedSelectionFor('headwear'), 'cap');

      repo.cycleCategory('headwear', 1);
      expect(repo.committedSelectionFor('headwear'), 'beanie');

      repo.cycleCategory('headwear', 1);
      expect(repo.committedSelectionFor('headwear'), 'visor');
    },
  );

  test(
    'clothesRailNodes keep main categories visible and hide empty subcategory nodes',
    () {
      final customManifest = WardrobeManifest.empty().copyWith(
        categories: <String, List<WardrobeItem>>{
          'headwear': const <WardrobeItem>[],
          'top': <WardrobeItem>[
            const WardrobeItem(
              id: 'tee',
              category: 'top',
              subcategory: 'T-Shirts',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'bottom': const <WardrobeItem>[],
          'shoes': const <WardrobeItem>[],
        },
      );
      final repo = WardrobeRepository()
        ..setContentPack(manifest: customManifest, packRoot: packRoot);

      final nodes = repo.clothesRailNodes();
      expect(
        nodes.map((ClothesRailNode node) => node.category).toSet(),
        containsAll(<String>{'headwear', 'top', 'bottom', 'shoes'}),
      );
      final topNode = nodes.firstWhere(
        (ClothesRailNode node) => node.category == 'top',
      );
      expect(
        topNode.subcategories
            .map((ClothesRailSubcategoryNode node) => node.label)
            .toList(),
        contains('T-Shirts'),
      );
      final headwearNode = nodes.firstWhere(
        (ClothesRailNode node) => node.category == 'headwear',
      );
      expect(headwearNode.subcategories, isEmpty);
    },
  );

  test('global color filter applies to all categories', () {
    final repo = WardrobeRepository()
      ..setContentPack(manifest: buildFilterManifest(), packRoot: packRoot);

    repo.toggleGlobalFilterValue(WardrobeGlobalFilterField.color, 'white');

    final topIds = repo
        .itemsForCategory('top')
        .map((GalleryItem item) => item.id);
    final bottomIds = repo
        .itemsForCategory('bottom')
        .map((GalleryItem item) => item.id);
    expect(topIds, contains('tee-white'));
    expect(topIds, isNot(contains('tee-blue')));
    expect(bottomIds, contains('jeans-white'));
    expect(bottomIds, isNot(contains('shorts-black')));
  });

  test('local type filter only affects its category', () {
    final repo = WardrobeRepository()
      ..setContentPack(manifest: buildFilterManifest(), packRoot: packRoot);

    repo.toggleLocalTypeFilter('top', 't-shirt');

    final topIds = repo
        .itemsForCategory('top')
        .map((GalleryItem item) => item.id);
    final bottomIds = repo
        .itemsForCategory('bottom')
        .map((GalleryItem item) => item.id);
    expect(topIds, isNot(contains('hoodie-gray')));
    expect(topIds, containsAll(<String?>['tee-white', 'tee-gray', 'tee-blue']));
    expect(bottomIds, containsAll(<String?>['jeans-white', 'shorts-black']));
  });

  test('local type facets exclude uncategorized intake category', () {
    final manifestWithIntake = buildFilterManifest().copyWith(
      intakeQueue: const <WardrobePendingIntakeItem>[
        WardrobePendingIntakeItem(
          id: 'pending-1',
          path: 'intake/pending-1.jpg',
          thumbPath: 'intake/pending-1_thumb.jpg',
          metaPath: 'intake/pending-1.json',
          createdAt: '2026-01-01T00:00:00Z',
        ),
      ],
    );
    final repo = WardrobeRepository()
      ..setContentPack(manifest: manifestWithIntake, packRoot: packRoot);

    expect(
      repo.clothesMainCategories,
      contains(WardrobeRepository.uncategorizedIntakeCategory),
    );
    expect(
      repo.filterFacets().localTypesByCategory.keys,
      isNot(contains(WardrobeRepository.uncategorizedIntakeCategory)),
    );

    repo.toggleLocalTypeFilter(
      WardrobeRepository.uncategorizedIntakeCategory,
      'other',
    );
    expect(repo.hasActiveFilters, isFalse);
  });

  test('OR within field and AND across fields', () {
    final repo = WardrobeRepository()
      ..setContentPack(manifest: buildFilterManifest(), packRoot: packRoot);

    repo.toggleGlobalFilterValue(WardrobeGlobalFilterField.color, 'white');
    repo.toggleGlobalFilterValue(WardrobeGlobalFilterField.color, 'gray');
    repo.toggleGlobalFilterValue(WardrobeGlobalFilterField.material, 'cotton');

    final topIds = repo
        .itemsForCategory('top')
        .where((GalleryItem item) => item.id != null)
        .map((GalleryItem item) => item.id!)
        .toList(growable: false);
    expect(topIds, contains('tee-white'));
    expect(topIds, contains('hoodie-gray'));
    expect(topIds, isNot(contains('tee-gray')));
  });

  test('selected non-matching item stays visible as pinned', () {
    final repo = WardrobeRepository()
      ..setContentPack(manifest: buildFilterManifest(), packRoot: packRoot);

    repo.beginPendingSelection();
    repo.selectPendingItem('top', 'tee-blue');
    repo.toggleGlobalFilterValue(WardrobeGlobalFilterField.color, 'white');

    final items = repo.itemsForCategory('top');
    final pinned = items
        .where((GalleryItem item) => item.id == 'tee-blue')
        .firstOrNull;
    expect(pinned, isNotNull);
    expect(pinned!.isPinned, isTrue);
    expect(pinned.isSelected, isTrue);
  });

  test('cycleCategoryFiltered blocks when no matches exist', () {
    final repo = WardrobeRepository()
      ..setContentPack(manifest: buildFilterManifest(), packRoot: packRoot);

    final before = repo.committedSelectionFor('top');
    repo.toggleGlobalFilterValue(WardrobeGlobalFilterField.color, 'pink');
    final result = repo.cycleCategoryFiltered('top', 1);

    expect(result.blockedNoMatches, isTrue);
    expect(repo.committedSelectionFor('top'), before);
  });

  test('multiple local filters can be active in parallel', () {
    final repo = WardrobeRepository()
      ..setContentPack(manifest: buildFilterManifest(), packRoot: packRoot);

    repo.toggleLocalTypeFilter('top', 't-shirt');
    repo.toggleLocalTypeFilter('bottom', 'jeans');

    final topIds = repo
        .itemsForCategory('top')
        .map((GalleryItem item) => item.id);
    final bottomIds = repo
        .itemsForCategory('bottom')
        .map((GalleryItem item) => item.id);
    expect(topIds, isNot(contains('hoodie-gray')));
    expect(bottomIds, contains('jeans-white'));
    expect(bottomIds, isNot(contains('shorts-black')));
  });

  test('style, pattern and tags global filters are applied', () {
    final repo = WardrobeRepository()
      ..setContentPack(manifest: buildFilterManifest(), packRoot: packRoot);

    repo.toggleGlobalFilterValue(WardrobeGlobalFilterField.style, 'casual');
    repo.toggleGlobalFilterValue(WardrobeGlobalFilterField.pattern, 'solid');
    repo.toggleGlobalFilterValue(WardrobeGlobalFilterField.tags, 'summer');

    final topIds = repo
        .itemsForCategory('top')
        .where((GalleryItem item) => item.id != null)
        .map((GalleryItem item) => item.id!)
        .toList(growable: false);
    expect(topIds, <String>['tee-white']);
  });

  test('current outfit state can be restored after manifest reload', () {
    final baseManifest = WardrobeManifest.empty().copyWith(
      poses: const <WardrobePose>[
        WardrobePose(id: 'pose-1', name: 'Pose 1', renderReady: true),
      ],
      categories: const <String, List<WardrobeItem>>{
        'headwear': <WardrobeItem>[
          WardrobeItem(
            id: 'cap',
            category: 'headwear',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'top': <WardrobeItem>[
          WardrobeItem(
            id: 'top-a',
            category: 'top',
            tags: <String>[],
            renderReady: true,
          ),
          WardrobeItem(
            id: 'top-b',
            category: 'top',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'bottom': <WardrobeItem>[
          WardrobeItem(
            id: 'bottom-a',
            category: 'bottom',
            tags: <String>[],
            renderReady: true,
          ),
          WardrobeItem(
            id: 'bottom-b',
            category: 'bottom',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'shoes': <WardrobeItem>[
          WardrobeItem(
            id: 'shoe-a',
            category: 'shoes',
            tags: <String>[],
            renderReady: true,
          ),
        ],
      },
    );

    final repo = WardrobeRepository()
      ..setContentPack(manifest: baseManifest, packRoot: packRoot)
      ..beginPendingSelection()
      ..selectPendingItem('headwear', 'cap')
      ..selectPendingItem('top', 'top-b')
      ..selectPendingItem('bottom', 'bottom-b')
      ..selectPendingItem('shoes', 'shoe-a')
      ..applyPendingSelection();

    final savedState = repo.currentOutfitState();
    expect(savedState, isNotNull);

    final reloadedManifest = baseManifest.copyWith(
      regeneration: const WardrobeRegenerationQueue(
        items: <WardrobeRegenerationRequest>[
          WardrobeRegenerationRequest(
            category: 'top',
            itemId: 'top-a',
            requestedAt: '2026-03-01T10:00:00Z',
          ),
        ],
      ),
    );
    repo.setContentPack(manifest: reloadedManifest, packRoot: packRoot);

    expect(repo.committedSelectionFor('top'), 'top-a');
    expect(repo.committedSelectionFor('bottom'), 'bottom-a');

    final restored = repo.restoreCurrentOutfitState(savedState!);
    expect(restored, isTrue);
    expect(repo.committedSelectionFor('headwear'), 'cap');
    expect(repo.committedSelectionFor('top'), 'top-b');
    expect(repo.committedSelectionFor('bottom'), 'bottom-b');
    expect(repo.committedSelectionFor('shoes'), 'shoe-a');
  });

  test(
    'current outfit regeneration target reflects active selection and queue',
    () {
      final customManifest = WardrobeManifest.empty().copyWith(
        poses: const <WardrobePose>[
          WardrobePose(id: 'pose-1', name: 'Pose 1', renderReady: true),
        ],
        categories: const <String, List<WardrobeItem>>{
          'headwear': <WardrobeItem>[
            WardrobeItem(
              id: 'cap',
              category: 'headwear',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'top': <WardrobeItem>[
            WardrobeItem(
              id: 'hoodie',
              category: 'top',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'bottom': <WardrobeItem>[
            WardrobeItem(
              id: 'jeans',
              category: 'bottom',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'shoes': <WardrobeItem>[
            WardrobeItem(
              id: 'sneakers',
              category: 'shoes',
              tags: <String>[],
              renderReady: true,
            ),
          ],
        },
        regeneration: const WardrobeRegenerationQueue(
          items: <WardrobeRegenerationRequest>[
            WardrobeRegenerationRequest(
              category: 'top',
              itemId: 'hoodie',
              requestedAt: '2026-03-01T10:00:00Z',
            ),
          ],
          targets: <WardrobeRegenerationTarget>[
            WardrobeRegenerationTarget.render(
              poseId: 'pose-1',
              topId: 'hoodie',
              bottomId: 'jeans',
              requestedAt: '2026-03-01T10:05:00Z',
            ),
            WardrobeRegenerationTarget.overlay(
              poseId: 'pose-1',
              category: 'headwear',
              itemId: 'cap',
              requestedAt: '2026-03-01T10:05:00Z',
            ),
            WardrobeRegenerationTarget.overlay(
              poseId: 'pose-1',
              category: 'shoes',
              itemId: 'sneakers',
              requestedAt: '2026-03-01T10:05:00Z',
            ),
          ],
        ),
      );

      final repo = WardrobeRepository()
        ..setContentPack(manifest: customManifest, packRoot: packRoot)
        ..beginPendingSelection()
        ..selectPendingItem('headwear', 'cap')
        ..selectPendingItem('shoes', 'sneakers')
        ..applyPendingSelection();

      final target = repo.currentLookRegenerationBundle();

      expect(target, isNotNull);
      expect(target!.renderTarget.poseId, 'pose-1');
      expect(target.renderTarget.topId, 'hoodie');
      expect(target.renderTarget.bottomId, 'jeans');
      expect(target.headwearTarget!.itemId, 'cap');
      expect(target.shoesTarget!.itemId, 'sneakers');
      expect(repo.isItemQueuedForRegeneration('top', 'hoodie'), isTrue);
      expect(
        repo.currentLookRegenerationState,
        CurrentLookRegenerationState.full,
      );
    },
  );
}
