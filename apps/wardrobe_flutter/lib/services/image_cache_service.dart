import 'dart:io';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class ImageCacheService {
  ImageCacheService({int? maxCachedPaths})
    : _maxCachedPaths = maxCachedPaths ?? 256;

  final int _maxCachedPaths;
  final LinkedHashSet<String> _warmedPaths = LinkedHashSet<String>();
  final Map<String, Future<void>> _pendingWarmups = <String, Future<void>>{};

  Future<void> warmPaths(
    BuildContext context,
    Iterable<String> paths, {
    bool force = false,
  }) async {
    for (final path in paths) {
      if (!force && _warmedPaths.contains(path)) {
        continue;
      }

      final pendingWarmup = _pendingWarmups[path];
      if (pendingWarmup != null) {
        await pendingWarmup;
        if (!context.mounted) {
          return;
        }
        _rememberPath(path);
        continue;
      }

      if (!context.mounted) {
        return;
      }
      final warmup = _warmPath(context, path);
      _pendingWarmups[path] = warmup;
      try {
        await warmup;
        if (!context.mounted) {
          return;
        }
        _rememberPath(path);
      } on Object {
        // Skip invalid or unreadable images so one bad file does not block warmup.
      } finally {
        if (identical(_pendingWarmups[path], warmup)) {
          _pendingWarmups.remove(path);
        }
      }
    }
  }

  Future<void> _warmPath(BuildContext context, String path) async {
    if (path.startsWith('data:')) {
      await precacheImage(NetworkImage(path), context);
      return;
    }
    if (!kIsWeb && File(path).existsSync()) {
      await precacheImage(FileImage(File(path)), context);
    }
  }

  void _rememberPath(String path) {
    _warmedPaths.remove(path);
    _warmedPaths.add(path);
    if (_warmedPaths.length > _maxCachedPaths) {
      _warmedPaths.remove(_warmedPaths.first);
    }
  }

  void clear() {
    _warmedPaths.clear();
    _pendingWarmups.clear();
  }
}
