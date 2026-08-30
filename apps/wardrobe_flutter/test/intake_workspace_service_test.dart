import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:wardrobe_flutter/models/wardrobe.dart';
import 'package:wardrobe_flutter/services/content_pack_service.dart';
import 'package:wardrobe_flutter/services/intake_workspace_service.dart';
import 'package:wardrobe_flutter/services/wardrobe_repository.dart';

void main() {
  test(
    'saving clothing on top of builtin pack keeps default renders',
    () async {
      final zipFile = File('assets/builtin_pack/wardrobe_pack.zip');
      expect(zipFile.existsSync(), isTrue, reason: 'Expected built-in ZIP');

      final tempRoot = await Directory.systemTemp.createTemp(
        'wardrobe_intake_test_',
      );
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final contentPackService = ContentPackService(
        appDirectoryProvider: () async => tempRoot,
      );

      final importResult = await contentPackService.importZip(zipFile);
      expect(importResult.success, isTrue, reason: importResult.message);
      expect(importResult.manifest, isNotNull);
      expect(importResult.manifest!.schemaVersion, 5);
      expect(importResult.manifest!.renders, isNotEmpty);

      final intakeService = IntakeWorkspaceService(contentPackService);

      final source = img.Image(width: 12, height: 12);
      img.fill(source, color: img.ColorRgb8(200, 12, 24));
      final imageBytes = Uint8List.fromList(img.encodePng(source));

      final updated = await intakeService.saveClothingSelection(
        imageBytes: imageBytes,
        selection: const RectSelection(left: 0, top: 0, width: 1, height: 1),
      );

      expect(updated.schemaVersion, 5);
      expect(updated.renders, isNotEmpty);
      expect(updated.intakeQueue, isNotEmpty);
      expect(updated.intakeQueue.single.path, contains('items/intake_queue/'));
    },
  );

  test('loads unique sorted tag suggestions from existing items', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'wardrobe_intake_test_',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final contentPackService = ContentPackService(
      appDirectoryProvider: () async => tempRoot,
    );
    final intakeService = IntakeWorkspaceService(contentPackService);

    final manifest = WardrobeManifest.empty().copyWith(
      categories: const <String, List<WardrobeItem>>{
        'headwear': <WardrobeItem>[
          WardrobeItem(
            id: 'cap-1',
            category: 'headwear',
            subcategory: 'Beanie',
            colorPrimary: 'Black',
            tags: <String>['winter', 'Cozy'],
            renderReady: false,
          ),
        ],
        'top': <WardrobeItem>[
          WardrobeItem(
            id: 'hoodie-1',
            category: 'top',
            subcategory: 'Hoodie',
            colorPrimary: 'brown',
            tags: <String>['casual', 'winter'],
            renderReady: false,
          ),
          WardrobeItem(
            id: 'hoodie-2',
            category: 'top',
            subcategory: 'hoodie',
            colorPrimary: 'Black',
            tags: <String>['Casual', ''],
            renderReady: false,
          ),
        ],
        'bottom': <WardrobeItem>[],
        'shoes': <WardrobeItem>[
          WardrobeItem(
            id: 'shoe-1',
            category: 'shoes',
            colorPrimary: '  ',
            tags: <String>['sport'],
            renderReady: false,
          ),
        ],
      },
    );
    await contentPackService.saveActiveManifest(manifest);

    final suggestions = await intakeService.loadTagSuggestions();

    expect(suggestions.subcategories, <String>['Beanie', 'Hoodie']);
    expect(suggestions.subcategoriesByCategory['headwear'], <String>['Beanie']);
    expect(suggestions.subcategoriesByCategory['top'], <String>['Hoodie']);
    expect(suggestions.subcategoriesByCategory['shoes'], isEmpty);
    expect(suggestions.subcategoriesForCategory('top'), <String>['Hoodie']);
    expect(suggestions.subcategoriesForCategory('headwear'), <String>[
      'Beanie',
    ]);
    expect(suggestions.colors, <String>['Black', 'brown']);
    expect(suggestions.materials, isEmpty);
    expect(suggestions.styles, isEmpty);
    expect(suggestions.patterns, isEmpty);
    expect(suggestions.tags, <String>['casual', 'Cozy', 'sport', 'winter']);
  });

  test(
    'loads editable item metadata with absolute preview image path',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'wardrobe_preview_test_',
      );
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final contentPackService = ContentPackService(
        appDirectoryProvider: () async => tempRoot,
      );
      final intakeService = IntakeWorkspaceService(contentPackService);
      final active = await contentPackService.ensureActiveWorkspace();

      final imageFile = contentPackService.resolveAssetFile(
        active.root,
        'items/top/preview-item/image.png',
      );
      await imageFile.parent.create(recursive: true);
      await imageFile.writeAsBytes(_tinyPng(), flush: true);

      final manifest = WardrobeManifest.empty().copyWith(
        categories: const <String, List<WardrobeItem>>{
          'headwear': <WardrobeItem>[],
          'top': <WardrobeItem>[
            WardrobeItem(
              id: 'preview-item',
              category: 'top',
              name: 'Preview Item',
              path: 'items/top/preview-item/image.png',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'bottom': <WardrobeItem>[],
          'shoes': <WardrobeItem>[],
        },
      );
      await contentPackService.saveActiveManifest(manifest);

      final metadata = await intakeService.loadEditableItemMetadata(
        category: 'top',
        itemId: 'preview-item',
      );

      expect(metadata.previewImagePath, imageFile.path);
    },
  );

  test(
    'falls back to thumbnail for editable item preview image path',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'wardrobe_preview_test_',
      );
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final contentPackService = ContentPackService(
        appDirectoryProvider: () async => tempRoot,
      );
      final intakeService = IntakeWorkspaceService(contentPackService);
      final active = await contentPackService.ensureActiveWorkspace();

      final thumbFile = contentPackService.resolveAssetFile(
        active.root,
        'items/top/thumb-only/thumb.png',
      );
      await thumbFile.parent.create(recursive: true);
      await thumbFile.writeAsBytes(_tinyPng(), flush: true);

      final manifest = WardrobeManifest.empty().copyWith(
        categories: const <String, List<WardrobeItem>>{
          'headwear': <WardrobeItem>[],
          'top': <WardrobeItem>[
            WardrobeItem(
              id: 'thumb-only',
              category: 'top',
              name: 'Thumb Only',
              thumbPath: 'items/top/thumb-only/thumb.png',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'bottom': <WardrobeItem>[],
          'shoes': <WardrobeItem>[],
        },
      );
      await contentPackService.saveActiveManifest(manifest);

      final metadata = await intakeService.loadEditableItemMetadata(
        category: 'top',
        itemId: 'thumb-only',
      );

      expect(metadata.previewImagePath, thumbFile.path);
    },
  );

  test('returns null preview image path when no image is available', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'wardrobe_preview_test_',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final contentPackService = ContentPackService(
      appDirectoryProvider: () async => tempRoot,
    );
    final intakeService = IntakeWorkspaceService(contentPackService);

    final manifest = WardrobeManifest.empty().copyWith(
      categories: const <String, List<WardrobeItem>>{
        'headwear': <WardrobeItem>[],
        'top': <WardrobeItem>[
          WardrobeItem(
            id: 'no-preview',
            category: 'top',
            name: 'No Preview',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'bottom': <WardrobeItem>[],
        'shoes': <WardrobeItem>[],
      },
    );
    await contentPackService.saveActiveManifest(manifest);

    final metadata = await intakeService.loadEditableItemMetadata(
      category: 'top',
      itemId: 'no-preview',
    );

    expect(metadata.previewImagePath, isNull);
  });

  test('updates metadata in-place without category change', () async {
    final zipFile = File('assets/builtin_pack/wardrobe_pack.zip');
    expect(zipFile.existsSync(), isTrue, reason: 'Expected built-in ZIP');

    final tempRoot = await Directory.systemTemp.createTemp(
      'wardrobe_update_test_',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final contentPackService = ContentPackService(
      appDirectoryProvider: () async => tempRoot,
    );
    final importResult = await contentPackService.importZip(zipFile);
    expect(importResult.success, isTrue, reason: importResult.message);

    final intakeService = IntakeWorkspaceService(contentPackService);
    final manifest = importResult.manifest!;
    final itemId = manifest.itemsForCategory('top').first.id;

    final result = await intakeService.updateClothingItemMetadataWithResult(
      UpdateWardrobeItemRequest(
        currentCategory: 'top',
        itemId: itemId,
        metadata: const EditableWardrobeItemMetadata(
          name: 'Updated Top',
          category: 'top',
          subcategory: 't-shirt',
          colorPrimary: 'white',
          material: 'linen',
          styleOccasion: 'casual',
          patternDesign: 'solid',
          tags: <String>['summer', 'new'],
        ),
      ),
    );

    expect(result.categoryChanged, isFalse);
    final updated = result.manifest
        .itemsForCategory('top')
        .where((WardrobeItem item) => item.id == itemId)
        .firstOrNull;
    expect(updated, isNotNull);
    final updatedItem = updated!;
    expect(updatedItem.name, 'Updated Top');
    expect(updatedItem.material, 'linen');
    expect(updatedItem.tags, <String>['new', 'summer']);
  });

  test(
    'category change invalidates dependent renders and moves files',
    () async {
      final zipFile = File('assets/builtin_pack/wardrobe_pack.zip');
      expect(zipFile.existsSync(), isTrue, reason: 'Expected built-in ZIP');

      final tempRoot = await Directory.systemTemp.createTemp(
        'wardrobe_update_test_',
      );
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final contentPackService = ContentPackService(
        appDirectoryProvider: () async => tempRoot,
      );
      final importResult = await contentPackService.importZip(zipFile);
      expect(importResult.success, isTrue, reason: importResult.message);
      final intakeService = IntakeWorkspaceService(contentPackService);

      final manifest = importResult.manifest!;
      final topId = manifest.itemsForCategory('top').first.id;
      final dependentRenders = manifest.renders
          .where((WardrobeRender render) => render.topId == topId)
          .length;
      expect(dependentRenders, greaterThan(0));

      final result = await intakeService.updateClothingItemMetadataWithResult(
        UpdateWardrobeItemRequest(
          currentCategory: 'top',
          itemId: topId,
          metadata: const EditableWardrobeItemMetadata(
            name: 'Moved Item',
            category: 'headwear',
            subcategory: 'beanie',
            colorPrimary: 'gray',
            material: 'wool',
            styleOccasion: 'casual',
            patternDesign: 'solid',
            tags: <String>['winter'],
          ),
        ),
      );

      expect(result.categoryChanged, isTrue);
      expect(result.invalidatedAssetsCount, greaterThan(0));
      expect(
        result.manifest.renders.any(
          (WardrobeRender render) => render.topId == topId,
        ),
        isFalse,
      );
      expect(
        result.manifest
            .itemsForCategory('top')
            .any((WardrobeItem item) => item.id == topId),
        isFalse,
      );
      expect(
        result.manifest
            .itemsForCategory('headwear')
            .any((WardrobeItem item) => item.id == result.nextItemId),
        isTrue,
      );
      final movedItem = result.manifest
          .itemsForCategory('headwear')
          .where((WardrobeItem item) => item.id == result.nextItemId)
          .firstOrNull;
      expect(movedItem, isNotNull);
      expect(movedItem!.name, 'Moved Item');
    },
  );

  test('category change resolves id collisions with suffix', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'wardrobe_update_test_',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final contentPackService = ContentPackService(
      appDirectoryProvider: () async => tempRoot,
    );
    final active = await contentPackService.ensureActiveWorkspace();

    final topImage = contentPackService.resolveAssetFile(
      active.root,
      'items/top/shared/image.png',
    );
    final topThumb = contentPackService.resolveAssetFile(
      active.root,
      'items/top/shared/thumb.jpg',
    );
    final topMeta = contentPackService.resolveAssetFile(
      active.root,
      'items/top/shared/item.yaml',
    );
    await topImage.parent.create(recursive: true);
    await topImage.writeAsBytes(_tinyPng(), flush: true);
    await topThumb.writeAsBytes(_tinyPng(), flush: true);
    await topMeta.writeAsString('{}', flush: true);

    final existingHeadwearImage = contentPackService.resolveAssetFile(
      active.root,
      'items/headwear/shared/image.png',
    );
    final existingHeadwearThumb = contentPackService.resolveAssetFile(
      active.root,
      'items/headwear/shared/thumb.jpg',
    );
    final existingHeadwearMeta = contentPackService.resolveAssetFile(
      active.root,
      'items/headwear/shared/item.yaml',
    );
    await existingHeadwearImage.parent.create(recursive: true);
    await existingHeadwearImage.writeAsBytes(_tinyPng(), flush: true);
    await existingHeadwearThumb.writeAsBytes(_tinyPng(), flush: true);
    await existingHeadwearMeta.writeAsString('{}', flush: true);

    final manifest = WardrobeManifest.empty().copyWith(
      categories: const <String, List<WardrobeItem>>{
        'headwear': <WardrobeItem>[
          WardrobeItem(
            id: 'shared',
            category: 'headwear',
            path: 'items/headwear/shared/image.png',
            thumbPath: 'items/headwear/shared/thumb.jpg',
            metaPath: 'items/headwear/shared/item.yaml',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'top': <WardrobeItem>[
          WardrobeItem(
            id: 'shared',
            category: 'top',
            path: 'items/top/shared/image.png',
            thumbPath: 'items/top/shared/thumb.jpg',
            metaPath: 'items/top/shared/item.yaml',
            tags: <String>[],
            renderReady: true,
          ),
        ],
        'bottom': <WardrobeItem>[],
        'shoes': <WardrobeItem>[],
      },
    );
    await contentPackService.saveActiveManifest(manifest);

    final intakeService = IntakeWorkspaceService(contentPackService);
    final result = await intakeService.updateClothingItemMetadataWithResult(
      const UpdateWardrobeItemRequest(
        currentCategory: 'top',
        itemId: 'shared',
        metadata: EditableWardrobeItemMetadata(
          name: 'Collision Move',
          category: 'headwear',
          subcategory: 'cap',
          colorPrimary: 'black',
          material: 'cotton',
          styleOccasion: 'casual',
          patternDesign: 'solid',
          tags: <String>['tag'],
        ),
      ),
    );

    expect(result.nextItemId, 'shared-2');
    final movedImage = contentPackService.resolveAssetFile(
      active.root,
      'items/headwear/shared-2/image.png',
    );
    expect(await movedImage.exists(), isTrue);
  });

  test('updates pose name in manifest and pose metadata file', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'wardrobe_pose_update_test_',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final contentPackService = ContentPackService(
      appDirectoryProvider: () async => tempRoot,
    );
    final intakeService = IntakeWorkspaceService(contentPackService);

    final source = img.Image(width: 16, height: 16);
    img.fill(source, color: img.ColorRgb8(42, 120, 210));
    final imageBytes = Uint8List.fromList(img.encodePng(source));

    final saved = await intakeService.savePoseSelection(
      imageBytes: imageBytes,
      selection: null,
      markers: const IntakePoseMarkers(neckY: 0.3, ankleY: 0.85),
    );
    final poseId = saved.poses.single.id;

    final updated = await intakeService.updatePoseName(
      poseId: poseId,
      name: 'Front Pose',
    );
    final updatedPose = updated.poses
        .where((WardrobePose pose) => pose.id == poseId)
        .firstOrNull;
    expect(updatedPose, isNotNull);
    expect(updatedPose!.name, 'Front Pose');

    final active = await contentPackService.ensureActiveWorkspace();
    final poseMetaFile = contentPackService.resolveAssetFile(
      active.root,
      'poses/$poseId/pose.yaml',
    );
    expect(await poseMetaFile.exists(), isTrue);
    final decoded = jsonDecode(await poseMetaFile.readAsString()) as Map;
    expect(decoded['name'], 'Front Pose');
    expect(decoded['id'], poseId);
  });

  test('deletes pending intake item and removes its files', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'wardrobe_pending_delete_test_',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final contentPackService = ContentPackService(
      appDirectoryProvider: () async => tempRoot,
    );
    final intakeService = IntakeWorkspaceService(contentPackService);
    final active = await contentPackService.ensureActiveWorkspace();

    const imagePath = 'items/intake_queue/pending-1/image.png';
    const thumbPath = 'items/intake_queue/pending-1/thumb.jpg';
    const metaPath = 'items/intake_queue/pending-1/item.yaml';

    final imageFile = contentPackService.resolveAssetFile(
      active.root,
      imagePath,
    );
    final thumbFile = contentPackService.resolveAssetFile(
      active.root,
      thumbPath,
    );
    final metaFile = contentPackService.resolveAssetFile(active.root, metaPath);
    await imageFile.parent.create(recursive: true);
    await imageFile.writeAsBytes(_tinyPng(), flush: true);
    await thumbFile.writeAsBytes(_tinyPng(), flush: true);
    await metaFile.writeAsString('{}', flush: true);

    await contentPackService.saveActiveManifest(
      WardrobeManifest.empty().copyWith(
        categories: const <String, List<WardrobeItem>>{
          'headwear': <WardrobeItem>[],
          'top': <WardrobeItem>[],
          'bottom': <WardrobeItem>[],
          'shoes': <WardrobeItem>[],
        },
        intakeQueue: const <WardrobePendingIntakeItem>[
          WardrobePendingIntakeItem(
            id: 'pending-1',
            path: imagePath,
            thumbPath: thumbPath,
            metaPath: metaPath,
            createdAt: '2026-02-24T12:00:00Z',
          ),
        ],
      ),
    );

    final updated = await intakeService.deletePendingIntakeItem(
      itemId: 'pending-1',
    );

    expect(updated.intakeQueue, isEmpty);
    expect(await imageFile.exists(), isFalse);
    expect(await thumbFile.exists(), isFalse);
    expect(await metaFile.exists(), isFalse);
  });

  test('deletes pose and dependent rendered assets', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'wardrobe_pose_delete_test_',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final contentPackService = ContentPackService(
      appDirectoryProvider: () async => tempRoot,
    );
    final intakeService = IntakeWorkspaceService(contentPackService);
    final active = await contentPackService.ensureActiveWorkspace();

    const posePath = 'poses/pose-1/pose.png';
    const poseThumbPath = 'poses/pose-1/thumb.jpg';
    const poseMetaPath = 'poses/pose-1/pose.yaml';
    const renderPath = 'renders/pose-1/top-1__bottom-1.png';
    const renderMetaPath = 'renders/pose-1/top-1__bottom-1.json';
    const overlayPath = 'overlays/pose-1/headwear/hat-1.png';
    const overlayMetaPath = 'overlays/pose-1/headwear/hat-1.json';

    final files = <File>[
      contentPackService.resolveAssetFile(active.root, posePath),
      contentPackService.resolveAssetFile(active.root, poseThumbPath),
      contentPackService.resolveAssetFile(active.root, poseMetaPath),
      contentPackService.resolveAssetFile(active.root, renderPath),
      contentPackService.resolveAssetFile(active.root, renderMetaPath),
      contentPackService.resolveAssetFile(active.root, overlayPath),
      contentPackService.resolveAssetFile(active.root, overlayMetaPath),
    ];
    for (final file in files) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(_tinyPng(), flush: true);
    }

    await contentPackService.saveActiveManifest(
      WardrobeManifest.empty().copyWith(
        poses: const <WardrobePose>[
          WardrobePose(
            id: 'pose-1',
            name: 'Pose 1',
            path: posePath,
            thumbPath: poseThumbPath,
            metaPath: poseMetaPath,
            renderReady: true,
          ),
        ],
        categories: const <String, List<WardrobeItem>>{
          'headwear': <WardrobeItem>[
            WardrobeItem(
              id: 'hat-1',
              category: 'headwear',
              path: 'items/headwear/hat-1/image.png',
              thumbPath: 'items/headwear/hat-1/thumb.jpg',
              metaPath: 'items/headwear/hat-1/item.yaml',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'top': <WardrobeItem>[
            WardrobeItem(
              id: 'top-1',
              category: 'top',
              path: 'items/top/top-1/image.png',
              thumbPath: 'items/top/top-1/thumb.jpg',
              metaPath: 'items/top/top-1/item.yaml',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'bottom': <WardrobeItem>[
            WardrobeItem(
              id: 'bottom-1',
              category: 'bottom',
              path: 'items/bottom/bottom-1/image.png',
              thumbPath: 'items/bottom/bottom-1/thumb.jpg',
              metaPath: 'items/bottom/bottom-1/item.yaml',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'shoes': <WardrobeItem>[],
        },
        renders: const <WardrobeRender>[
          WardrobeRender(
            poseId: 'pose-1',
            topId: 'top-1',
            bottomId: 'bottom-1',
            path: renderPath,
            size: <int>[1072, 1936],
            metaPath: renderMetaPath,
          ),
        ],
        overlays: const <WardrobeOverlay>[
          WardrobeOverlay(
            poseId: 'pose-1',
            category: 'headwear',
            itemId: 'hat-1',
            path: overlayPath,
            anchorBox: <double>[0.25, 0.12, 0.5, 0.2],
            metaPath: overlayMetaPath,
          ),
        ],
      ),
    );

    final updated = await intakeService.deletePose(poseId: 'pose-1');

    expect(updated.poses, isEmpty);
    expect(updated.renders, isEmpty);
    expect(updated.overlays, isEmpty);
    for (final file in files) {
      expect(await file.exists(), isFalse);
    }
  });

  test(
    'deleting one pending pose keeps default pack hidden while pending clothes remain',
    () async {
      final zipFile = File('assets/builtin_pack/wardrobe_pack.zip');
      expect(zipFile.existsSync(), isTrue, reason: 'Expected built-in ZIP');

      final tempRoot = await Directory.systemTemp.createTemp(
        'wardrobe_pending_pose_delete_test_',
      );
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final contentPackService = ContentPackService(
        appDirectoryProvider: () async => tempRoot,
      );
      final importResult = await contentPackService.importZip(zipFile);
      expect(importResult.success, isTrue, reason: importResult.message);

      final intakeService = IntakeWorkspaceService(contentPackService);
      final bytes = Uint8List.fromList(_tinyPng());

      final withPendingClothes = await intakeService.saveClothingSelection(
        imageBytes: bytes,
        selection: const RectSelection(left: 0, top: 0, width: 1, height: 1),
      );
      expect(withPendingClothes.intakeQueue, isNotEmpty);

      final withFirstPose = await intakeService.savePoseSelection(
        imageBytes: bytes,
        selection: null,
        markers: const IntakePoseMarkers(neckY: 0.30, ankleY: 0.85),
      );
      final firstOwnPoseId = withFirstPose.poses.last.id;

      final withSecondPose = await intakeService.savePoseSelection(
        imageBytes: bytes,
        selection: null,
        markers: const IntakePoseMarkers(neckY: 0.30, ankleY: 0.85),
      );
      final secondOwnPoseId = withSecondPose.poses.last.id;
      expect(firstOwnPoseId == secondOwnPoseId, isFalse);

      final afterDelete = await intakeService.deletePose(
        poseId: firstOwnPoseId,
      );
      expect(afterDelete.intakeQueue, isNotEmpty);

      final activePack = await contentPackService.loadActivePack();
      expect(activePack, isNotNull);

      final repo = WardrobeRepository()
        ..setContentPack(
          manifest: afterDelete,
          packRoot: activePack!.root,
          assetPathOverrides: activePack.assetPathOverrides,
        );

      expect(repo.hidesDefaultPackContent, isTrue);
      expect(repo.availablePoses, contains(secondOwnPoseId));
      expect(
        repo.availablePoses.any((String id) => id.startsWith('dummy')),
        isFalse,
      );
    },
  );

  test(
    'after workspace zip re-import, deleting one pending pose still keeps default pack hidden',
    () async {
      final zipFile = File('assets/builtin_pack/wardrobe_pack.zip');
      expect(zipFile.existsSync(), isTrue, reason: 'Expected built-in ZIP');

      final tempRoot = await Directory.systemTemp.createTemp(
        'wardrobe_pending_pose_reimport_test_',
      );
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final contentPackService = ContentPackService(
        appDirectoryProvider: () async => tempRoot,
      );
      final importResult = await contentPackService.importZip(zipFile);
      expect(importResult.success, isTrue, reason: importResult.message);

      final intakeService = IntakeWorkspaceService(contentPackService);
      final bytes = Uint8List.fromList(_tinyPng());

      await intakeService.saveClothingSelection(
        imageBytes: bytes,
        selection: const RectSelection(left: 0, top: 0, width: 1, height: 1),
      );

      final withFirstPose = await intakeService.savePoseSelection(
        imageBytes: bytes,
        selection: null,
        markers: const IntakePoseMarkers(neckY: 0.30, ankleY: 0.85),
      );
      final firstOwnPoseId = withFirstPose.poses.last.id;

      final withSecondPose = await intakeService.savePoseSelection(
        imageBytes: bytes,
        selection: null,
        markers: const IntakePoseMarkers(neckY: 0.30, ankleY: 0.85),
      );
      final secondOwnPoseId = withSecondPose.poses.last.id;
      expect(firstOwnPoseId == secondOwnPoseId, isFalse);

      final workspaceZipBytes = await contentPackService
          .exportActiveWorkspaceZipBytes();
      await contentPackService.clearActivePack();

      final reimport = await contentPackService.importZipBytes(
        workspaceZipBytes,
      );
      expect(reimport.success, isTrue, reason: reimport.message);

      final afterDelete = await intakeService.deletePose(
        poseId: firstOwnPoseId,
      );
      expect(afterDelete.intakeQueue, isNotEmpty);

      final activePack = await contentPackService.loadActivePack();
      expect(activePack, isNotNull);

      final repo = WardrobeRepository()
        ..setContentPack(
          manifest: afterDelete,
          packRoot: activePack!.root,
          assetPathOverrides: activePack.assetPathOverrides,
        );

      expect(repo.hidesDefaultPackContent, isTrue);
      expect(repo.availablePoses, contains(secondOwnPoseId));
      expect(
        repo.availablePoses.any((String id) => id.startsWith('dummy')),
        isFalse,
      );
    },
  );

  test('toggleItemRegeneration adds and removes an item request', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'wardrobe_regenerate_item_test_',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final contentPackService = ContentPackService(
      appDirectoryProvider: () async => tempRoot,
    );
    final intakeService = IntakeWorkspaceService(contentPackService);
    await contentPackService.saveActiveManifest(
      WardrobeManifest.empty().copyWith(
        categories: const <String, List<WardrobeItem>>{
          'headwear': <WardrobeItem>[],
          'top': <WardrobeItem>[
            WardrobeItem(
              id: 'hoodie',
              category: 'top',
              tags: <String>[],
              renderReady: true,
            ),
          ],
          'bottom': <WardrobeItem>[],
          'shoes': <WardrobeItem>[],
        },
      ),
    );

    final queued = await intakeService.toggleItemRegeneration(
      category: 'top',
      itemId: 'hoodie',
    );
    expect(queued.regeneration.items, hasLength(1));
    expect(queued.regeneration.items.single.itemId, 'hoodie');

    final removed = await intakeService.toggleItemRegeneration(
      category: 'top',
      itemId: 'hoodie',
    );
    expect(removed.regeneration.items, isEmpty);
  });

  test(
    'toggle pose, render, and overlay regeneration targets add and remove entries',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'wardrobe_regenerate_outfit_test_',
      );
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final contentPackService = ContentPackService(
        appDirectoryProvider: () async => tempRoot,
      );
      final intakeService = IntakeWorkspaceService(contentPackService);
      await contentPackService.saveActiveManifest(
        WardrobeManifest.empty().copyWith(
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
        ),
      );

      final poseItemQueued = await intakeService.togglePoseItemRegeneration(
        poseId: 'pose-1',
        category: 'top',
        itemId: 'hoodie',
      );
      expect(poseItemQueued.regeneration.targets, hasLength(1));
      expect(
        poseItemQueued.regeneration.targets.single.type,
        WardrobeRegenerationTargetType.poseItem,
      );

      final renderQueued = await intakeService.toggleRenderRegeneration(
        poseId: 'pose-1',
        topId: 'hoodie',
        bottomId: 'jeans',
      );
      expect(renderQueued.regeneration.targets, hasLength(2));
      expect(
        renderQueued.regeneration.targets.any(
          (WardrobeRegenerationTarget target) =>
              target.type == WardrobeRegenerationTargetType.render &&
              target.topId == 'hoodie' &&
              target.bottomId == 'jeans',
        ),
        isTrue,
      );

      final overlayQueued = await intakeService.toggleOverlayRegeneration(
        poseId: 'pose-1',
        category: 'shoes',
        itemId: 'sneakers',
      );
      expect(overlayQueued.regeneration.targets, hasLength(3));
      expect(
        overlayQueued.regeneration.targets.any(
          (WardrobeRegenerationTarget target) =>
              target.type == WardrobeRegenerationTargetType.overlay &&
              target.category == 'shoes' &&
              target.itemId == 'sneakers',
        ),
        isTrue,
      );

      final withoutPoseItem = await intakeService.togglePoseItemRegeneration(
        poseId: 'pose-1',
        category: 'top',
        itemId: 'hoodie',
      );
      expect(withoutPoseItem.regeneration.targets, hasLength(2));

      final withoutRender = await intakeService.toggleRenderRegeneration(
        poseId: 'pose-1',
        topId: 'hoodie',
        bottomId: 'jeans',
      );
      expect(withoutRender.regeneration.targets, hasLength(1));

      final removed = await intakeService.toggleOverlayRegeneration(
        poseId: 'pose-1',
        category: 'shoes',
        itemId: 'sneakers',
      );
      expect(removed.regeneration.targets, isEmpty);
    },
  );
}

List<int> _tinyPng() {
  final source = img.Image(width: 3, height: 3);
  img.fill(source, color: img.ColorRgb8(12, 90, 180));
  return img.encodePng(source);
}
