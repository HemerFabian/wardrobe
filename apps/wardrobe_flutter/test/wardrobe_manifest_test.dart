import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wardrobe_flutter/models/wardrobe.dart';

void main() {
  test('parses built-in wardrobe manifest', () {
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
    final manifest = WardrobeManifest.fromString(
      utf8.decode(manifestEntry.content as List<int>),
    );

    expect(manifest.schemaVersion, 5);
    expect(manifest.poses, isNotEmpty);
    expect(manifest.categories.keys, containsAll(<String>['top', 'bottom']));
    expect(manifest.renders, isNotEmpty);
  });

  test('rejects unsupported schema versions', () {
    const json =
        '{"schema_version":99,"poses":[{"id":"pose"}],"categories":{},"renders":[],"overlays":[]}';
    expect(
      () => WardrobeManifest.fromString(json),
      throwsA(isA<UnsupportedSchemaException>()),
    );
  });

  test('rejects legacy schema version 1', () {
    const json = '''
{
  "schema_version": 1,
  "poses": [{"id": "pose-1"}],
  "categories": {},
  "renders": [],
  "overlays": []
}
''';
    expect(
      () => WardrobeManifest.fromString(json),
      throwsA(isA<UnsupportedSchemaException>()),
    );
  });

  test('parses schema v4 metadata fields', () {
    const json = '''
{
  "schema_version": 4,
  "images": {
    "output_size": [1080, 1920],
    "thumbnail_size": [256, 256],
    "image_format": "webp",
    "overlay_format": "png",
    "thumbnail_format": "jpg"
  },
  "poses": [
    {
      "id": "pose-1",
      "name": "Pose 1",
      "path": "poses/pose-1/pose.png",
      "thumb_path": "poses/pose-1/thumb.jpg",
      "meta_path": "poses/pose-1/pose.yaml",
      "neck_y": 0.22,
      "ankle_y": 0.88,
      "render_ready": false
    }
  ],
  "categories": {
    "top": [
      {
        "id": "item-1",
        "name": "Item 1",
        "category": "top",
        "path": "items/top/item-1/image.png",
        "thumb_path": "items/top/item-1/thumb.jpg",
        "meta_path": "items/top/item-1/item.yaml",
        "subcategory": "Hoodie",
        "color_primary": "Blue",
        "material": "Cotton",
        "style_occasion": "Casual",
        "pattern_design": "Solid",
        "classification": {
          "provider": "ollama",
          "model": "qwen3-vl:8b",
          "classified_at": "2026-02-21T10:00:00Z",
          "prompt_version": "2026-02-21-v1"
        },
        "tags": ["winter"],
        "render_ready": false
      }
    ]
  },
  "intake_queue": [
    {
      "id": "pending-1",
      "path": "items/intake_queue/pending-1/image.png",
      "thumb_path": "items/intake_queue/pending-1/thumb.jpg",
      "meta_path": "items/intake_queue/pending-1/item.yaml",
      "created_at": "2026-02-21T09:00:00Z"
    }
  ],
  "renders": [],
  "overlays": []
}
''';

    final manifest = WardrobeManifest.fromString(json);

    expect(manifest.schemaVersion, 4);
    expect(manifest.poses.single.neckY, closeTo(0.22, 0.0001));
    expect(manifest.itemsForCategory('top').single.name, 'Item 1');
    expect(manifest.itemsForCategory('top').single.renderReady, isFalse);
    expect(manifest.itemsForCategory('top').single.material, 'Cotton');
    expect(manifest.intakeQueue.single.id, 'pending-1');
  });

  test('parses regeneration queue and drops invalid entries', () {
    const json = '''
{
  "schema_version": 5,
  "images": {
    "output_size": [1080, 1920],
    "thumbnail_size": [256, 256],
    "image_format": "webp",
    "overlay_format": "png",
    "thumbnail_format": "jpg"
  },
  "poses": [],
  "categories": {
    "headwear": [],
    "top": [],
    "bottom": [],
    "shoes": []
  },
  "intake_queue": [],
  "regeneration": {
    "items": [
      {
        "category": "top",
        "item_id": "hoodie",
        "requested_at": "2026-03-01T12:34:56Z"
      },
      {
        "category": "invalid",
        "item_id": "bad",
        "requested_at": "2026-03-01T12:35:56Z"
      }
    ],
    "targets": [
      {
        "type": "pose_item",
        "pose_id": "pose-1",
        "category": "top",
        "item_id": "hoodie",
        "requested_at": "2026-03-01T12:35:56Z"
      },
      {
        "type": "overlay",
        "pose_id": "pose-1",
        "category": "top",
        "item_id": "bad",
        "requested_at": "2026-03-01T12:35:57Z"
      }
    ],
    "outfits": [
      {
        "pose_id": "pose-1",
        "top_id": "hoodie",
        "bottom_id": "jeans",
        "headwear_id": "cap",
        "requested_at": "2026-03-01T12:36:56Z"
      },
      {
        "pose_id": "",
        "top_id": "hoodie",
        "bottom_id": "jeans",
        "requested_at": "2026-03-01T12:37:56Z"
      }
    ]
  },
  "renders": [],
  "overlays": []
}
''';

    final manifest = WardrobeManifest.fromString(json);

    expect(manifest.regeneration.items, hasLength(1));
    expect(manifest.regeneration.items.single.category, 'top');
    expect(manifest.regeneration.targets, hasLength(3));
    expect(
      manifest.regeneration.targets.any(
        (WardrobeRegenerationTarget target) =>
            target.type == WardrobeRegenerationTargetType.poseItem &&
            target.category == 'top' &&
            target.itemId == 'hoodie',
      ),
      isTrue,
    );
    expect(
      manifest.regeneration.targets.any(
        (WardrobeRegenerationTarget target) =>
            target.type == WardrobeRegenerationTargetType.render &&
            target.poseId == 'pose-1' &&
            target.topId == 'hoodie' &&
            target.bottomId == 'jeans',
      ),
      isTrue,
    );
    expect(
      manifest.regeneration.targets.any(
        (WardrobeRegenerationTarget target) =>
            target.type == WardrobeRegenerationTargetType.overlay &&
            target.category == 'headwear' &&
            target.itemId == 'cap',
      ),
      isTrue,
    );

    final encoded = manifest.toJson();
    final regeneration = encoded['regeneration'] as Map<String, dynamic>;
    expect((regeneration['items'] as List<dynamic>).length, 1);
    expect((regeneration['targets'] as List<dynamic>).length, 3);
    expect(regeneration.containsKey('outfits'), isFalse);
  });
}
