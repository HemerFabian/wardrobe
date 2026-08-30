import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/favorite_outfit.dart';

class FavoritesService {
  final Map<String, FavoriteOutfit> _inMemoryWebFavorites =
      <String, FavoriteOutfit>{};

  Future<List<FavoriteOutfit>> loadFavorites({
    required Directory packRoot,
  }) async {
    if (kIsWeb) {
      return _sortedByCreatedAtDescending(_inMemoryWebFavorites.values);
    }

    final directory = _favoritesDirectory(packRoot);
    if (!await directory.exists()) {
      return const <FavoriteOutfit>[];
    }

    final deduplicated = <String, FavoriteOutfit>{};
    final entities = directory.listSync(followLinks: false);
    for (final entity in entities) {
      if (entity is! File) {
        continue;
      }
      final lowerPath = entity.path.toLowerCase();
      if (!lowerPath.endsWith('.yaml') && !lowerPath.endsWith('.yml')) {
        continue;
      }

      try {
        final raw = await entity.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          continue;
        }
        final favorite = FavoriteOutfit.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        final existing = deduplicated[favorite.key];
        if (existing == null ||
            favorite.createdAt.isAfter(existing.createdAt)) {
          deduplicated[favorite.key] = favorite;
        }
      } catch (_) {
        // Ignore malformed favorite files to keep loading resilient.
      }
    }

    return _sortedByCreatedAtDescending(deduplicated.values);
  }

  Future<void> saveFavorite({
    required Directory packRoot,
    required FavoriteOutfit favorite,
    required List<String> orderedCategories,
  }) async {
    if (kIsWeb) {
      _inMemoryWebFavorites[favorite.key] = favorite;
      return;
    }

    final directory = _favoritesDirectory(packRoot);
    await directory.create(recursive: true);

    final file = File(
      p.join(directory.path, '${_keyToFileStem(favorite.key)}.yaml'),
    );
    final payload = const JsonEncoder.withIndent(
      '  ',
    ).convert(favorite.toJson(orderedCategories: orderedCategories));
    await file.writeAsString(payload, flush: true);
  }

  Future<void> removeFavorite({
    required Directory packRoot,
    required String favoriteKey,
  }) async {
    if (kIsWeb) {
      _inMemoryWebFavorites.remove(favoriteKey);
      return;
    }

    final directory = _favoritesDirectory(packRoot);
    if (!await directory.exists()) {
      return;
    }

    final directFile = File(
      p.join(directory.path, '${_keyToFileStem(favoriteKey)}.yaml'),
    );
    if (await directFile.exists()) {
      await directFile.delete();
    }

    final entities = directory.listSync(followLinks: false);
    for (final entity in entities) {
      if (entity is! File) {
        continue;
      }
      final lowerPath = entity.path.toLowerCase();
      if (!lowerPath.endsWith('.yaml') && !lowerPath.endsWith('.yml')) {
        continue;
      }
      try {
        final raw = await entity.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          continue;
        }
        final favorite = FavoriteOutfit.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        if (favorite.key == favoriteKey) {
          await entity.delete();
        }
      } catch (_) {
        // Ignore malformed favorite files while deleting.
      }
    }
  }

  Directory _favoritesDirectory(Directory packRoot) {
    return Directory(p.join(packRoot.path, 'favorites'));
  }

  List<FavoriteOutfit> _sortedByCreatedAtDescending(
    Iterable<FavoriteOutfit> favorites,
  ) {
    final sorted = favorites.toList(growable: false);
    sorted.sort(
      (FavoriteOutfit left, FavoriteOutfit right) =>
          right.createdAt.compareTo(left.createdAt),
    );
    return sorted;
  }

  String _keyToFileStem(String key) {
    return base64UrlEncode(utf8.encode(key)).replaceAll('=', '');
  }
}
