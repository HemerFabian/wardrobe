import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:wardrobe_flutter/models/favorite_outfit.dart';
import 'package:wardrobe_flutter/models/wardrobe.dart';
import 'package:wardrobe_flutter/services/content_pack_service.dart';
import 'package:wardrobe_flutter/services/favorites_service.dart';

void main() {
  test('imports the built-in wardrobe ZIP and keeps it loadable', () async {
    final zipFile = File('assets/builtin_pack/wardrobe_pack.zip');
    expect(zipFile.existsSync(), isTrue, reason: 'Expected built-in ZIP');

    final tempRoot = await Directory.systemTemp.createTemp(
      'wardrobe_pack_test_',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final service = ContentPackService(
      appDirectoryProvider: () async => tempRoot,
    );
    final result = await service.importZip(zipFile);

    expect(result.success, isTrue, reason: result.message);
    expect(result.manifest, isNotNull);
    expect(result.packRoot, isNotNull);

    final loaded = await service.loadActivePack();
    expect(loaded, isNotNull);
    expect(loaded!.manifest.renders, isNotEmpty);
  });

  test('returns failure when ZIP path does not exist', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'wardrobe_pack_test_',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final service = ContentPackService(
      appDirectoryProvider: () async => tempRoot,
    );
    final result = await service.importZip(File('/does/not/exist.zip'));

    expect(result.success, isFalse);
    expect(result.reason, ImportFailureReason.missingFile);
  });

  test('rejects ZIPs that exceed configured resource limits', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'wardrobe_pack_test_',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final archive = Archive()
      ..addFile(ArchiveFile.string('wardrobe.json', '{}'))
      ..addFile(ArchiveFile.string('extra.txt', 'x'));
    final zipBytes = ZipEncoder().encode(archive);
    final service = ContentPackService(
      appDirectoryProvider: () async => tempRoot,
      maxArchiveEntries: 1,
    );

    final result = await service.importZipBytes(zipBytes);

    expect(result.success, isFalse);
    expect(result.reason, ImportFailureReason.invalidZip);
    expect(result.message, contains('more than 1 entries'));
  });

  test('rejects unsafe asset paths in the manifest', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'wardrobe_pack_test_',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final manifest = WardrobeManifest.empty().copyWith(
      schemaVersion: 5,
      poses: const <WardrobePose>[
        WardrobePose(
          id: 'unsafe',
          name: 'Unsafe',
          path: '../outside.png',
          renderReady: true,
        ),
      ],
    );
    final archive = Archive()
      ..addFile(
        ArchiveFile.string('wardrobe.json', jsonEncode(manifest.toJson())),
      );
    final zipBytes = ZipEncoder().encode(archive);
    final service = ContentPackService(
      appDirectoryProvider: () async => tempRoot,
    );

    final result = await service.importZipBytes(zipBytes);

    expect(result.success, isFalse);
    expect(result.reason, ImportFailureReason.invalidManifest);
    expect(result.message, contains('../outside.png'));
  });

  test('exports the complete active pack including regeneration queue', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'wardrobe_pack_test_',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final activeDir = Directory(
      p.join(tempRoot.path, 'wardrobe_flutter', 'active_pack'),
    );
    await activeDir.create(recursive: true);

    final manifest = WardrobeManifest(
      schemaVersion: 5,
      generatedAt: DateTime.utc(2026, 2, 8),
      images: const WardrobeImages(
        outputSize: <int>[1080, 1920],
        thumbnailSize: <int>[256, 256],
        imageFormat: 'png',
        overlayFormat: 'png',
        thumbnailFormat: 'jpg',
      ),
      poses: const <WardrobePose>[
        WardrobePose(
          id: 'default-pose',
          name: 'Default Pose',
          thumbPath: 'thumbs/poses/default.jpg',
          renderReady: true,
        ),
        WardrobePose(
          id: 'custom-pose',
          name: 'Custom Pose',
          path: 'poses/custom-pose/pose.png',
          thumbPath: 'poses/custom-pose/thumb.jpg',
          metaPath: 'poses/custom-pose/pose.yaml',
          neckY: 0.2,
          ankleY: 0.85,
          renderReady: false,
        ),
      ],
      categories: const <String, List<WardrobeItem>>{
        'top': <WardrobeItem>[
          WardrobeItem(
            id: 'default-top',
            category: 'top',
            thumbPath: 'thumbs/top/default.jpg',
            tags: <String>[],
            renderReady: true,
          ),
          WardrobeItem(
            id: 'custom-top',
            category: 'top',
            path: 'items/top/custom-top/image.png',
            thumbPath: 'items/top/custom-top/thumb.jpg',
            metaPath: 'items/top/custom-top/item.yaml',
            tags: <String>[],
            renderReady: false,
          ),
        ],
        'bottom': <WardrobeItem>[],
        'headwear': <WardrobeItem>[],
        'shoes': <WardrobeItem>[],
      },
      intakeQueue: const <WardrobePendingIntakeItem>[
        WardrobePendingIntakeItem(
          id: 'pending-1',
          path: 'items/intake_queue/pending-1/image.png',
          thumbPath: 'items/intake_queue/pending-1/thumb.jpg',
          metaPath: 'items/intake_queue/pending-1/item.yaml',
          createdAt: '2026-02-21T10:00:00Z',
        ),
      ],
      renders: const <WardrobeRender>[
        WardrobeRender(
          poseId: 'default-pose',
          topId: 'default-top',
          bottomId: 'default-bottom',
          path: 'renders/default-pose/default-top__default-bottom.png',
          size: <int>[1080, 1920],
        ),
      ],
      overlays: const <WardrobeOverlay>[
        WardrobeOverlay(
          poseId: 'default-pose',
          category: 'shoes',
          itemId: 'default-shoes',
          path: 'overlays/default-pose/shoes/default-shoes.png',
          anchorBox: <double>[0, 0, 1, 1],
        ),
      ],
      thumbs: const <WardrobeThumb>[],
      regeneration: const WardrobeRegenerationQueue(
        items: <WardrobeRegenerationRequest>[
          WardrobeRegenerationRequest(
            category: 'top',
            itemId: 'custom-top',
            requestedAt: '2026-03-01T10:00:00Z',
          ),
        ],
        targets: <WardrobeRegenerationTarget>[
          WardrobeRegenerationTarget.render(
            poseId: 'default-pose',
            topId: 'default-top',
            bottomId: 'default-bottom',
            requestedAt: '2026-03-01T10:05:00Z',
          ),
          WardrobeRegenerationTarget.overlay(
            poseId: 'default-pose',
            category: 'shoes',
            itemId: 'default-shoes',
            requestedAt: '2026-03-01T10:05:00Z',
          ),
        ],
      ),
    );

    await File(
      p.join(activeDir.path, 'wardrobe.json'),
    ).writeAsString(jsonEncode(manifest.toJson()), flush: true);

    for (final relativePath in const <String>[
      'poses/custom-pose/pose.png',
      'poses/custom-pose/thumb.jpg',
      'poses/custom-pose/pose.yaml',
      'thumbs/poses/default.jpg',
      'items/top/custom-top/image.png',
      'items/top/custom-top/thumb.jpg',
      'items/top/custom-top/item.yaml',
      'thumbs/top/default.jpg',
      'items/intake_queue/pending-1/image.png',
      'items/intake_queue/pending-1/thumb.jpg',
      'items/intake_queue/pending-1/item.yaml',
      'renders/default-pose/default-top__default-bottom.png',
      'overlays/default-pose/shoes/default-shoes.png',
    ]) {
      final file = File(p.join(activeDir.path, relativePath));
      await file.parent.create(recursive: true);
      await file.writeAsString('x', flush: true);
    }
    await File(
      p.join(activeDir.path, 'renders/stale/unused-render.png'),
    ).create(recursive: true);

    final downloadsDir = Directory(p.join(tempRoot.path, 'downloads'));
    final favoritesService = FavoritesService();
    final favoriteSelection = <String, String?>{
      'headwear': null,
      'top': 'custom-top',
      'bottom': null,
      'shoes': null,
    };
    final favoriteCategories = favoriteSelection.keys.toList(growable: false);
    final favorite = FavoriteOutfit(
      key: FavoriteOutfit.buildKey(
        selection: favoriteSelection,
        categories: favoriteCategories,
      ),
      selection: favoriteSelection,
      createdAt: DateTime.utc(2026, 3, 2, 9, 30),
    );
    await favoritesService.saveFavorite(
      packRoot: activeDir,
      favorite: favorite,
      orderedCategories: favoriteCategories,
    );
    final service = ContentPackService(
      appDirectoryProvider: () async => tempRoot,
      downloadsDirectoryProvider: () async => downloadsDir,
    );

    final zipFile = await service.exportActiveWorkspaceZip(
      fileName: 'workspace_only.zip',
    );
    expect(zipFile.path, p.join(downloadsDir.path, 'workspace_only.zip'));
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final names = archive.files.map((ArchiveFile file) => file.name).toSet();

    expect(
      names,
      containsAll(<String>[
        'wardrobe.json',
        'poses/custom-pose/pose.png',
        'poses/custom-pose/thumb.jpg',
        'poses/custom-pose/pose.yaml',
        'thumbs/poses/default.jpg',
        'items/top/custom-top/image.png',
        'items/top/custom-top/thumb.jpg',
        'items/top/custom-top/item.yaml',
        'thumbs/top/default.jpg',
        'items/intake_queue/pending-1/image.png',
        'items/intake_queue/pending-1/thumb.jpg',
        'items/intake_queue/pending-1/item.yaml',
        'renders/default-pose/default-top__default-bottom.png',
        'overlays/default-pose/shoes/default-shoes.png',
        'favorites/${base64UrlEncode(utf8.encode(favorite.key)).replaceAll('=', '')}.yaml',
      ]),
    );
    expect(names, isNot(contains('renders/stale/unused-render.png')));

    final manifestEntry = archive.files.firstWhere(
      (ArchiveFile file) => file.name == 'wardrobe.json',
    );
    final exportedManifest =
        jsonDecode(utf8.decode(manifestEntry.content as List<int>))
            as Map<String, dynamic>;

    expect(exportedManifest['schema_version'], 5);
    expect((exportedManifest['renders'] as List<dynamic>).length, 1);
    expect((exportedManifest['overlays'] as List<dynamic>).length, 1);
    expect((exportedManifest['intake_queue'] as List<dynamic>).length, 1);
    final regeneration =
        exportedManifest['regeneration'] as Map<String, dynamic>;
    expect((regeneration['items'] as List<dynamic>).length, 1);
    expect((regeneration['targets'] as List<dynamic>).length, 2);

    final poses = exportedManifest['poses'] as List<dynamic>;
    expect(poses.length, 2);

    final categories = exportedManifest['categories'] as Map<String, dynamic>;
    final tops = categories['top'] as List<dynamic>;
    expect(tops.length, 2);

    await service.clearActivePack();
    final importResult = await service.importZip(zipFile);
    expect(importResult.success, isTrue, reason: importResult.message);
    expect(importResult.manifest, isNotNull);
    expect(importResult.manifest!.schemaVersion, 5);
    expect(importResult.manifest!.renders, hasLength(1));
    expect(importResult.manifest!.overlays, hasLength(1));
    expect(importResult.manifest!.intakeQueue.length, 1);
    expect(importResult.manifest!.poses.length, 2);
    expect(importResult.manifest!.itemsForCategory('top').length, 2);
    expect(importResult.manifest!.regeneration.items, hasLength(1));
    expect(importResult.manifest!.regeneration.targets, hasLength(2));
    final importedFavorites = await favoritesService.loadFavorites(
      packRoot: importResult.packRoot!,
    );
    expect(importedFavorites, hasLength(1));
    expect(importedFavorites.single.key, favorite.key);
  });

  test(
    'import replaces existing workspace state and preserves ZIP manifest verbatim',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'wardrobe_pack_test_',
      );
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final service = ContentPackService(
        appDirectoryProvider: () async => tempRoot,
      );
      final activeDir = Directory(
        p.join(tempRoot.path, 'wardrobe_flutter', 'active_pack'),
      );
      await activeDir.create(recursive: true);
      await File(
        p.join(activeDir.path, 'stale.txt'),
      ).writeAsString('old-state', flush: true);

      final manifest = WardrobeManifest.empty().copyWith(
        schemaVersion: 5,
        poses: const <WardrobePose>[
          WardrobePose(
            id: 'dummy1',
            name: 'Default',
            path: 'poses/dummy1/pose.png',
            renderReady: true,
          ),
          WardrobePose(
            id: 'pose-1',
            name: 'pending pose',
            path: 'poses/pose-1/pose.png',
            renderReady: false,
          ),
        ],
        categories: const <String, List<WardrobeItem>>{
          'headwear': <WardrobeItem>[],
          'top': <WardrobeItem>[
            WardrobeItem(
              id: 'rex',
              category: 'top',
              path: 'items/top/rex/image.png',
              tags: <String>[],
              renderReady: true,
            ),
            WardrobeItem(
              id: 'user-top',
              category: 'top',
              path: 'items/top/user-top/image.png',
              tags: <String>[],
              renderReady: false,
            ),
          ],
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
        renders: const <WardrobeRender>[],
        overlays: const <WardrobeOverlay>[],
      );

      final archive = Archive();
      final manifestBytes = utf8.encode(jsonEncode(manifest.toJson()));
      archive.addFile(
        ArchiveFile('wardrobe.json', manifestBytes.length, manifestBytes),
      );
      for (final path in manifest.referencedAssetPaths()) {
        final bytes = utf8.encode('x');
        archive.addFile(ArchiveFile(path, bytes.length, bytes));
      }

      final zipBytes = ZipEncoder().encode(archive);
      final result = await service.importZipBytes(zipBytes);

      expect(result.success, isTrue, reason: result.message);
      expect(result.manifest, isNotNull);
      expect(
        result.manifest!.poses.map((WardrobePose pose) => pose.id),
        <String>['dummy1', 'pose-1'],
      );
      expect(
        result.manifest!
            .itemsForCategory('top')
            .map((WardrobeItem item) => item.id),
        <String>['rex', 'user-top'],
      );
      expect(result.manifest!.intakeQueue, hasLength(1));
      expect(File(p.join(activeDir.path, 'stale.txt')).existsSync(), isFalse);
    },
  );
}
