import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/wardrobe.dart';
import 'content_pack_service.dart';

class IntakeTagData {
  const IntakeTagData({
    required this.name,
    required this.category,
    this.subcategory,
    this.color,
    this.tags = const <String>[],
  });

  final String name;
  final String category;
  final String? subcategory;
  final String? color;
  final List<String> tags;
}

class IntakeTagSuggestions {
  const IntakeTagSuggestions({
    this.subcategories = const <String>[],
    this.subcategoriesByCategory = const <String, List<String>>{},
    this.colors = const <String>[],
    this.materials = const <String>[],
    this.styles = const <String>[],
    this.patterns = const <String>[],
    this.tags = const <String>[],
  });

  final List<String> subcategories;
  final Map<String, List<String>> subcategoriesByCategory;
  final List<String> colors;
  final List<String> materials;
  final List<String> styles;
  final List<String> patterns;
  final List<String> tags;

  List<String> subcategoriesForCategory(String category) {
    final normalizedCategory = category.trim().toLowerCase();
    if (normalizedCategory.isEmpty) {
      return subcategories;
    }
    return subcategoriesByCategory[normalizedCategory] ?? const <String>[];
  }
}

class EditableWardrobeItemMetadata {
  const EditableWardrobeItemMetadata({
    required this.name,
    required this.category,
    required this.subcategory,
    required this.colorPrimary,
    required this.material,
    required this.styleOccasion,
    required this.patternDesign,
    required this.tags,
    this.previewImagePath,
  });

  final String name;
  final String category;
  final String subcategory;
  final String colorPrimary;
  final String material;
  final String styleOccasion;
  final String patternDesign;
  final List<String> tags;
  final String? previewImagePath;
}

class UpdateWardrobeItemRequest {
  const UpdateWardrobeItemRequest({
    required this.currentCategory,
    required this.itemId,
    required this.metadata,
  });

  final String currentCategory;
  final String itemId;
  final EditableWardrobeItemMetadata metadata;
}

class UpdateWardrobeItemResult {
  const UpdateWardrobeItemResult({
    required this.manifest,
    required this.categoryChanged,
    required this.previousCategory,
    required this.nextCategory,
    required this.previousItemId,
    required this.nextItemId,
    required this.invalidatedAssetsCount,
  });

  final WardrobeManifest manifest;
  final bool categoryChanged;
  final String previousCategory;
  final String nextCategory;
  final String previousItemId;
  final String nextItemId;
  final int invalidatedAssetsCount;
}

class IntakePoseMarkers {
  const IntakePoseMarkers({required this.neckY, required this.ankleY});

  final double neckY;
  final double ankleY;
}

class IntakeWorkspaceService {
  IntakeWorkspaceService(this._contentPackService);

  final ContentPackService _contentPackService;
  static const String _pendingPoseName = 'pending pose';

  static const Set<String> _allowedCategories = <String>{
    'top',
    'bottom',
    'headwear',
    'shoes',
  };

  Future<IntakeTagSuggestions> loadTagSuggestions() async {
    final active = await _contentPackService.ensureActiveWorkspace();
    final categories = active.manifest.categories;
    final allItems = categories.values.expand(
      (List<WardrobeItem> items) => items,
    );
    final subcategoriesByCategory = <String, List<String>>{
      for (final entry in categories.entries)
        entry.key.trim().toLowerCase(): _collectUniqueSorted(
          entry.value
              .map((WardrobeItem item) => item.subcategory)
              .where((String? value) => !_isUnknownPlaceholder(value)),
        ),
    };

    return IntakeTagSuggestions(
      subcategoriesByCategory: subcategoriesByCategory,
      subcategories: _collectUniqueSorted(
        subcategoriesByCategory.values.expand((List<String> values) => values),
      ),
      colors: _collectUniqueSorted(
        allItems
            .map((WardrobeItem item) => item.colorPrimary)
            .where((String? value) => !_isUnknownPlaceholder(value)),
      ),
      materials: _collectUniqueSorted(
        allItems
            .map((WardrobeItem item) => item.material)
            .where((String? value) => !_isUnknownPlaceholder(value)),
      ),
      styles: _collectUniqueSorted(
        allItems
            .map((WardrobeItem item) => item.styleOccasion)
            .where((String? value) => !_isUnknownPlaceholder(value)),
      ),
      patterns: _collectUniqueSorted(
        allItems
            .map((WardrobeItem item) => item.patternDesign)
            .where((String? value) => !_isUnknownPlaceholder(value)),
      ),
      tags: _collectUniqueSorted(
        allItems.expand((WardrobeItem item) => item.tags),
      ),
    );
  }

  Future<EditableWardrobeItemMetadata> loadEditableItemMetadata({
    required String category,
    required String itemId,
  }) async {
    final normalizedCategory = category.trim().toLowerCase();
    final normalizedItemId = itemId.trim();
    if (!_allowedCategories.contains(normalizedCategory)) {
      throw ArgumentError('Unsupported category: $category');
    }
    if (normalizedItemId.isEmpty) {
      throw ArgumentError('Item id must not be empty.');
    }

    final active = await _contentPackService.ensureActiveWorkspace();
    final manifest = active.manifest;
    final existing = manifest
        .itemsForCategory(normalizedCategory)
        .where((WardrobeItem item) => item.id == normalizedItemId)
        .firstOrNull;
    if (existing == null) {
      throw StateError(
        'Could not find item "$normalizedItemId" in category "$normalizedCategory".',
      );
    }

    return EditableWardrobeItemMetadata(
      name: existing.name.trim().isEmpty
          ? _humanizeSlug(existing.id)
          : existing.name,
      category: existing.category,
      subcategory: _normalizedEditableText(existing.subcategory),
      colorPrimary: _normalizedEditableText(existing.colorPrimary),
      material: _normalizedEditableText(existing.material),
      styleOccasion: _normalizedEditableText(existing.styleOccasion),
      patternDesign: _normalizedEditableText(existing.patternDesign),
      tags: _normalizeTagList(existing.tags),
      previewImagePath: _resolveEditablePreviewPath(
        root: active.root,
        primaryRelativePath: existing.path,
        fallbackRelativePath: existing.thumbPath,
      ),
    );
  }

  String? _resolveEditablePreviewPath({
    required Directory root,
    required String? primaryRelativePath,
    required String? fallbackRelativePath,
  }) {
    final candidate = primaryRelativePath?.trim().isNotEmpty == true
        ? primaryRelativePath!.trim()
        : (fallbackRelativePath?.trim().isNotEmpty == true
              ? fallbackRelativePath!.trim()
              : null);
    if (candidate == null) {
      return null;
    }
    return _contentPackService.resolveAssetFile(root, candidate).path;
  }

  Future<WardrobeManifest> updateClothingItemMetadata(
    UpdateWardrobeItemRequest request,
  ) async {
    final result = await updateClothingItemMetadataWithResult(request);
    return result.manifest;
  }

  Future<UpdateWardrobeItemResult> updateClothingItemMetadataWithResult(
    UpdateWardrobeItemRequest request,
  ) async {
    final previousCategory = request.currentCategory.trim().toLowerCase();
    final previousItemId = request.itemId.trim();
    final nextCategory = request.metadata.category.trim().toLowerCase();
    final nextName = request.metadata.name.trim();

    if (!_allowedCategories.contains(previousCategory)) {
      throw ArgumentError('Unsupported category: ${request.currentCategory}');
    }
    if (!_allowedCategories.contains(nextCategory)) {
      throw ArgumentError('Unsupported category: ${request.metadata.category}');
    }
    if (previousItemId.isEmpty) {
      throw ArgumentError('Item id must not be empty.');
    }
    if (nextName.isEmpty) {
      throw ArgumentError('Item name must not be empty.');
    }

    final active = await _contentPackService.ensureActiveWorkspace();
    final root = active.root;
    final manifest = active.manifest;

    final previousItems = manifest.itemsForCategory(previousCategory);
    final existingItem = previousItems
        .where((WardrobeItem item) => item.id == previousItemId)
        .firstOrNull;
    if (existingItem == null) {
      throw StateError(
        'Could not find item "$previousItemId" in category "$previousCategory".',
      );
    }

    final categoryChanged = previousCategory != nextCategory;
    final targetIds = manifest
        .itemsForCategory(nextCategory)
        .map((WardrobeItem item) => item.id)
        .where((String id) {
          if (!categoryChanged) {
            return id != previousItemId;
          }
          return true;
        })
        .toSet();
    final nextItemId = _makeUniqueSlug(previousItemId, targetIds);

    String? newPath = existingItem.path;
    String? newThumbPath = existingItem.thumbPath;
    String? newMetaPath = existingItem.metaPath;

    if (categoryChanged) {
      final oldImageRelative = existingItem.path;
      final oldThumbRelative = existingItem.thumbPath;
      final oldMetaRelative = existingItem.metaPath;
      final imageExt = _extensionFromRelativePath(
        oldImageRelative,
        fallback: '.png',
      );
      final thumbExt = _extensionFromRelativePath(
        oldThumbRelative,
        fallback: '.${manifest.images.thumbnailFormat}',
      );

      final newImageRelative = 'items/$nextCategory/$nextItemId/image$imageExt';
      final newThumbRelative = oldThumbRelative == null
          ? null
          : 'items/$nextCategory/$nextItemId/thumb$thumbExt';
      final newMetaRelative = 'items/$nextCategory/$nextItemId/item.yaml';

      await _moveRelativeAsset(
        root: root,
        oldRelativePath: oldImageRelative,
        newRelativePath: newImageRelative,
      );
      if (oldThumbRelative != null && newThumbRelative != null) {
        await _moveRelativeAsset(
          root: root,
          oldRelativePath: oldThumbRelative,
          newRelativePath: newThumbRelative,
        );
      }
      if (oldMetaRelative != null && oldMetaRelative.isNotEmpty) {
        await _moveRelativeAsset(
          root: root,
          oldRelativePath: oldMetaRelative,
          newRelativePath: newMetaRelative,
        );
      }

      newPath = newImageRelative;
      newThumbPath = newThumbRelative;
      newMetaPath = newMetaRelative;
      if (oldMetaRelative != null && oldMetaRelative.isNotEmpty) {
        await _cleanupRelativeParents(root, oldMetaRelative, stopAt: 'items');
      }
    }

    final updatedItem = existingItem.copyWith(
      id: nextItemId,
      name: nextName,
      category: nextCategory,
      subcategory: _normalizedFieldOrUnknown(request.metadata.subcategory),
      colorPrimary: _normalizedFieldOrUnknown(request.metadata.colorPrimary),
      material: _normalizedFieldOrUnknown(request.metadata.material),
      styleOccasion: _normalizedFieldOrUnknown(request.metadata.styleOccasion),
      patternDesign: _normalizedFieldOrUnknown(request.metadata.patternDesign),
      tags: _normalizeTagList(request.metadata.tags),
      path: newPath,
      thumbPath: newThumbPath,
      metaPath: newMetaPath,
      renderReady: categoryChanged ? false : existingItem.renderReady,
    );

    final nextCategories = <String, List<WardrobeItem>>{
      for (final entry in manifest.categories.entries)
        entry.key: List<WardrobeItem>.from(entry.value),
    };
    nextCategories[previousCategory] = nextCategories[previousCategory]!
        .where((WardrobeItem item) => item.id != previousItemId)
        .toList(growable: false);
    nextCategories.putIfAbsent(nextCategory, () => <WardrobeItem>[]);
    nextCategories[nextCategory] = <WardrobeItem>[
      ...nextCategories[nextCategory]!,
      updatedItem,
    ];

    var invalidatedAssetsCount = 0;
    List<WardrobeRender> nextRenders = List<WardrobeRender>.from(
      manifest.renders,
    );
    List<WardrobeOverlay> nextOverlays = List<WardrobeOverlay>.from(
      manifest.overlays,
    );
    List<WardrobeThumb> nextThumbs = manifest.thumbs
        .where((WardrobeThumb thumb) {
          return !(thumb.category == previousCategory &&
              thumb.itemId == previousItemId);
        })
        .toList(growable: false);

    if (categoryChanged) {
      final removedRenders = manifest.renders
          .where((WardrobeRender render) {
            return (previousCategory == 'top' &&
                    render.topId == previousItemId) ||
                (previousCategory == 'bottom' &&
                    render.bottomId == previousItemId);
          })
          .toList(growable: false);
      final removedOverlays = manifest.overlays
          .where(
            (WardrobeOverlay overlay) =>
                overlay.category == previousCategory &&
                overlay.itemId == previousItemId,
          )
          .toList(growable: false);
      nextRenders = manifest.renders
          .where((WardrobeRender render) => !removedRenders.contains(render))
          .toList(growable: false);
      nextOverlays = manifest.overlays
          .where(
            (WardrobeOverlay overlay) => !removedOverlays.contains(overlay),
          )
          .toList(growable: false);
      invalidatedAssetsCount = removedRenders.length + removedOverlays.length;

      final invalidatedPaths = <String>{
        ...removedRenders.map((WardrobeRender render) => render.path),
        ...removedRenders
            .map((WardrobeRender render) => render.metaPath)
            .whereType<String>(),
        ...removedOverlays.map((WardrobeOverlay overlay) => overlay.path),
        ...removedOverlays
            .map((WardrobeOverlay overlay) => overlay.metaPath)
            .whereType<String>(),
      };
      for (final relativePath in invalidatedPaths) {
        await _deleteRelativeAssetFile(
          root,
          _normalizeRelativePath(relativePath),
        );
      }
    }

    var updatedManifest = manifest.copyWith(
      schemaVersion: 5,
      generatedAt: DateTime.now().toUtc(),
      categories: nextCategories,
      renders: nextRenders,
      overlays: nextOverlays,
      thumbs: nextThumbs,
    );

    if (categoryChanged) {
      updatedManifest = _recalculateRenderReadiness(updatedManifest);
    }

    final targetMetaPath =
        updatedItem.metaPath ?? 'items/$nextCategory/$nextItemId/item.yaml';
    final metaFile = _contentPackService.resolveAssetFile(root, targetMetaPath);
    await metaFile.parent.create(recursive: true);
    final metaPayload = <String, dynamic>{
      'id': updatedItem.id,
      'name': updatedItem.name,
      'category': updatedItem.category,
      'subcategory': updatedItem.subcategory ?? 'unknown',
      'color_primary': updatedItem.colorPrimary ?? 'unknown',
      'material': updatedItem.material ?? 'unknown',
      'style_occasion': updatedItem.styleOccasion ?? 'unknown',
      'pattern_design': updatedItem.patternDesign ?? 'unknown',
      'tags': updatedItem.tags,
      if (updatedItem.path != null) 'path': updatedItem.path,
      if (updatedItem.thumbPath != null) 'thumb_path': updatedItem.thumbPath,
      'meta_path': targetMetaPath,
      'render_ready':
          updatedManifest
              .itemsForCategory(nextCategory)
              .where((WardrobeItem item) => item.id == nextItemId)
              .firstOrNull
              ?.renderReady ??
          updatedItem.renderReady,
      'classification': updatedItem.classification.toJson(),
    };
    await metaFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(metaPayload),
      flush: true,
    );

    await _contentPackService.saveActiveManifest(updatedManifest);
    return UpdateWardrobeItemResult(
      manifest: updatedManifest,
      categoryChanged: categoryChanged,
      previousCategory: previousCategory,
      nextCategory: nextCategory,
      previousItemId: previousItemId,
      nextItemId: nextItemId,
      invalidatedAssetsCount: invalidatedAssetsCount,
    );
  }

  Future<WardrobeManifest> toggleItemRegeneration({
    required String category,
    required String itemId,
  }) async {
    final normalizedCategory = category.trim().toLowerCase();
    final normalizedItemId = itemId.trim();
    if (!_allowedCategories.contains(normalizedCategory)) {
      throw ArgumentError('Unsupported category: $category');
    }
    if (normalizedItemId.isEmpty) {
      throw ArgumentError('Item id must not be empty.');
    }

    final active = await _contentPackService.ensureActiveWorkspace();
    final manifest = active.manifest;
    final itemExists = manifest
        .itemsForCategory(normalizedCategory)
        .any((WardrobeItem item) => item.id == normalizedItemId);
    if (!itemExists) {
      throw StateError(
        'Could not find item "$normalizedItemId" in category "$normalizedCategory".',
      );
    }

    final existing = manifest.regeneration.items;
    final nextTimestamp = DateTime.now().toUtc().toIso8601String();
    final requestKey = '$normalizedCategory|$normalizedItemId';
    final alreadyQueued = existing.any(
      (WardrobeRegenerationRequest request) => request.key == requestKey,
    );
    final nextItems = alreadyQueued
        ? existing
              .where(
                (WardrobeRegenerationRequest request) =>
                    request.key != requestKey,
              )
              .toList(growable: false)
        : <WardrobeRegenerationRequest>[
            ...existing.where(
              (WardrobeRegenerationRequest request) =>
                  request.key != requestKey,
            ),
            WardrobeRegenerationRequest(
              category: normalizedCategory,
              itemId: normalizedItemId,
              requestedAt: nextTimestamp,
            ),
          ];

    final updated = manifest.copyWith(
      generatedAt: DateTime.now().toUtc(),
      regeneration: manifest.regeneration.copyWith(items: nextItems),
    );
    await _contentPackService.saveActiveManifest(updated);
    return updated;
  }

  Future<WardrobeManifest> togglePoseItemRegeneration({
    required String poseId,
    required String category,
    required String itemId,
  }) async {
    final normalizedPoseId = poseId.trim();
    final normalizedCategory = category.trim().toLowerCase();
    final normalizedItemId = itemId.trim();
    if (normalizedPoseId.isEmpty) {
      throw ArgumentError('Pose id must not be empty.');
    }
    if (!_allowedCategories.contains(normalizedCategory)) {
      throw ArgumentError('Unsupported category: $category');
    }
    if (normalizedItemId.isEmpty) {
      throw ArgumentError('Item id must not be empty.');
    }

    final active = await _contentPackService.ensureActiveWorkspace();
    final manifest = active.manifest;
    final hasPose = manifest.poses.any(
      (WardrobePose pose) => pose.id == normalizedPoseId,
    );
    final itemExists = manifest
        .itemsForCategory(normalizedCategory)
        .any((WardrobeItem item) => item.id == normalizedItemId);
    if (!hasPose || !itemExists) {
      throw StateError(
        'Could not resolve pose item target "$normalizedPoseId/$normalizedCategory/$normalizedItemId".',
      );
    }

    return _toggleRegenerationTarget(
      manifest: manifest,
      target: WardrobeRegenerationTarget.poseItem(
        poseId: normalizedPoseId,
        category: normalizedCategory,
        itemId: normalizedItemId,
        requestedAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  Future<WardrobeManifest> toggleRenderRegeneration({
    required String poseId,
    required String topId,
    required String bottomId,
  }) async {
    final normalizedPoseId = poseId.trim();
    final normalizedTopId = topId.trim();
    final normalizedBottomId = bottomId.trim();
    if (normalizedPoseId.isEmpty ||
        normalizedTopId.isEmpty ||
        normalizedBottomId.isEmpty) {
      throw ArgumentError('Pose, top, and bottom ids must not be empty.');
    }

    final active = await _contentPackService.ensureActiveWorkspace();
    final manifest = active.manifest;
    final hasPose = manifest.poses.any(
      (WardrobePose pose) => pose.id == normalizedPoseId,
    );
    final hasTop = manifest
        .itemsForCategory('top')
        .any((WardrobeItem item) => item.id == normalizedTopId);
    final hasBottom = manifest
        .itemsForCategory('bottom')
        .any((WardrobeItem item) => item.id == normalizedBottomId);
    if (!hasPose || !hasTop || !hasBottom) {
      throw StateError(
        'Could not resolve render target "$normalizedPoseId/$normalizedTopId/$normalizedBottomId".',
      );
    }

    return _toggleRegenerationTarget(
      manifest: manifest,
      target: WardrobeRegenerationTarget.render(
        poseId: normalizedPoseId,
        topId: normalizedTopId,
        bottomId: normalizedBottomId,
        requestedAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  Future<WardrobeManifest> toggleOverlayRegeneration({
    required String poseId,
    required String category,
    required String itemId,
  }) async {
    final normalizedPoseId = poseId.trim();
    final normalizedCategory = category.trim().toLowerCase();
    final normalizedItemId = itemId.trim();
    if (normalizedPoseId.isEmpty) {
      throw ArgumentError('Pose id must not be empty.');
    }
    if (!(normalizedCategory == 'headwear' || normalizedCategory == 'shoes')) {
      throw ArgumentError('Unsupported overlay category: $category');
    }
    if (normalizedItemId.isEmpty) {
      throw ArgumentError('Item id must not be empty.');
    }

    final active = await _contentPackService.ensureActiveWorkspace();
    final manifest = active.manifest;
    final hasPose = manifest.poses.any(
      (WardrobePose pose) => pose.id == normalizedPoseId,
    );
    final itemExists = manifest
        .itemsForCategory(normalizedCategory)
        .any((WardrobeItem item) => item.id == normalizedItemId);
    if (!hasPose || !itemExists) {
      throw StateError(
        'Could not resolve overlay target "$normalizedPoseId/$normalizedCategory/$normalizedItemId".',
      );
    }

    return _toggleRegenerationTarget(
      manifest: manifest,
      target: WardrobeRegenerationTarget.overlay(
        poseId: normalizedPoseId,
        category: normalizedCategory,
        itemId: normalizedItemId,
        requestedAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  Future<WardrobeManifest> _toggleRegenerationTarget({
    required WardrobeManifest manifest,
    required WardrobeRegenerationTarget target,
  }) async {
    final existing = manifest.regeneration.targets;
    final alreadyQueued = existing.any(
      (WardrobeRegenerationTarget request) => request.key == target.key,
    );
    final nextTargets = alreadyQueued
        ? existing
              .where(
                (WardrobeRegenerationTarget request) =>
                    request.key != target.key,
              )
              .toList(growable: false)
        : <WardrobeRegenerationTarget>[
            ...existing.where(
              (WardrobeRegenerationTarget request) => request.key != target.key,
            ),
            target,
          ];

    final updated = manifest.copyWith(
      generatedAt: DateTime.now().toUtc(),
      regeneration: manifest.regeneration.copyWith(targets: nextTargets),
    );
    await _contentPackService.saveActiveManifest(updated);
    return updated;
  }

  Future<WardrobeManifest> saveClothingSelection({
    required Uint8List imageBytes,
    required RectSelection selection,
  }) async {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw const FormatException('Could not decode selected image.');
    }

    final active = await _contentPackService.ensureActiveWorkspace();
    final manifest = active.manifest;

    final itemIdBase = _slugify(
      'intake-${DateTime.now().toUtc().millisecondsSinceEpoch}',
    );
    final existingIds = manifest.intakeQueue
        .map((WardrobePendingIntakeItem item) => item.id)
        .toSet();
    final itemId = _makeUniqueSlug(itemIdBase, existingIds);

    final cropped = _cropSelection(decoded, selection);

    final imageRelativePath = 'items/intake_queue/$itemId/image.png';
    final thumbRelativePath =
        'items/intake_queue/$itemId/thumb.${manifest.images.thumbnailFormat}';
    final metaRelativePath = 'items/intake_queue/$itemId/item.yaml';

    final imageFile = _contentPackService.resolveAssetFile(
      active.root,
      imageRelativePath,
    );
    final thumbFile = _contentPackService.resolveAssetFile(
      active.root,
      thumbRelativePath,
    );
    final metaFile = _contentPackService.resolveAssetFile(
      active.root,
      metaRelativePath,
    );

    await imageFile.parent.create(recursive: true);
    await thumbFile.parent.create(recursive: true);
    await metaFile.parent.create(recursive: true);

    await imageFile.writeAsBytes(img.encodePng(cropped), flush: true);

    final thumbImage = _buildThumbnail(
      cropped,
      width: manifest.images.thumbnailSize[0],
      height: manifest.images.thumbnailSize[1],
    );
    final thumbFormat = _normalizeImageFormat(manifest.images.thumbnailFormat);
    await thumbFile.writeAsBytes(
      _encodeImage(thumbImage, thumbFormat),
      flush: true,
    );

    final createdAt = DateTime.now().toUtc().toIso8601String();
    final itemPayload = <String, dynamic>{
      'id': itemId,
      'path': imageRelativePath,
      'thumb_path': thumbRelativePath,
      'meta_path': metaRelativePath,
      'created_at': createdAt,
    };
    await metaFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(itemPayload),
      flush: true,
    );

    final newItem = WardrobePendingIntakeItem(
      id: itemId,
      path: imageRelativePath,
      thumbPath: thumbRelativePath,
      metaPath: metaRelativePath,
      createdAt: createdAt,
    );

    final updated = manifest.copyWith(
      schemaVersion: 5,
      generatedAt: DateTime.now().toUtc(),
      intakeQueue: <WardrobePendingIntakeItem>[
        ...manifest.intakeQueue,
        newItem,
      ],
    );

    await _contentPackService.saveActiveManifest(updated);
    return updated;
  }

  Future<WardrobeManifest> deleteClothingItem({
    required String category,
    required String itemId,
  }) async {
    final normalizedCategory = category.trim().toLowerCase();
    final normalizedItemId = itemId.trim();

    if (!_allowedCategories.contains(normalizedCategory)) {
      throw ArgumentError('Unsupported category: $category');
    }
    if (normalizedItemId.isEmpty) {
      throw ArgumentError('Item id must not be empty.');
    }

    final active = await _contentPackService.ensureActiveWorkspace();
    final manifest = active.manifest;

    final existingCategoryItems = manifest.itemsForCategory(normalizedCategory);
    final itemToDelete = existingCategoryItems
        .where((WardrobeItem item) => item.id == normalizedItemId)
        .firstOrNull;
    if (itemToDelete == null) {
      throw StateError(
        'Could not find item "$normalizedItemId" in category "$normalizedCategory".',
      );
    }

    final updatedCategories = <String, List<WardrobeItem>>{
      for (final entry in manifest.categories.entries)
        entry.key: List<WardrobeItem>.from(entry.value),
    };
    final keptCategoryItems = existingCategoryItems
        .where((WardrobeItem item) => item.id != normalizedItemId)
        .toList(growable: false);
    updatedCategories[normalizedCategory] = keptCategoryItems;

    final removedRenders = manifest.renders
        .where((WardrobeRender render) {
          return switch (normalizedCategory) {
            'top' => render.topId == normalizedItemId,
            'bottom' => render.bottomId == normalizedItemId,
            _ => false,
          };
        })
        .toList(growable: false);
    final keptRenders = manifest.renders
        .where((WardrobeRender render) => !removedRenders.contains(render))
        .toList(growable: false);

    final removedOverlays = manifest.overlays
        .where(
          (WardrobeOverlay overlay) =>
              overlay.category == normalizedCategory &&
              overlay.itemId == normalizedItemId,
        )
        .toList(growable: false);
    final keptOverlays = manifest.overlays
        .where((WardrobeOverlay overlay) => !removedOverlays.contains(overlay))
        .toList(growable: false);

    final removedThumbs = manifest.thumbs
        .where(
          (WardrobeThumb thumb) =>
              thumb.category == normalizedCategory &&
              thumb.itemId == normalizedItemId,
        )
        .toList(growable: false);
    final keptThumbs = manifest.thumbs
        .where((WardrobeThumb thumb) => !removedThumbs.contains(thumb))
        .toList(growable: false);

    final updated = manifest.copyWith(
      schemaVersion: 5,
      generatedAt: DateTime.now().toUtc(),
      categories: updatedCategories,
      renders: keptRenders,
      overlays: keptOverlays,
      thumbs: keptThumbs,
    );

    final candidatePaths = <String>{
      if (itemToDelete.path != null && itemToDelete.path!.isNotEmpty)
        itemToDelete.path!,
      if (itemToDelete.thumbPath != null && itemToDelete.thumbPath!.isNotEmpty)
        itemToDelete.thumbPath!,
      if (itemToDelete.metaPath != null && itemToDelete.metaPath!.isNotEmpty)
        itemToDelete.metaPath!,
      ...removedThumbs.map((WardrobeThumb thumb) => thumb.path),
      ...removedRenders.map((WardrobeRender render) => render.path),
      ...removedRenders
          .map((WardrobeRender render) => render.metaPath)
          .whereType<String>(),
      ...removedOverlays.map((WardrobeOverlay overlay) => overlay.path),
      ...removedOverlays
          .map((WardrobeOverlay overlay) => overlay.metaPath)
          .whereType<String>(),
    };

    final referencedAfterDelete = updated
        .referencedAssetPaths()
        .map(_normalizeRelativePath)
        .toSet();

    for (final relativePath in candidatePaths) {
      final normalizedPath = _normalizeRelativePath(relativePath);
      if (normalizedPath.isEmpty ||
          referencedAfterDelete.contains(normalizedPath)) {
        continue;
      }
      await _deleteRelativeAssetFile(active.root, normalizedPath);
    }

    await _contentPackService.saveActiveManifest(updated);
    return updated;
  }

  Future<WardrobeManifest> deletePendingIntakeItem({
    required String itemId,
  }) async {
    final normalizedItemId = itemId.trim();
    if (normalizedItemId.isEmpty) {
      throw ArgumentError('Item id must not be empty.');
    }

    final active = await _contentPackService.ensureActiveWorkspace();
    final manifest = active.manifest;
    final itemToDelete = manifest.intakeQueue
        .where((WardrobePendingIntakeItem item) => item.id == normalizedItemId)
        .firstOrNull;
    if (itemToDelete == null) {
      throw StateError(
        'Could not find pending intake item "$normalizedItemId".',
      );
    }

    final updated = manifest.copyWith(
      schemaVersion: 5,
      generatedAt: DateTime.now().toUtc(),
      intakeQueue: manifest.intakeQueue
          .where(
            (WardrobePendingIntakeItem item) => item.id != normalizedItemId,
          )
          .toList(growable: false),
    );

    final candidatePaths = <String>{
      itemToDelete.path,
      itemToDelete.thumbPath,
      itemToDelete.metaPath,
    };
    final referencedAfterDelete = updated
        .referencedAssetPaths()
        .map(_normalizeRelativePath)
        .toSet();

    for (final relativePath in candidatePaths) {
      final normalizedPath = _normalizeRelativePath(relativePath);
      if (normalizedPath.isEmpty ||
          referencedAfterDelete.contains(normalizedPath)) {
        continue;
      }
      await _deleteRelativeAssetFile(active.root, normalizedPath);
      await _cleanupRelativeParents(
        active.root,
        normalizedPath,
        stopAt: 'items',
      );
    }

    await _contentPackService.saveActiveManifest(updated);
    return updated;
  }

  Future<WardrobeManifest> savePoseSelection({
    required Uint8List imageBytes,
    required RectSelection? selection,
    required IntakePoseMarkers markers,
  }) async {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw const FormatException('Could not decode selected image.');
    }

    final active = await _contentPackService.ensureActiveWorkspace();
    final manifest = active.manifest;

    final poseName = _pendingPoseName;
    final poseIdBase = _slugify('pose-${manifest.poses.length + 1}');
    final existingPoseIds = manifest.poses
        .map((WardrobePose pose) => pose.id)
        .toSet();
    final poseId = _makeUniqueSlug(poseIdBase, existingPoseIds);

    final cropped = selection == null
        ? decoded
        : _cropSelection(decoded, selection);

    final poseRelativePath = 'poses/$poseId/pose.png';
    final thumbRelativePath =
        'poses/$poseId/thumb.${manifest.images.thumbnailFormat}';
    final metaRelativePath = 'poses/$poseId/pose.yaml';

    final poseFile = _contentPackService.resolveAssetFile(
      active.root,
      poseRelativePath,
    );
    final thumbFile = _contentPackService.resolveAssetFile(
      active.root,
      thumbRelativePath,
    );
    final metaFile = _contentPackService.resolveAssetFile(
      active.root,
      metaRelativePath,
    );

    await poseFile.parent.create(recursive: true);
    await thumbFile.parent.create(recursive: true);
    await metaFile.parent.create(recursive: true);

    await poseFile.writeAsBytes(img.encodePng(cropped), flush: true);

    final thumbImage = _buildThumbnail(
      cropped,
      width: manifest.images.thumbnailSize[0],
      height: manifest.images.thumbnailSize[1],
    );
    final thumbFormat = _normalizeImageFormat(manifest.images.thumbnailFormat);
    await thumbFile.writeAsBytes(
      _encodeImage(thumbImage, thumbFormat),
      flush: true,
    );

    final posePayload = <String, dynamic>{
      'id': poseId,
      'name': poseName,
      'neck_y': markers.neckY,
      'ankle_y': markers.ankleY,
      'path': poseRelativePath,
      'thumb_path': thumbRelativePath,
      'meta_path': metaRelativePath,
      'render_ready': false,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
    await metaFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(posePayload),
      flush: true,
    );

    final newPose = WardrobePose(
      id: poseId,
      name: poseName,
      path: poseRelativePath,
      thumbPath: thumbRelativePath,
      metaPath: metaRelativePath,
      neckY: markers.neckY,
      ankleY: markers.ankleY,
      renderReady: false,
    );

    final updated = manifest.copyWith(
      schemaVersion: 5,
      generatedAt: DateTime.now().toUtc(),
      poses: <WardrobePose>[...manifest.poses, newPose],
    );

    await _contentPackService.saveActiveManifest(updated);
    return updated;
  }

  Future<WardrobeManifest> updatePoseName({
    required String poseId,
    required String name,
  }) async {
    final normalizedPoseId = poseId.trim();
    final normalizedName = name.trim();
    if (normalizedPoseId.isEmpty) {
      throw ArgumentError('Pose id must not be empty.');
    }
    if (normalizedName.isEmpty) {
      throw ArgumentError('Pose name must not be empty.');
    }

    final active = await _contentPackService.ensureActiveWorkspace();
    final manifest = active.manifest;
    final existingPose = manifest.poses
        .where((WardrobePose pose) => pose.id == normalizedPoseId)
        .firstOrNull;
    if (existingPose == null) {
      throw StateError('Could not find pose "$normalizedPoseId".');
    }

    final updatedPose = existingPose.copyWith(name: normalizedName);
    final updatedPoses = manifest.poses
        .map(
          (WardrobePose pose) =>
              pose.id == normalizedPoseId ? updatedPose : pose,
        )
        .toList(growable: false);
    final updatedManifest = manifest.copyWith(
      schemaVersion: 5,
      generatedAt: DateTime.now().toUtc(),
      poses: updatedPoses,
    );

    final rawMetaPath = (updatedPose.metaPath?.trim().isNotEmpty ?? false)
        ? updatedPose.metaPath!
        : 'poses/${updatedPose.id}/pose.yaml';
    final metaRelativePath = _normalizeRelativePath(rawMetaPath);
    if (metaRelativePath.isNotEmpty) {
      final metaFile = _contentPackService.resolveAssetFile(
        active.root,
        metaRelativePath,
      );
      final existingMeta = await _readJsonMap(metaFile);
      final metaPayload = <String, dynamic>{
        ...existingMeta,
        'id': updatedPose.id,
        'name': updatedPose.name,
        if (updatedPose.neckY != null) 'neck_y': updatedPose.neckY,
        if (updatedPose.ankleY != null) 'ankle_y': updatedPose.ankleY,
        if (updatedPose.path != null) 'path': updatedPose.path,
        if (updatedPose.thumbPath != null) 'thumb_path': updatedPose.thumbPath,
        'meta_path': metaRelativePath,
        'render_ready': updatedPose.renderReady,
      };
      await metaFile.parent.create(recursive: true);
      await metaFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(metaPayload),
        flush: true,
      );
    }

    await _contentPackService.saveActiveManifest(updatedManifest);
    return updatedManifest;
  }

  Future<WardrobeManifest> deletePose({required String poseId}) async {
    final normalizedPoseId = poseId.trim();
    if (normalizedPoseId.isEmpty) {
      throw ArgumentError('Pose id must not be empty.');
    }

    final active = await _contentPackService.ensureActiveWorkspace();
    final manifest = active.manifest;
    final poseToDelete = manifest.poses
        .where((WardrobePose pose) => pose.id == normalizedPoseId)
        .firstOrNull;
    if (poseToDelete == null) {
      throw StateError('Could not find pose "$normalizedPoseId".');
    }

    final removedRenders = manifest.renders
        .where((WardrobeRender render) => render.poseId == normalizedPoseId)
        .toList(growable: false);
    final removedOverlays = manifest.overlays
        .where((WardrobeOverlay overlay) => overlay.poseId == normalizedPoseId)
        .toList(growable: false);

    var updatedManifest = manifest.copyWith(
      schemaVersion: 5,
      generatedAt: DateTime.now().toUtc(),
      poses: manifest.poses
          .where((WardrobePose pose) => pose.id != normalizedPoseId)
          .toList(growable: false),
      renders: manifest.renders
          .where((WardrobeRender render) => render.poseId != normalizedPoseId)
          .toList(growable: false),
      overlays: manifest.overlays
          .where(
            (WardrobeOverlay overlay) => overlay.poseId != normalizedPoseId,
          )
          .toList(growable: false),
    );
    updatedManifest = _recalculateRenderReadiness(updatedManifest);

    final candidatePaths = <String>{
      if (poseToDelete.path != null && poseToDelete.path!.isNotEmpty)
        poseToDelete.path!,
      if (poseToDelete.thumbPath != null && poseToDelete.thumbPath!.isNotEmpty)
        poseToDelete.thumbPath!,
      if (poseToDelete.metaPath != null && poseToDelete.metaPath!.isNotEmpty)
        poseToDelete.metaPath!,
      ...removedRenders.map((WardrobeRender render) => render.path),
      ...removedRenders
          .map((WardrobeRender render) => render.metaPath)
          .whereType<String>(),
      ...removedOverlays.map((WardrobeOverlay overlay) => overlay.path),
      ...removedOverlays
          .map((WardrobeOverlay overlay) => overlay.metaPath)
          .whereType<String>(),
    };
    final referencedAfterDelete = updatedManifest
        .referencedAssetPaths()
        .map(_normalizeRelativePath)
        .toSet();

    for (final relativePath in candidatePaths) {
      final normalizedPath = _normalizeRelativePath(relativePath);
      if (normalizedPath.isEmpty ||
          referencedAfterDelete.contains(normalizedPath)) {
        continue;
      }
      await _deleteRelativeAssetFile(active.root, normalizedPath);
      await _cleanupRelativeParents(
        active.root,
        normalizedPath,
        stopAt: normalizedPath.split('/').first,
      );
    }

    await _contentPackService.saveActiveManifest(updatedManifest);
    return updatedManifest;
  }

  WardrobeManifest _recalculateRenderReadiness(WardrobeManifest manifest) {
    final poses = manifest.poses;
    final tops = manifest.itemsForCategory('top');
    final bottoms = manifest.itemsForCategory('bottom');
    final renderSet = manifest.renders
        .map(
          (WardrobeRender render) =>
              '${render.poseId}|${render.topId}|${render.bottomId}',
        )
        .toSet();
    final overlaySet = manifest.overlays
        .map(
          (WardrobeOverlay overlay) =>
              '${overlay.poseId}|${overlay.category}|${overlay.itemId}',
        )
        .toSet();

    final nextPoses = poses
        .map((WardrobePose pose) {
          final required = tops.length * bottoms.length;
          final ready =
              required > 0 &&
              tops.every((WardrobeItem top) {
                return bottoms.every((WardrobeItem bottom) {
                  return renderSet.contains(
                    '${pose.id}|${top.id}|${bottom.id}',
                  );
                });
              });
          return pose.copyWith(renderReady: ready);
        })
        .toList(growable: false);

    final nextCategories = <String, List<WardrobeItem>>{};
    for (final entry in manifest.categories.entries) {
      final category = entry.key;
      final updatedItems = entry.value
          .map((WardrobeItem item) {
            bool ready;
            if (category == 'top') {
              ready =
                  poses.isNotEmpty &&
                  bottoms.isNotEmpty &&
                  poses.every((WardrobePose pose) {
                    return bottoms.every((WardrobeItem bottom) {
                      return renderSet.contains(
                        '${pose.id}|${item.id}|${bottom.id}',
                      );
                    });
                  });
            } else if (category == 'bottom') {
              ready =
                  poses.isNotEmpty &&
                  tops.isNotEmpty &&
                  poses.every((WardrobePose pose) {
                    return tops.every((WardrobeItem top) {
                      return renderSet.contains(
                        '${pose.id}|${top.id}|${item.id}',
                      );
                    });
                  });
            } else if (category == 'headwear' || category == 'shoes') {
              ready =
                  poses.isNotEmpty &&
                  poses.every((WardrobePose pose) {
                    return overlaySet.contains(
                      '${pose.id}|$category|${item.id}',
                    );
                  });
            } else {
              ready = item.renderReady;
            }
            return item.copyWith(renderReady: ready);
          })
          .toList(growable: false);
      nextCategories[category] = updatedItems;
    }

    return manifest.copyWith(poses: nextPoses, categories: nextCategories);
  }

  String _normalizedEditableText(String? value) {
    final trimmed = (value ?? '').trim();
    if (trimmed.isEmpty || _isUnknownPlaceholder(trimmed)) {
      return '';
    }
    return trimmed;
  }

  String _humanizeSlug(String value) {
    final words = value
        .trim()
        .replaceAll('-', ' ')
        .split(' ')
        .where((String part) => part.isNotEmpty)
        .toList(growable: false);
    if (words.isEmpty) {
      return value;
    }
    return words
        .map((String word) {
          if (word.length <= 1) {
            return word.toUpperCase();
          }
          return '${word[0].toUpperCase()}${word.substring(1)}';
        })
        .join(' ');
  }

  String _normalizedFieldOrUnknown(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return 'unknown';
    }
    return trimmed;
  }

  List<String> _normalizeTagList(Iterable<String> rawTags) {
    final unique = <String, String>{};
    for (final raw in rawTags) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      unique[trimmed.toLowerCase()] = trimmed;
    }
    final values = unique.values.toList(growable: false);
    values.sort((String left, String right) {
      final lower = left.toLowerCase().compareTo(right.toLowerCase());
      if (lower != 0) {
        return lower;
      }
      return left.compareTo(right);
    });
    return values;
  }

  String _extensionFromRelativePath(String? path, {required String fallback}) {
    final normalized = _normalizeRelativePath(path ?? '');
    if (normalized.isEmpty) {
      return fallback.startsWith('.') ? fallback : '.$fallback';
    }
    final ext = normalized.contains('.')
        ? '.${normalized.split('.').last}'
        : fallback;
    if (!ext.startsWith('.')) {
      return '.$ext';
    }
    return ext;
  }

  Future<void> _moveRelativeAsset({
    required Directory root,
    required String? oldRelativePath,
    required String? newRelativePath,
  }) async {
    final from = _normalizeRelativePath(oldRelativePath ?? '');
    final to = _normalizeRelativePath(newRelativePath ?? '');
    if (from.isEmpty || to.isEmpty || from == to) {
      return;
    }

    final source = _contentPackService.resolveAssetFile(root, from);
    if (!await source.exists()) {
      return;
    }

    final target = _contentPackService.resolveAssetFile(root, to);
    await target.parent.create(recursive: true);
    try {
      await source.rename(target.path);
    } on FileSystemException {
      await target.writeAsBytes(await source.readAsBytes(), flush: true);
      await source.delete();
    }
  }

  Future<void> _cleanupRelativeParents(
    Directory root,
    String relativePath, {
    required String stopAt,
  }) async {
    final normalized = _normalizeRelativePath(relativePath);
    if (normalized.isEmpty) {
      return;
    }
    var current = _contentPackService.resolveAssetFile(root, normalized).parent;
    final stopDirectory = _contentPackService
        .resolveAssetFile(root, stopAt)
        .path;

    for (var i = 0; i < 6; i++) {
      if (current.path == stopDirectory || current.path == root.path) {
        return;
      }
      try {
        await current.delete();
      } on FileSystemException {
        return;
      }
      current = current.parent;
    }
  }

  img.Image _cropSelection(img.Image source, RectSelection selection) {
    final clamped = selection.clamp();
    final x = (clamped.left * source.width).round();
    final y = (clamped.top * source.height).round();
    final width = math.max(1, (clamped.width * source.width).round());
    final height = math.max(1, (clamped.height * source.height).round());

    final cropX = math.max(0, math.min(source.width - 1, x));
    final cropY = math.max(0, math.min(source.height - 1, y));
    final cropW = math.max(1, math.min(source.width - cropX, width));
    final cropH = math.max(1, math.min(source.height - cropY, height));

    return img.copyCrop(
      source,
      x: cropX,
      y: cropY,
      width: cropW,
      height: cropH,
    );
  }

  img.Image _buildThumbnail(
    img.Image source, {
    required int width,
    required int height,
  }) {
    final safeWidth = math.max(1, width);
    final safeHeight = math.max(1, height);

    final scale = math.min(
      safeWidth / source.width,
      safeHeight / source.height,
    );
    final resized = img.copyResize(
      source,
      width: math.max(1, (source.width * scale).round()),
      height: math.max(1, (source.height * scale).round()),
      interpolation: img.Interpolation.cubic,
    );

    final canvas = img.Image(
      width: safeWidth,
      height: safeHeight,
      numChannels: 3,
    );
    img.fill(canvas, color: img.ColorRgb8(245, 245, 245));

    final offsetX = ((safeWidth - resized.width) / 2).round();
    final offsetY = ((safeHeight - resized.height) / 2).round();
    img.compositeImage(canvas, resized, dstX: offsetX, dstY: offsetY);
    return canvas;
  }

  List<int> _encodeImage(img.Image source, String format) {
    switch (format) {
      case 'jpg':
      case 'jpeg':
        return img.encodeJpg(source, quality: 90);
      default:
        return img.encodePng(source);
    }
  }

  String _normalizeImageFormat(String format) {
    final lower = format.toLowerCase();
    if (lower == 'jpg' || lower == 'jpeg') {
      return 'jpg';
    }
    return 'png';
  }

  String _slugify(String value) {
    final lower = value.toLowerCase();
    final cleaned = lower
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return cleaned.isEmpty ? 'item' : cleaned;
  }

  String _makeUniqueSlug(String base, Set<String> existing) {
    var slug = base;
    var counter = 2;
    while (existing.contains(slug)) {
      slug = '$base-$counter';
      counter += 1;
    }
    return slug;
  }

  String _normalizeRelativePath(String value) {
    return value.trim().replaceAll('\\', '/');
  }

  List<String> _collectUniqueSorted(Iterable<String?> values) {
    final unique = <String, String>{};
    for (final value in values) {
      final trimmed = value?.trim() ?? '';
      if (trimmed.isEmpty) {
        continue;
      }
      final key = trimmed.toLowerCase();
      unique.putIfAbsent(key, () => trimmed);
    }

    final result = unique.values.toList(growable: false);
    result.sort((String left, String right) {
      final lowerCompare = left.toLowerCase().compareTo(right.toLowerCase());
      if (lowerCompare != 0) {
        return lowerCompare;
      }
      return left.compareTo(right);
    });
    return result;
  }

  bool _isUnknownPlaceholder(String? value) {
    final normalized = value?.trim().toLowerCase() ?? '';
    return normalized == 'unknown';
  }

  Future<void> _deleteRelativeAssetFile(
    Directory root,
    String relativePath,
  ) async {
    final file = _contentPackService.resolveAssetFile(root, relativePath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<Map<String, dynamic>> _readJsonMap(File file) async {
    if (!await file.exists()) {
      return <String, dynamic>{};
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      // Ignore malformed metadata and replace it with a valid JSON object.
    }
    return <String, dynamic>{};
  }
}

class RectSelection {
  const RectSelection({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  RectSelection clamp() {
    final safeLeft = left.clamp(0.0, 1.0);
    final safeTop = top.clamp(0.0, 1.0);
    final safeWidth = width.clamp(0.02, 1.0);
    final safeHeight = height.clamp(0.02, 1.0);

    final maxWidth = 1.0 - safeLeft;
    final maxHeight = 1.0 - safeTop;

    return RectSelection(
      left: safeLeft,
      top: safeTop,
      width: math.min(safeWidth, maxWidth),
      height: math.min(safeHeight, maxHeight),
    );
  }
}
