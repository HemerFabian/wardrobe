import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:wardrobe_flutter/models/favorite_outfit.dart';
import 'package:wardrobe_flutter/services/favorites_service.dart';

void main() {
  late Directory tempRoot;
  late FavoritesService service;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('favorites_service_test_');
    service = FavoritesService();
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('save, load and remove favorite files in favorites folder', () async {
    final selection = <String, String?>{
      'headwear': null,
      'top': 'lila-pullover',
      'bottom': 'hellgraue-jogginghose',
      'shoes': null,
    };
    final categories = selection.keys.toList(growable: false);
    final favorite = FavoriteOutfit(
      key: FavoriteOutfit.buildKey(
        selection: selection,
        categories: categories,
      ),
      selection: selection,
      createdAt: DateTime.utc(2026, 2, 8, 10, 30),
    );

    await service.saveFavorite(
      packRoot: tempRoot,
      favorite: favorite,
      orderedCategories: categories,
    );

    final loaded = await service.loadFavorites(packRoot: tempRoot);
    expect(loaded, hasLength(1));
    expect(loaded.first.key, favorite.key);
    expect(loaded.first.selection['top'], 'lila-pullover');

    await service.removeFavorite(packRoot: tempRoot, favoriteKey: favorite.key);
    final reloaded = await service.loadFavorites(packRoot: tempRoot);
    expect(reloaded, isEmpty);
  });

  test(
    'removeFavorite deletes legacy pose-bound favorites after key migration',
    () async {
      final selection = <String, String?>{
        'headwear': null,
        'top': 'lila-pullover',
        'bottom': 'hellgraue-jogginghose',
        'shoes': null,
      };
      final categories = selection.keys.toList(growable: false);
      final migratedKey = FavoriteOutfit.buildKey(
        selection: selection,
        categories: categories,
      );

      final legacyBuffer = StringBuffer(
        'pose:${Uri.encodeComponent('pose-1')}',
      );
      for (final category in categories) {
        final selected = selection[category];
        legacyBuffer
          ..write('|')
          ..write(Uri.encodeComponent(category))
          ..write('=')
          ..write(selected == null ? '~' : Uri.encodeComponent(selected));
      }
      final legacyPayload = <String, dynamic>{
        'key': legacyBuffer.toString(),
        'pose_id': 'pose-1',
        'selection': selection,
        'categories': categories,
        'created_at': DateTime.utc(2026, 2, 8, 10, 30).toIso8601String(),
      };

      final favoritesDir = Directory(p.join(tempRoot.path, 'favorites'))
        ..createSync(recursive: true);
      final legacyFile = File(p.join(favoritesDir.path, 'legacy.yaml'));
      await legacyFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(legacyPayload),
      );

      final loaded = await service.loadFavorites(packRoot: tempRoot);
      expect(loaded, hasLength(1));
      expect(loaded.first.key, migratedKey);

      await service.removeFavorite(
        packRoot: tempRoot,
        favoriteKey: migratedKey,
      );

      final reloaded = await service.loadFavorites(packRoot: tempRoot);
      expect(reloaded, isEmpty);
      expect(await legacyFile.exists(), isFalse);
    },
  );
}
