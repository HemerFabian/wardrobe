import 'dart:convert';

class UnsupportedSchemaException implements Exception {
  UnsupportedSchemaException(this.schemaVersion);

  final int schemaVersion;

  @override
  String toString() =>
      'Unsupported schema version $schemaVersion. Supported versions are 4 and 5.';
}

class WardrobeClassification {
  const WardrobeClassification({
    required this.provider,
    required this.model,
    required this.classifiedAt,
    required this.promptVersion,
  });

  factory WardrobeClassification.fromJson(Map<String, dynamic> json) {
    return WardrobeClassification(
      provider: _normalizedOrDefault(json['provider'], defaultValue: 'manual'),
      model: _normalizedOrDefault(json['model'], defaultValue: 'n/a'),
      classifiedAt: _normalizedOrDefault(
        json['classified_at'],
        defaultValue: DateTime.now().toUtc().toIso8601String(),
      ),
      promptVersion: _normalizedOrDefault(
        json['prompt_version'],
        defaultValue: 'legacy-v2',
      ),
    );
  }

  final String provider;
  final String model;
  final String classifiedAt;
  final String promptVersion;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'provider': provider,
      'model': model,
      'classified_at': classifiedAt,
      'prompt_version': promptVersion,
    };
  }

  WardrobeClassification copyWith({
    String? provider,
    String? model,
    String? classifiedAt,
    String? promptVersion,
  }) {
    return WardrobeClassification(
      provider: provider ?? this.provider,
      model: model ?? this.model,
      classifiedAt: classifiedAt ?? this.classifiedAt,
      promptVersion: promptVersion ?? this.promptVersion,
    );
  }
}

class WardrobePendingIntakeItem {
  const WardrobePendingIntakeItem({
    required this.id,
    required this.path,
    required this.thumbPath,
    required this.metaPath,
    required this.createdAt,
  });

  factory WardrobePendingIntakeItem.fromJson(Map<String, dynamic> json) {
    return WardrobePendingIntakeItem(
      id: json['id'] as String,
      path: json['path'] as String,
      thumbPath: json['thumb_path'] as String,
      metaPath: json['meta_path'] as String,
      createdAt: _normalizedOrDefault(
        json['created_at'],
        defaultValue: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  final String id;
  final String path;
  final String thumbPath;
  final String metaPath;
  final String createdAt;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'path': path,
      'thumb_path': thumbPath,
      'meta_path': metaPath,
      'created_at': createdAt,
    };
  }
}

class WardrobeRegenerationRequest {
  const WardrobeRegenerationRequest({
    required this.category,
    required this.itemId,
    required this.requestedAt,
  });

  static const Set<String> _allowedCategories = <String>{
    'top',
    'bottom',
    'headwear',
    'shoes',
  };

  factory WardrobeRegenerationRequest.fromJson(Map<String, dynamic> json) {
    final category = _normalizedOrDefault(json['category'], defaultValue: '');
    final itemId = _normalizedOrDefault(json['item_id'], defaultValue: '');
    if (!_allowedCategories.contains(category)) {
      throw const FormatException('Invalid regeneration item category.');
    }
    if (itemId.isEmpty) {
      throw const FormatException('Missing regeneration item id.');
    }
    return WardrobeRegenerationRequest(
      category: category,
      itemId: itemId,
      requestedAt: _normalizedOrDefault(
        json['requested_at'],
        defaultValue: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  final String category;
  final String itemId;
  final String requestedAt;

  String get key => '$category|$itemId';

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'category': category,
      'item_id': itemId,
      'requested_at': requestedAt,
    };
  }

  WardrobeRegenerationRequest copyWith({
    String? category,
    String? itemId,
    String? requestedAt,
  }) {
    return WardrobeRegenerationRequest(
      category: category ?? this.category,
      itemId: itemId ?? this.itemId,
      requestedAt: requestedAt ?? this.requestedAt,
    );
  }
}

enum WardrobeRegenerationTargetType { poseItem, render, overlay }

class WardrobeRegenerationTarget {
  const WardrobeRegenerationTarget.poseItem({
    required this.poseId,
    required this.category,
    required this.itemId,
    required this.requestedAt,
  }) : type = WardrobeRegenerationTargetType.poseItem,
       topId = null,
       bottomId = null;

  const WardrobeRegenerationTarget.render({
    required this.poseId,
    required this.topId,
    required this.bottomId,
    required this.requestedAt,
  }) : type = WardrobeRegenerationTargetType.render,
       category = null,
       itemId = null;

  const WardrobeRegenerationTarget.overlay({
    required this.poseId,
    required this.category,
    required this.itemId,
    required this.requestedAt,
  }) : type = WardrobeRegenerationTargetType.overlay,
       topId = null,
       bottomId = null;

  factory WardrobeRegenerationTarget.fromJson(Map<String, dynamic> json) {
    final rawType = _normalizedOrDefault(json['type'], defaultValue: '');
    final requestedAt = _normalizedOrDefault(
      json['requested_at'],
      defaultValue: DateTime.now().toUtc().toIso8601String(),
    );
    switch (rawType) {
      case 'pose_item':
        final poseId = _normalizedOrDefault(json['pose_id'], defaultValue: '');
        final category = _normalizedOrDefault(
          json['category'],
          defaultValue: '',
        );
        final itemId = _normalizedOrDefault(json['item_id'], defaultValue: '');
        if (poseId.isEmpty ||
            itemId.isEmpty ||
            !WardrobeRegenerationRequest._allowedCategories.contains(
              category,
            )) {
          throw const FormatException('Invalid pose_item regeneration target.');
        }
        return WardrobeRegenerationTarget.poseItem(
          poseId: poseId,
          category: category,
          itemId: itemId,
          requestedAt: requestedAt,
        );
      case 'render':
        final poseId = _normalizedOrDefault(json['pose_id'], defaultValue: '');
        final topId = _normalizedOrDefault(json['top_id'], defaultValue: '');
        final bottomId = _normalizedOrDefault(
          json['bottom_id'],
          defaultValue: '',
        );
        if (poseId.isEmpty || topId.isEmpty || bottomId.isEmpty) {
          throw const FormatException('Invalid render regeneration target.');
        }
        return WardrobeRegenerationTarget.render(
          poseId: poseId,
          topId: topId,
          bottomId: bottomId,
          requestedAt: requestedAt,
        );
      case 'overlay':
        final poseId = _normalizedOrDefault(json['pose_id'], defaultValue: '');
        final category = _normalizedOrDefault(
          json['category'],
          defaultValue: '',
        );
        final itemId = _normalizedOrDefault(json['item_id'], defaultValue: '');
        if (poseId.isEmpty ||
            itemId.isEmpty ||
            !(category == 'headwear' || category == 'shoes')) {
          throw const FormatException('Invalid overlay regeneration target.');
        }
        return WardrobeRegenerationTarget.overlay(
          poseId: poseId,
          category: category,
          itemId: itemId,
          requestedAt: requestedAt,
        );
      default:
        throw const FormatException('Invalid regeneration target type.');
    }
  }

  final WardrobeRegenerationTargetType type;
  final String? poseId;
  final String? category;
  final String? itemId;
  final String? topId;
  final String? bottomId;
  final String requestedAt;

  String get key {
    return switch (type) {
      WardrobeRegenerationTargetType.poseItem =>
        'pose_item|${poseId ?? ''}|${category ?? ''}|${itemId ?? ''}',
      WardrobeRegenerationTargetType.render =>
        'render|${poseId ?? ''}|${topId ?? ''}|${bottomId ?? ''}',
      WardrobeRegenerationTargetType.overlay =>
        'overlay|${poseId ?? ''}|${category ?? ''}|${itemId ?? ''}',
    };
  }

  Map<String, dynamic> toJson() {
    return switch (type) {
      WardrobeRegenerationTargetType.poseItem => <String, dynamic>{
        'type': 'pose_item',
        'pose_id': poseId,
        'category': category,
        'item_id': itemId,
        'requested_at': requestedAt,
      },
      WardrobeRegenerationTargetType.render => <String, dynamic>{
        'type': 'render',
        'pose_id': poseId,
        'top_id': topId,
        'bottom_id': bottomId,
        'requested_at': requestedAt,
      },
      WardrobeRegenerationTargetType.overlay => <String, dynamic>{
        'type': 'overlay',
        'pose_id': poseId,
        'category': category,
        'item_id': itemId,
        'requested_at': requestedAt,
      },
    };
  }
}

class WardrobeOutfitRegenerationRequest {
  const WardrobeOutfitRegenerationRequest({
    required this.poseId,
    required this.topId,
    required this.bottomId,
    this.headwearId,
    this.shoesId,
    required this.requestedAt,
  });

  factory WardrobeOutfitRegenerationRequest.fromJson(
    Map<String, dynamic> json,
  ) {
    final poseId = _normalizedOrDefault(json['pose_id'], defaultValue: '');
    final topId = _normalizedOrDefault(json['top_id'], defaultValue: '');
    final bottomId = _normalizedOrDefault(json['bottom_id'], defaultValue: '');
    if (poseId.isEmpty || topId.isEmpty || bottomId.isEmpty) {
      throw const FormatException('Incomplete regeneration outfit request.');
    }
    return WardrobeOutfitRegenerationRequest(
      poseId: poseId,
      topId: topId,
      bottomId: bottomId,
      headwearId: _optionalNormalized(json['headwear_id'], defaultValue: null),
      shoesId: _optionalNormalized(json['shoes_id'], defaultValue: null),
      requestedAt: _normalizedOrDefault(
        json['requested_at'],
        defaultValue: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  final String poseId;
  final String topId;
  final String bottomId;
  final String? headwearId;
  final String? shoesId;
  final String requestedAt;

  String get key =>
      '$poseId|$topId|$bottomId|${headwearId ?? ''}|${shoesId ?? ''}';

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'pose_id': poseId,
      'top_id': topId,
      'bottom_id': bottomId,
      if (headwearId != null) 'headwear_id': headwearId,
      if (shoesId != null) 'shoes_id': shoesId,
      'requested_at': requestedAt,
    };
  }

  WardrobeOutfitRegenerationRequest copyWith({
    String? poseId,
    String? topId,
    String? bottomId,
    String? headwearId,
    bool clearHeadwearId = false,
    String? shoesId,
    bool clearShoesId = false,
    String? requestedAt,
  }) {
    return WardrobeOutfitRegenerationRequest(
      poseId: poseId ?? this.poseId,
      topId: topId ?? this.topId,
      bottomId: bottomId ?? this.bottomId,
      headwearId: clearHeadwearId ? null : (headwearId ?? this.headwearId),
      shoesId: clearShoesId ? null : (shoesId ?? this.shoesId),
      requestedAt: requestedAt ?? this.requestedAt,
    );
  }

  List<WardrobeRegenerationTarget> toTargets() {
    return <WardrobeRegenerationTarget>[
      WardrobeRegenerationTarget.render(
        poseId: poseId,
        topId: topId,
        bottomId: bottomId,
        requestedAt: requestedAt,
      ),
      if (headwearId != null && headwearId!.isNotEmpty)
        WardrobeRegenerationTarget.overlay(
          poseId: poseId,
          category: 'headwear',
          itemId: headwearId!,
          requestedAt: requestedAt,
        ),
      if (shoesId != null && shoesId!.isNotEmpty)
        WardrobeRegenerationTarget.overlay(
          poseId: poseId,
          category: 'shoes',
          itemId: shoesId!,
          requestedAt: requestedAt,
        ),
    ];
  }
}

class WardrobeRegenerationQueue {
  const WardrobeRegenerationQueue({
    this.items = const <WardrobeRegenerationRequest>[],
    this.targets = const <WardrobeRegenerationTarget>[],
  });

  factory WardrobeRegenerationQueue.fromJson(Map<String, dynamic> json) {
    final itemsByKey = <String, WardrobeRegenerationRequest>{};
    final targetsByKey = <String, WardrobeRegenerationTarget>{};

    final rawItems = json['items'];
    if (rawItems is List<dynamic>) {
      for (final entry in rawItems) {
        if (entry is! Map) {
          continue;
        }
        try {
          final request = WardrobeRegenerationRequest.fromJson(
            Map<String, dynamic>.from(entry),
          );
          itemsByKey[request.key] = request;
        } on FormatException {
          continue;
        }
      }
    }

    final rawTargets = json['targets'];
    if (rawTargets is List<dynamic>) {
      for (final entry in rawTargets) {
        if (entry is! Map) {
          continue;
        }
        try {
          final request = WardrobeRegenerationTarget.fromJson(
            Map<String, dynamic>.from(entry),
          );
          targetsByKey[request.key] = request;
        } on FormatException {
          continue;
        }
      }
    }

    final rawOutfits = json['outfits'];
    if (rawOutfits is List<dynamic>) {
      for (final entry in rawOutfits) {
        if (entry is! Map) {
          continue;
        }
        try {
          final request = WardrobeOutfitRegenerationRequest.fromJson(
            Map<String, dynamic>.from(entry),
          );
          for (final target in request.toTargets()) {
            targetsByKey[target.key] = target;
          }
        } on FormatException {
          continue;
        }
      }
    }

    return WardrobeRegenerationQueue(
      items: itemsByKey.values.toList(growable: false),
      targets: targetsByKey.values.toList(growable: false),
    );
  }

  final List<WardrobeRegenerationRequest> items;
  final List<WardrobeRegenerationTarget> targets;

  bool get isEmpty => items.isEmpty && targets.isEmpty;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'items': items
          .map((WardrobeRegenerationRequest request) => request.toJson())
          .toList(growable: false),
      'targets': targets
          .map((WardrobeRegenerationTarget request) => request.toJson())
          .toList(growable: false),
    };
  }

  WardrobeRegenerationQueue copyWith({
    List<WardrobeRegenerationRequest>? items,
    List<WardrobeRegenerationTarget>? targets,
  }) {
    return WardrobeRegenerationQueue(
      items: items ?? this.items,
      targets: targets ?? this.targets,
    );
  }
}

class WardrobePose {
  const WardrobePose({
    required this.id,
    required this.name,
    this.path,
    this.thumbPath,
    this.metaPath,
    this.neckY,
    this.ankleY,
    required this.renderReady,
  });

  factory WardrobePose.fromJson(Map<String, dynamic> json) {
    return WardrobePose(
      id: json['id'] as String,
      name: json['name'] as String? ?? _humanize(json['id'] as String),
      path: json['path'] as String?,
      thumbPath: json['thumb_path'] as String?,
      metaPath: json['meta_path'] as String?,
      neckY: (json['neck_y'] as num?)?.toDouble(),
      ankleY: (json['ankle_y'] as num?)?.toDouble(),
      renderReady: json['render_ready'] as bool? ?? true,
    );
  }

  final String id;
  final String name;
  final String? path;
  final String? thumbPath;
  final String? metaPath;
  final double? neckY;
  final double? ankleY;
  final bool renderReady;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      if (path != null) 'path': path,
      if (thumbPath != null) 'thumb_path': thumbPath,
      if (metaPath != null) 'meta_path': metaPath,
      if (neckY != null) 'neck_y': neckY,
      if (ankleY != null) 'ankle_y': ankleY,
      'render_ready': renderReady,
    };
  }

  WardrobePose copyWith({
    String? id,
    String? name,
    String? path,
    String? thumbPath,
    String? metaPath,
    double? neckY,
    double? ankleY,
    bool? renderReady,
  }) {
    return WardrobePose(
      id: id ?? this.id,
      name: name ?? this.name,
      path: path ?? this.path,
      thumbPath: thumbPath ?? this.thumbPath,
      metaPath: metaPath ?? this.metaPath,
      neckY: neckY ?? this.neckY,
      ankleY: ankleY ?? this.ankleY,
      renderReady: renderReady ?? this.renderReady,
    );
  }
}

class WardrobeItem {
  const WardrobeItem({
    required this.id,
    this.name = '',
    required this.category,
    this.path,
    this.thumbPath,
    this.metaPath,
    this.subcategory,
    this.colorPrimary,
    this.material,
    this.styleOccasion,
    this.patternDesign,
    this.classification = const WardrobeClassification(
      provider: 'manual',
      model: 'n/a',
      classifiedAt: '1970-01-01T00:00:00Z',
      promptVersion: 'legacy-v2',
    ),
    required this.tags,
    required this.renderReady,
  });

  factory WardrobeItem.fromJson(
    Map<String, dynamic> json, {
    String? category,
    int schemaVersion = 4,
  }) {
    final itemCategory = (json['category'] as String?) ?? category;
    if (itemCategory == null || itemCategory.isEmpty) {
      throw const FormatException(
        'Wardrobe item is missing required category.',
      );
    }
    final itemId = json['id'] as String;
    final itemName = _requiredNonEmptyString(
      json,
      key: 'name',
      context: 'Wardrobe item',
    );
    final classificationPayload = json['classification'];
    final classification = classificationPayload is Map
        ? WardrobeClassification.fromJson(
            Map<String, dynamic>.from(classificationPayload),
          )
        : WardrobeClassification(
            provider: 'manual',
            model: schemaVersion >= 3 ? 'n/a' : 'legacy-v2',
            classifiedAt: DateTime.now().toUtc().toIso8601String(),
            promptVersion: schemaVersion >= 3 ? 'unknown' : 'legacy-v2',
          );

    return WardrobeItem(
      id: itemId,
      name: itemName,
      category: itemCategory,
      path: json['path'] as String?,
      thumbPath: json['thumb_path'] as String?,
      metaPath: json['meta_path'] as String?,
      subcategory: _optionalNormalized(
        json['subcategory'],
        defaultValue: 'unknown',
      ),
      colorPrimary: _optionalNormalized(
        json['color_primary'] ?? json['color'],
        defaultValue: 'unknown',
      ),
      material: _optionalNormalized(json['material'], defaultValue: 'unknown'),
      styleOccasion: _optionalNormalized(
        json['style_occasion'],
        defaultValue: 'unknown',
      ),
      patternDesign: _optionalNormalized(
        json['pattern_design'],
        defaultValue: 'unknown',
      ),
      classification: classification,
      tags: (json['tags'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic value) => value.toString())
          .toList(growable: false),
      renderReady: json['render_ready'] as bool? ?? true,
    );
  }

  final String id;
  final String name;
  final String category;
  final String? path;
  final String? thumbPath;
  final String? metaPath;
  final String? subcategory;
  final String? colorPrimary;
  final String? material;
  final String? styleOccasion;
  final String? patternDesign;
  final WardrobeClassification classification;
  final List<String> tags;
  final bool renderReady;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name.trim().isEmpty ? _humanize(id) : name,
      'category': category,
      if (path != null) 'path': path,
      if (thumbPath != null) 'thumb_path': thumbPath,
      if (metaPath != null) 'meta_path': metaPath,
      'subcategory': subcategory ?? 'unknown',
      'color_primary': colorPrimary ?? 'unknown',
      'material': material ?? 'unknown',
      'style_occasion': styleOccasion ?? 'unknown',
      'pattern_design': patternDesign ?? 'unknown',
      'classification': classification.toJson(),
      'tags': tags,
      'render_ready': renderReady,
    };
  }

  WardrobeItem copyWith({
    String? id,
    String? name,
    String? category,
    String? path,
    String? thumbPath,
    String? metaPath,
    String? subcategory,
    String? colorPrimary,
    String? material,
    String? styleOccasion,
    String? patternDesign,
    WardrobeClassification? classification,
    List<String>? tags,
    bool? renderReady,
  }) {
    return WardrobeItem(
      id: id ?? this.id,
      name: name ?? this.name,
      category: category ?? this.category,
      path: path ?? this.path,
      thumbPath: thumbPath ?? this.thumbPath,
      metaPath: metaPath ?? this.metaPath,
      subcategory: subcategory ?? this.subcategory,
      colorPrimary: colorPrimary ?? this.colorPrimary,
      material: material ?? this.material,
      styleOccasion: styleOccasion ?? this.styleOccasion,
      patternDesign: patternDesign ?? this.patternDesign,
      classification: classification ?? this.classification,
      tags: tags ?? this.tags,
      renderReady: renderReady ?? this.renderReady,
    );
  }
}

class WardrobeImages {
  const WardrobeImages({
    required this.outputSize,
    required this.thumbnailSize,
    required this.imageFormat,
    required this.overlayFormat,
    required this.thumbnailFormat,
  });

  factory WardrobeImages.fromJson(Map<String, dynamic> json) {
    return WardrobeImages(
      outputSize: _toIntTuple(json['output_size']),
      thumbnailSize: _toIntTuple(json['thumbnail_size']),
      imageFormat:
          json['image_format'] as String? ??
          json['base_format'] as String? ??
          'png',
      overlayFormat: json['overlay_format'] as String? ?? 'png',
      thumbnailFormat: json['thumbnail_format'] as String? ?? 'jpg',
    );
  }

  final List<int> outputSize;
  final List<int> thumbnailSize;
  final String imageFormat;
  final String overlayFormat;
  final String thumbnailFormat;

  double get aspectRatio {
    if (outputSize.length != 2 || outputSize[1] == 0) {
      return 9 / 16;
    }
    return outputSize[0] / outputSize[1];
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'output_size': outputSize,
      'thumbnail_size': thumbnailSize,
      'image_format': imageFormat,
      'overlay_format': overlayFormat,
      'thumbnail_format': thumbnailFormat,
    };
  }
}

class WardrobeRender {
  const WardrobeRender({
    required this.poseId,
    required this.topId,
    required this.bottomId,
    required this.path,
    required this.size,
    this.metaPath,
  });

  factory WardrobeRender.fromJson(Map<String, dynamic> json) {
    return WardrobeRender(
      poseId: json['pose_id'] as String,
      topId: json['top_id'] as String,
      bottomId: json['bottom_id'] as String,
      path: json['path'] as String,
      size: _toIntTuple(json['size']),
      metaPath: json['meta_path'] as String?,
    );
  }

  final String poseId;
  final String topId;
  final String bottomId;
  final String path;
  final List<int> size;
  final String? metaPath;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'pose_id': poseId,
      'top_id': topId,
      'bottom_id': bottomId,
      'path': path,
      'size': size,
      if (metaPath != null) 'meta_path': metaPath,
    };
  }
}

class WardrobeOverlay {
  const WardrobeOverlay({
    required this.poseId,
    required this.category,
    required this.itemId,
    required this.path,
    required this.anchorBox,
    this.metaPath,
  });

  factory WardrobeOverlay.fromJson(Map<String, dynamic> json) {
    return WardrobeOverlay(
      poseId: json['pose_id'] as String,
      category: json['category'] as String,
      itemId: json['item_id'] as String,
      path: json['path'] as String,
      anchorBox: _toDoubleTuple(json['anchor_box']),
      metaPath: json['meta_path'] as String?,
    );
  }

  final String poseId;
  final String category;
  final String itemId;
  final String path;
  final List<double> anchorBox;
  final String? metaPath;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'pose_id': poseId,
      'category': category,
      'item_id': itemId,
      'path': path,
      'anchor_box': anchorBox,
      if (metaPath != null) 'meta_path': metaPath,
    };
  }
}

class WardrobeThumb {
  const WardrobeThumb({
    required this.category,
    required this.itemId,
    required this.path,
  });

  factory WardrobeThumb.fromJson(Map<String, dynamic> json) {
    return WardrobeThumb(
      category: json['category'] as String,
      itemId: json['item_id'] as String,
      path: json['path'] as String,
    );
  }

  final String category;
  final String itemId;
  final String path;
}

class WardrobeManifest {
  const WardrobeManifest({
    required this.schemaVersion,
    required this.generatedAt,
    required this.images,
    required this.poses,
    required this.categories,
    required this.intakeQueue,
    required this.renders,
    required this.overlays,
    required this.thumbs,
    this.regeneration = const WardrobeRegenerationQueue(),
  });

  factory WardrobeManifest.empty() {
    return WardrobeManifest(
      schemaVersion: 5,
      generatedAt: DateTime.now().toUtc(),
      images: const WardrobeImages(
        outputSize: <int>[1080, 1920],
        thumbnailSize: <int>[256, 256],
        imageFormat: 'webp',
        overlayFormat: 'png',
        thumbnailFormat: 'jpg',
      ),
      poses: const <WardrobePose>[],
      categories: const <String, List<WardrobeItem>>{
        'headwear': <WardrobeItem>[],
        'top': <WardrobeItem>[],
        'bottom': <WardrobeItem>[],
        'shoes': <WardrobeItem>[],
      },
      intakeQueue: const <WardrobePendingIntakeItem>[],
      renders: const <WardrobeRender>[],
      overlays: const <WardrobeOverlay>[],
      thumbs: const <WardrobeThumb>[],
      regeneration: const WardrobeRegenerationQueue(),
    );
  }

  factory WardrobeManifest.fromString(String jsonString) {
    return WardrobeManifest.fromJson(
      json.decode(jsonString) as Map<String, dynamic>,
    );
  }

  factory WardrobeManifest.fromJson(Map<String, dynamic> json) {
    final schemaVersion = (json['schema_version'] as num?)?.toInt() ?? 0;
    if (schemaVersion != 4 && schemaVersion != 5) {
      throw UnsupportedSchemaException(schemaVersion);
    }
    return _fromJson(json, schemaVersion: schemaVersion);
  }

  final int schemaVersion;
  final DateTime? generatedAt;
  final WardrobeImages images;
  final List<WardrobePose> poses;
  final Map<String, List<WardrobeItem>> categories;
  final List<WardrobePendingIntakeItem> intakeQueue;
  final List<WardrobeRender> renders;
  final List<WardrobeOverlay> overlays;
  final List<WardrobeThumb> thumbs;
  final WardrobeRegenerationQueue regeneration;

  static const List<String> preferredCategoryOrder = <String>[
    'headwear',
    'top',
    'bottom',
    'shoes',
  ];

  List<String> get orderedCategories {
    final categoryIds = categories.keys.toList(growable: true);
    categoryIds.sort((String left, String right) {
      final leftIndex = preferredCategoryOrder.indexOf(left);
      final rightIndex = preferredCategoryOrder.indexOf(right);
      if (leftIndex == -1 && rightIndex == -1) {
        return left.compareTo(right);
      }
      if (leftIndex == -1) {
        return 1;
      }
      if (rightIndex == -1) {
        return -1;
      }
      return leftIndex.compareTo(rightIndex);
    });
    return categoryIds;
  }

  String? get defaultPoseId => poses.isEmpty ? null : poses.first.id;

  List<WardrobeItem> itemsForCategory(String category) {
    return categories[category] ?? const <WardrobeItem>[];
  }

  WardrobeRender? findRender({
    required String poseId,
    required String? topId,
    required String? bottomId,
  }) {
    if (topId == null || bottomId == null) {
      return null;
    }

    for (final render in renders) {
      if (render.poseId == poseId &&
          render.topId == topId &&
          render.bottomId == bottomId) {
        return render;
      }
    }
    return null;
  }

  WardrobeOverlay? findOverlay({
    required String poseId,
    required String category,
    required String? itemId,
  }) {
    if (itemId == null) {
      return null;
    }

    for (final overlay in overlays) {
      if (overlay.poseId == poseId &&
          overlay.category == category &&
          overlay.itemId == itemId) {
        return overlay;
      }
    }
    return null;
  }

  String? findThumbPath({required String category, required String itemId}) {
    for (final item in itemsForCategory(category)) {
      if (item.id == itemId) {
        return item.thumbPath;
      }
    }

    for (final thumb in thumbs) {
      if (thumb.category == category && thumb.itemId == itemId) {
        return thumb.path;
      }
    }
    return null;
  }

  bool get hasMultiplePoses => poses.length > 1;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'schema_version': schemaVersion,
      'generated_at': (generatedAt ?? DateTime.now().toUtc()).toIso8601String(),
      'images': images.toJson(),
      'poses': poses
          .map((WardrobePose pose) => pose.toJson())
          .toList(growable: false),
      'categories': <String, List<Map<String, dynamic>>>{
        for (final entry in categories.entries)
          entry.key: entry.value
              .map((WardrobeItem item) => item.toJson())
              .toList(growable: false),
      },
      'intake_queue': intakeQueue
          .map((WardrobePendingIntakeItem item) => item.toJson())
          .toList(growable: false),
      'renders': renders
          .map((WardrobeRender render) => render.toJson())
          .toList(growable: false),
      'overlays': overlays
          .map((WardrobeOverlay overlay) => overlay.toJson())
          .toList(growable: false),
      'regeneration': regeneration.toJson(),
    };
  }

  Set<String> referencedAssetPaths() {
    final paths = <String>{
      ...renders.map((WardrobeRender render) => render.path),
      ...overlays.map((WardrobeOverlay overlay) => overlay.path),
      ...thumbs.map((WardrobeThumb thumb) => thumb.path),
      ...intakeQueue.map((WardrobePendingIntakeItem item) => item.path),
      ...intakeQueue.map((WardrobePendingIntakeItem item) => item.thumbPath),
      ...intakeQueue.map((WardrobePendingIntakeItem item) => item.metaPath),
    };

    for (final pose in poses) {
      _addIfPresent(paths, pose.path);
      _addIfPresent(paths, pose.thumbPath);
      _addIfPresent(paths, pose.metaPath);
    }

    for (final items in categories.values) {
      for (final item in items) {
        _addIfPresent(paths, item.path);
        _addIfPresent(paths, item.thumbPath);
        _addIfPresent(paths, item.metaPath);
      }
    }

    for (final render in renders) {
      _addIfPresent(paths, render.metaPath);
    }
    for (final overlay in overlays) {
      _addIfPresent(paths, overlay.metaPath);
    }

    return paths;
  }

  WardrobeManifest copyWith({
    int? schemaVersion,
    DateTime? generatedAt,
    WardrobeImages? images,
    List<WardrobePose>? poses,
    Map<String, List<WardrobeItem>>? categories,
    List<WardrobePendingIntakeItem>? intakeQueue,
    List<WardrobeRender>? renders,
    List<WardrobeOverlay>? overlays,
    List<WardrobeThumb>? thumbs,
    WardrobeRegenerationQueue? regeneration,
  }) {
    return WardrobeManifest(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      generatedAt: generatedAt ?? this.generatedAt,
      images: images ?? this.images,
      poses: poses ?? this.poses,
      categories: categories ?? this.categories,
      intakeQueue: intakeQueue ?? this.intakeQueue,
      renders: renders ?? this.renders,
      overlays: overlays ?? this.overlays,
      thumbs: thumbs ?? this.thumbs,
      regeneration: regeneration ?? this.regeneration,
    );
  }

  static WardrobeManifest _fromJson(
    Map<String, dynamic> json, {
    required int schemaVersion,
  }) {
    final poses = (json['poses'] as List<dynamic>? ?? <dynamic>[])
        .map(
          (dynamic pose) =>
              WardrobePose.fromJson(Map<String, dynamic>.from(pose as Map)),
        )
        .toList(growable: false);

    final categories = _parseCategories(
      json['categories'],
      schemaVersion: schemaVersion,
    );

    final intakeQueue = (json['intake_queue'] as List<dynamic>? ?? <dynamic>[])
        .map(
          (dynamic item) => WardrobePendingIntakeItem.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);

    final renders = (json['renders'] as List<dynamic>? ?? <dynamic>[])
        .map(
          (dynamic render) =>
              WardrobeRender.fromJson(Map<String, dynamic>.from(render as Map)),
        )
        .toList(growable: false);

    final overlays = (json['overlays'] as List<dynamic>? ?? <dynamic>[])
        .map(
          (dynamic overlay) => WardrobeOverlay.fromJson(
            Map<String, dynamic>.from(overlay as Map),
          ),
        )
        .toList(growable: false);

    return WardrobeManifest(
      schemaVersion: schemaVersion,
      generatedAt: DateTime.tryParse(json['generated_at'] as String? ?? ''),
      images: WardrobeImages.fromJson(
        Map<String, dynamic>.from(
          (json['images'] as Map?) ??
              const <String, Object>{
                'output_size': <int>[1080, 1920],
                'thumbnail_size': <int>[256, 256],
                'image_format': 'webp',
                'overlay_format': 'png',
                'thumbnail_format': 'jpg',
              },
        ),
      ),
      poses: poses,
      categories: categories,
      intakeQueue: intakeQueue,
      renders: renders,
      overlays: overlays,
      thumbs: const <WardrobeThumb>[],
      regeneration: json['regeneration'] is Map
          ? WardrobeRegenerationQueue.fromJson(
              Map<String, dynamic>.from(json['regeneration'] as Map),
            )
          : const WardrobeRegenerationQueue(),
    );
  }
}

Map<String, List<WardrobeItem>> _parseCategories(
  dynamic rawCategories, {
  required int schemaVersion,
}) {
  if (rawCategories is! Map) {
    throw const FormatException('Manifest categories must be an object map.');
  }

  final result = <String, List<WardrobeItem>>{};
  for (final entry in rawCategories.entries) {
    final categoryId = entry.key.toString();
    final rawItems = entry.value;

    if (rawItems is! List) {
      throw FormatException(
        'Manifest category "$categoryId" must contain a list of items.',
      );
    }

    final items = rawItems
        .map(
          (dynamic item) => WardrobeItem.fromJson(
            Map<String, dynamic>.from(item as Map),
            category: categoryId,
            schemaVersion: schemaVersion,
          ),
        )
        .toList(growable: false);
    result[categoryId] = items;
  }

  return result;
}

List<int> _toIntTuple(dynamic rawTuple) {
  if (rawTuple is! List || rawTuple.length < 2) {
    return const <int>[0, 0];
  }

  return <int>[(rawTuple[0] as num).toInt(), (rawTuple[1] as num).toInt()];
}

List<double> _toDoubleTuple(dynamic rawTuple) {
  if (rawTuple is! List || rawTuple.length < 4) {
    return const <double>[0, 0, 0, 0];
  }

  return <double>[
    (rawTuple[0] as num).toDouble(),
    (rawTuple[1] as num).toDouble(),
    (rawTuple[2] as num).toDouble(),
    (rawTuple[3] as num).toDouble(),
  ];
}

String _humanize(String value) {
  final words = value.replaceAll('-', ' ').split(' ');
  return words
      .map((String word) {
        if (word.isEmpty) {
          return word;
        }
        return '${word[0].toUpperCase()}${word.substring(1)}';
      })
      .join(' ');
}

void _addIfPresent(Set<String> target, String? value) {
  if (value == null || value.isEmpty) {
    return;
  }
  target.add(value);
}

String _requiredNonEmptyString(
  Map<String, dynamic> json, {
  required String key,
  required String context,
}) {
  final raw = json[key];
  final value = (raw?.toString() ?? '').trim();
  if (value.isEmpty) {
    throw FormatException('$context is missing required $key.');
  }
  return value;
}

String _normalizedOrDefault(dynamic value, {required String defaultValue}) {
  final text = (value?.toString() ?? '').trim();
  return text.isEmpty ? defaultValue : text;
}

String? _optionalNormalized(dynamic value, {required String? defaultValue}) {
  final text = (value?.toString() ?? '').trim();
  if (text.isEmpty) {
    return defaultValue;
  }
  return text;
}
