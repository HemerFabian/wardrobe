import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/wardrobe.dart';

enum ImportFailureReason {
  missingFile,
  invalidZip,
  missingManifest,
  unsupportedSchema,
  invalidManifest,
  missingAssets,
  ioError,
}

class ImportProgress {
  const ImportProgress({
    required this.value,
    required this.phase,
    this.processed,
    this.total,
    this.estimatedRemaining,
  });

  final double value;
  final String phase;
  final int? processed;
  final int? total;
  final Duration? estimatedRemaining;
}

class ImportResult {
  const ImportResult._({
    required this.success,
    this.reason,
    this.message,
    this.manifest,
    this.packRoot,
    this.assetPathOverrides,
  });

  factory ImportResult.success({
    required WardrobeManifest manifest,
    required Directory packRoot,
    Map<String, String>? assetPathOverrides,
  }) {
    return ImportResult._(
      success: true,
      manifest: manifest,
      packRoot: packRoot,
      assetPathOverrides: assetPathOverrides,
    );
  }

  factory ImportResult.failure({
    required ImportFailureReason reason,
    required String message,
  }) {
    return ImportResult._(success: false, reason: reason, message: message);
  }

  final bool success;
  final ImportFailureReason? reason;
  final String? message;
  final WardrobeManifest? manifest;
  final Directory? packRoot;
  final Map<String, String>? assetPathOverrides;
}

class ActiveContentPack {
  const ActiveContentPack({
    required this.root,
    required this.manifest,
    this.assetPathOverrides,
  });

  final Directory root;
  final WardrobeManifest manifest;
  final Map<String, String>? assetPathOverrides;
}

class ContentPackService {
  ContentPackService({
    Future<Directory> Function()? appDirectoryProvider,
    Future<Directory?> Function()? downloadsDirectoryProvider,
    this.maxZipBytes = 512 * 1024 * 1024,
    this.maxArchiveEntries = 10000,
    this.maxArchiveUncompressedBytes = 1024 * 1024 * 1024,
    this.maxArchiveEntryBytes = 256 * 1024 * 1024,
  }) : _appDirectoryProvider =
           appDirectoryProvider ?? getApplicationSupportDirectory,
       _downloadsDirectoryProvider =
           downloadsDirectoryProvider ?? getDownloadsDirectory,
       assert(maxZipBytes > 0),
       assert(maxArchiveEntries > 0),
       assert(maxArchiveUncompressedBytes > 0),
       assert(maxArchiveEntryBytes > 0);

  static const MethodChannel _workspaceExportChannel = MethodChannel(
    'app.wardrobe.viewer/workspace_export',
  );

  final Future<Directory> Function() _appDirectoryProvider;
  final Future<Directory?> Function() _downloadsDirectoryProvider;
  final int maxZipBytes;
  final int maxArchiveEntries;
  final int maxArchiveUncompressedBytes;
  final int maxArchiveEntryBytes;

  Future<ImportResult> importZip(
    File zipFile, {
    void Function(ImportProgress progress)? onProgress,
  }) async {
    final emitProgress = _createProgressEmitter(onProgress);
    emitProgress(value: 0.02, phase: 'Reading ZIP');
    Archive? archive;
    InputFileStream? input;

    try {
      final resolvedZipFile = await _resolveZipFile(zipFile);
      if (!await resolvedZipFile.exists()) {
        return ImportResult.failure(
          reason: ImportFailureReason.missingFile,
          message: 'ZIP file does not exist: ${zipFile.path}',
        );
      }
      if (await resolvedZipFile.length() > maxZipBytes) {
        return _archiveLimitFailure(
          'ZIP file exceeds the ${_formatByteLimit(maxZipBytes)} input limit.',
        );
      }

      try {
        input = InputFileStream(resolvedZipFile.path);
        archive = ZipDecoder().decodeStream(input, verify: true);
      } on Exception catch (error) {
        return ImportResult.failure(
          reason: ImportFailureReason.invalidZip,
          message: 'Invalid ZIP archive: $error',
        );
      }
      final limitFailure = _validateArchiveLimits(archive);
      if (limitFailure != null) {
        return limitFailure;
      }
      if (kIsWeb) {
        return await _importArchiveInMemory(archive, emitProgress);
      }
      return await _importArchive(archive, emitProgress);
    } on FileSystemException catch (error) {
      return ImportResult.failure(
        reason: ImportFailureReason.ioError,
        message: 'I/O error while importing ZIP: $error',
      );
    } on UnsupportedError catch (error) {
      return ImportResult.failure(
        reason: ImportFailureReason.ioError,
        message:
            'Import from filesystem paths is not supported on this platform: $error',
      );
    } finally {
      if (archive != null) {
        await archive.clear();
      }
      if (input != null) {
        await input.close();
      }
    }
  }

  Future<ImportResult> importZipBytes(
    List<int> zipBytes, {
    void Function(ImportProgress progress)? onProgress,
  }) async {
    final emitProgress = _createProgressEmitter(onProgress);
    emitProgress(value: 0.02, phase: 'Reading ZIP');
    Archive? archive;

    try {
      if (zipBytes.length > maxZipBytes) {
        return _archiveLimitFailure(
          'ZIP data exceeds the ${_formatByteLimit(maxZipBytes)} input limit.',
        );
      }
      try {
        archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
      } on Exception catch (error) {
        return ImportResult.failure(
          reason: ImportFailureReason.invalidZip,
          message: 'Invalid ZIP archive: $error',
        );
      }
      final limitFailure = _validateArchiveLimits(archive);
      if (limitFailure != null) {
        return limitFailure;
      }
      if (kIsWeb) {
        return await _importArchiveInMemory(archive, emitProgress);
      }
      return await _importArchive(archive, emitProgress);
    } on FileSystemException catch (error) {
      return ImportResult.failure(
        reason: ImportFailureReason.ioError,
        message: 'I/O error while importing ZIP: $error',
      );
    } on UnsupportedError catch (error) {
      return ImportResult.failure(
        reason: ImportFailureReason.ioError,
        message:
            'Import from filesystem paths is not supported on this platform: $error',
      );
    } finally {
      if (archive != null) {
        await archive.clear();
      }
    }
  }

  Future<ActiveContentPack?> loadActivePack() async {
    if (kIsWeb) {
      return null;
    }

    final activeDir = await _activePackDirectory();
    final manifestFile = File(p.join(activeDir.path, 'wardrobe.json'));

    if (!await manifestFile.exists()) {
      return null;
    }

    final manifest = WardrobeManifest.fromString(
      await manifestFile.readAsString(),
    );
    return ActiveContentPack(root: activeDir, manifest: manifest);
  }

  Future<WardrobeManifest?> loadActiveManifest() async {
    final pack = await loadActivePack();
    return pack?.manifest;
  }

  Future<ActiveContentPack> ensureActiveWorkspace() async {
    final existing = await loadActivePack();
    if (existing != null) {
      return existing;
    }
    if (kIsWeb) {
      throw UnsupportedError(
        'Local workspace editing is not supported on web.',
      );
    }

    final activeDir = await _activePackDirectory();
    await activeDir.create(recursive: true);

    final manifest = WardrobeManifest.empty();
    await _writeManifest(activeDir, manifest);
    return ActiveContentPack(root: activeDir, manifest: manifest);
  }

  Future<ActiveContentPack> saveActiveManifest(
    WardrobeManifest manifest,
  ) async {
    if (kIsWeb) {
      throw UnsupportedError(
        'Saving workspace manifest is not supported on web.',
      );
    }
    final activeDir = await _activePackDirectory();
    await activeDir.create(recursive: true);
    await _writeManifest(activeDir, manifest);
    return ActiveContentPack(root: activeDir, manifest: manifest);
  }

  Future<File> exportActiveWorkspaceZip({
    String fileName = 'wardrobe_workspace.zip',
    String? outputFilePath,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Workspace export is not supported on web.');
    }

    final outFile = outputFilePath != null && outputFilePath.trim().isNotEmpty
        ? File(outputFilePath)
        : await _defaultExportFile(fileName: fileName);
    await outFile.parent.create(recursive: true);
    await _writeWorkspaceExportZip(outFile);
    return outFile;
  }

  Future<Uint8List> exportActiveWorkspaceZipBytes() async {
    if (kIsWeb) {
      throw UnsupportedError('Workspace export is not supported on web.');
    }

    final tempFile = await _temporaryExportFile();

    try {
      await _writeWorkspaceExportZip(tempFile);
      return await tempFile.readAsBytes();
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  Future<String?> exportActiveWorkspaceWithPicker({
    String fileName = 'wardrobe_workspace.zip',
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Workspace export is not supported on web.');
    }
    if (!Platform.isAndroid) {
      final file = await exportActiveWorkspaceZip(fileName: fileName);
      return file.path;
    }

    final tempFile = await _temporaryExportFile(fileName: fileName);
    try {
      await _writeWorkspaceExportZip(tempFile);
      return await _workspaceExportChannel.invokeMethod<String>(
        'saveWorkspaceZip',
        <String, Object?>{'sourcePath': tempFile.path, 'fileName': fileName},
      );
    } on MissingPluginException {
      final file = await exportActiveWorkspaceZip(fileName: fileName);
      return file.path;
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  Future<void> clearActivePack() async {
    if (kIsWeb) {
      return;
    }
    final activeDir = await _activePackDirectory();
    if (await activeDir.exists()) {
      await activeDir.delete(recursive: true);
    }
  }

  File resolveAssetFile(Directory packRoot, String relativePath) {
    final normalized = _safeRelativePath(relativePath);
    if (normalized == null ||
        normalized != relativePath.replaceAll('\\', '/')) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'Unsafe asset path',
      );
    }
    return File(p.join(packRoot.path, normalized));
  }

  Future<File> _resolveZipFile(File zipFile) async {
    if (await zipFile.exists()) {
      return zipFile;
    }

    final candidates = <String>{};
    final path = zipFile.path;
    if (path.startsWith('/sdcard/')) {
      candidates.add(path.replaceFirst('/sdcard/', '/storage/emulated/0/'));
    } else if (path.startsWith('/storage/emulated/0/')) {
      candidates.add(path.replaceFirst('/storage/emulated/0/', '/sdcard/'));
    }

    if (Platform.isAndroid) {
      final externalDir = await getExternalStorageDirectory();
      if (externalDir != null) {
        candidates.add(p.join(externalDir.path, p.basename(path)));
      }
    }

    for (final candidate in candidates) {
      final candidateFile = File(candidate);
      if (await candidateFile.exists()) {
        return candidateFile;
      }
    }
    return zipFile;
  }

  Future<void> _writeWorkspaceExportZip(File outputFile) async {
    final exportEntries = await _workspaceExportEntries();
    final encoder = ZipFileEncoder();
    encoder.create(outputFile.path);

    try {
      final manifestEntry = ArchiveFile.string(
        'wardrobe.json',
        exportEntries.manifestContents,
      );
      manifestEntry.lastModTime =
          (await exportEntries.manifestFile.lastModified())
              .millisecondsSinceEpoch ~/
          1000;
      manifestEntry.mode = (await exportEntries.manifestFile.stat()).mode;
      encoder.addArchiveFile(manifestEntry);

      for (final entry in exportEntries.assetFiles) {
        await encoder.addFile(entry.value, entry.key);
      }
    } finally {
      await encoder.close();
    }
  }

  Future<_WorkspaceExportEntries> _workspaceExportEntries() async {
    final activeDir = await _activePackDirectory();
    if (!await activeDir.exists()) {
      throw const FileSystemException('No active workspace to export.');
    }

    final manifestFile = File(p.join(activeDir.path, 'wardrobe.json'));
    if (!await manifestFile.exists()) {
      throw const FileSystemException(
        'No active workspace manifest to export.',
      );
    }

    final manifestContents = await manifestFile.readAsString();
    final manifest = WardrobeManifest.fromString(manifestContents);
    final assetFilesByPath = <String, File>{};
    final referencedPaths = manifest.referencedAssetPaths().toList()..sort();

    for (final referencedPath in referencedPaths) {
      final relativePath = _safeRelativePath(referencedPath);
      if (relativePath == null) {
        throw FileSystemException(
          'Invalid workspace export path.',
          referencedPath,
        );
      }
      final file = resolveAssetFile(activeDir, relativePath);
      if (!await file.exists()) {
        throw FileSystemException(
          'Missing workspace asset referenced by wardrobe.json.',
          file.path,
        );
      }
      assetFilesByPath[relativePath] = file;
    }

    final favoritesDir = Directory(p.join(activeDir.path, 'favorites'));
    if (await favoritesDir.exists()) {
      await for (final entity in favoritesDir.list(recursive: true)) {
        if (entity is! File) {
          continue;
        }
        final relativePath = _safeRelativePath(
          p.relative(entity.path, from: activeDir.path),
        );
        if (relativePath == null) {
          throw FileSystemException(
            'Invalid workspace export path.',
            entity.path,
          );
        }
        assetFilesByPath[relativePath] = entity;
      }
    }

    return _WorkspaceExportEntries(
      manifestFile: manifestFile,
      manifestContents: manifestContents,
      assetFiles: assetFilesByPath.entries.toList()
        ..sort((left, right) => left.key.compareTo(right.key)),
    );
  }

  Future<File> _defaultExportFile({required String fileName}) async {
    final exportDir = await _defaultExportDirectory();
    await exportDir.create(recursive: true);
    return File(p.join(exportDir.path, fileName));
  }

  Future<File> _temporaryExportFile({
    String fileName = 'wardrobe_workspace.zip',
  }) async {
    final appDir = await _appDirectoryProvider();
    final tempDir = await Directory(
      p.join(appDir.path, 'wardrobe_flutter', 'export_tmp'),
    ).create(recursive: true);
    final baseName = p.basenameWithoutExtension(fileName);
    final extension = p.extension(fileName);
    final suffix = DateTime.now().microsecondsSinceEpoch;
    return File(p.join(tempDir.path, '${baseName}_$suffix$extension'));
  }

  Future<Directory> _defaultExportDirectory() async {
    try {
      final downloadsDir = await _downloadsDirectoryProvider();
      if (downloadsDir != null) {
        return downloadsDir;
      }
    } on Object {
      // Ignore plugin/platform failures and fall back to app storage.
    }
    return _appDirectoryProvider();
  }

  Future<ImportResult?> _extractArchive({
    required Archive archive,
    required Directory destination,
    void Function(int processed, int total)? onStep,
  }) async {
    final total = archive.files.isEmpty ? 1 : archive.files.length;
    var processed = 0;
    onStep?.call(processed, total);

    for (final file in archive.files) {
      final safePath = _safeRelativePath(file.name);
      if (safePath == null) {
        return ImportResult.failure(
          reason: ImportFailureReason.invalidZip,
          message: 'ZIP contains an invalid file path: ${file.name}',
        );
      }

      final outputPath = p.join(destination.path, safePath);
      if (file.isFile) {
        final outputFile = File(outputPath);
        await outputFile.parent.create(recursive: true);
        final output = OutputFileStream(outputFile.path);
        try {
          file.writeContent(output);
        } on Object {
          return ImportResult.failure(
            reason: ImportFailureReason.ioError,
            message: 'Failed to extract file: ${file.name}',
          );
        } finally {
          await output.close();
        }
        if (!await outputFile.exists()) {
          return ImportResult.failure(
            reason: ImportFailureReason.ioError,
            message: 'Failed to extract file: ${file.name}',
          );
        }
      } else {
        await Directory(outputPath).create(recursive: true);
      }
      processed += 1;
      onStep?.call(processed, total);
    }
    return null;
  }

  Future<ImportResult> _importArchive(
    Archive archive,
    void Function({
      required double value,
      required String phase,
      int? processed,
      int? total,
    })
    emitProgress,
  ) async {
    emitProgress(value: 0.10, phase: 'Preparing import');

    final appDir = await _appDirectoryProvider();
    final rootDir = Directory(p.join(appDir.path, 'wardrobe_flutter'));
    final activeDir = Directory(p.join(rootDir.path, 'active_pack'));
    final stagingDir = Directory(p.join(rootDir.path, 'active_pack_staging'));

    if (await stagingDir.exists()) {
      await stagingDir.delete(recursive: true);
    }
    await stagingDir.create(recursive: true);

    final extractResult = await _extractArchive(
      archive: archive,
      destination: stagingDir,
      onStep: (int processed, int total) {
        final progress = 0.10 + (processed / total) * 0.60;
        emitProgress(
          value: progress,
          phase: 'Extracting files',
          processed: processed,
          total: total,
        );
      },
    );
    if (extractResult != null) {
      await stagingDir.delete(recursive: true);
      return extractResult;
    }

    final manifestFile = File(p.join(stagingDir.path, 'wardrobe.json'));
    if (!await manifestFile.exists()) {
      await stagingDir.delete(recursive: true);
      return ImportResult.failure(
        reason: ImportFailureReason.missingManifest,
        message: 'ZIP is missing wardrobe.json',
      );
    }
    emitProgress(value: 0.74, phase: 'Parsing manifest');

    final WardrobeManifest manifest;
    try {
      manifest = WardrobeManifest.fromString(await manifestFile.readAsString());
    } on UnsupportedSchemaException catch (error) {
      await stagingDir.delete(recursive: true);
      return ImportResult.failure(
        reason: ImportFailureReason.unsupportedSchema,
        message: error.toString(),
      );
    } on FormatException catch (error) {
      await stagingDir.delete(recursive: true);
      return ImportResult.failure(
        reason: ImportFailureReason.invalidManifest,
        message: error.message,
      );
    }

    final unsafeManifestPath = _firstUnsafeManifestPath(manifest);
    if (unsafeManifestPath != null) {
      await stagingDir.delete(recursive: true);
      return ImportResult.failure(
        reason: ImportFailureReason.invalidManifest,
        message: 'Manifest contains an unsafe asset path: $unsafeManifestPath',
      );
    }

    emitProgress(value: 0.88, phase: 'Validating assets');
    final missingAssets = await _validateAssets(
      manifest,
      stagingDir,
      onStep: (int processed, int total) {
        final progress = 0.88 + (processed / total) * 0.10;
        emitProgress(
          value: progress,
          phase: 'Validating assets',
          processed: processed,
          total: total,
        );
      },
    );
    if (missingAssets.isNotEmpty) {
      await stagingDir.delete(recursive: true);
      return ImportResult.failure(
        reason: ImportFailureReason.missingAssets,
        message:
            'Manifest references missing assets: ${missingAssets.take(8).join(', ')}',
      );
    }

    await rootDir.create(recursive: true);
    if (await activeDir.exists()) {
      await activeDir.delete(recursive: true);
    }
    await stagingDir.rename(activeDir.path);
    emitProgress(value: 1.0, phase: 'Import complete');

    return ImportResult.success(manifest: manifest, packRoot: activeDir);
  }

  Future<ImportResult> _importArchiveInMemory(
    Archive archive,
    void Function({
      required double value,
      required String phase,
      int? processed,
      int? total,
    })
    emitProgress,
  ) async {
    emitProgress(value: 0.10, phase: 'Preparing import');

    final filesByPath = <String, ArchiveFile>{};
    for (final file in archive.files) {
      final safePath = _safeRelativePath(file.name);
      if (safePath == null) {
        return ImportResult.failure(
          reason: ImportFailureReason.invalidZip,
          message: 'ZIP contains an invalid file path: ${file.name}',
        );
      }
      filesByPath[safePath] = file;
    }

    final manifestEntry = filesByPath['wardrobe.json'];
    if (manifestEntry == null) {
      return ImportResult.failure(
        reason: ImportFailureReason.missingManifest,
        message: 'ZIP is missing wardrobe.json',
      );
    }
    emitProgress(value: 0.74, phase: 'Parsing manifest');

    final WardrobeManifest manifest;
    try {
      manifest = WardrobeManifest.fromString(
        utf8.decode(_archiveFileBytes(manifestEntry)),
      );
    } on UnsupportedSchemaException catch (error) {
      return ImportResult.failure(
        reason: ImportFailureReason.unsupportedSchema,
        message: error.toString(),
      );
    } on FormatException catch (error) {
      return ImportResult.failure(
        reason: ImportFailureReason.invalidManifest,
        message: error.message,
      );
    }

    final unsafeManifestPath = _firstUnsafeManifestPath(manifest);
    if (unsafeManifestPath != null) {
      return ImportResult.failure(
        reason: ImportFailureReason.invalidManifest,
        message: 'Manifest contains an unsafe asset path: $unsafeManifestPath',
      );
    }

    emitProgress(value: 0.88, phase: 'Validating assets');
    final requiredPaths = manifest.referencedAssetPaths();

    final missing = <String>[];
    final total = requiredPaths.isEmpty ? 1 : requiredPaths.length;
    var processed = 0;
    for (final path in requiredPaths) {
      if (!filesByPath.containsKey(path)) {
        missing.add(path);
      }
      processed += 1;
      final progress = 0.88 + (processed / total) * 0.10;
      emitProgress(
        value: progress,
        phase: 'Validating assets',
        processed: processed,
        total: total,
      );
    }

    if (missing.isNotEmpty) {
      return ImportResult.failure(
        reason: ImportFailureReason.missingAssets,
        message:
            'Manifest references missing assets: ${missing.take(8).join(', ')}',
      );
    }

    final overrides = <String, String>{};
    for (final entry in filesByPath.entries) {
      if (!entry.value.isFile) {
        continue;
      }
      final mime = _mimeFromPath(entry.key);
      final encoded = base64Encode(_archiveFileBytes(entry.value));
      overrides[entry.key] = 'data:$mime;base64,$encoded';
    }

    emitProgress(value: 1.0, phase: 'Import complete');
    return ImportResult.success(
      manifest: manifest,
      packRoot: Directory(''),
      assetPathOverrides: overrides,
    );
  }

  List<int> _archiveFileBytes(ArchiveFile file) {
    return file.content as List<int>;
  }

  String _mimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.json')) {
      return 'application/json';
    }
    if (lower.endsWith('.yaml') || lower.endsWith('.yml')) {
      return 'application/yaml';
    }
    return 'application/octet-stream';
  }

  void Function({
    required double value,
    required String phase,
    int? processed,
    int? total,
  })
  _createProgressEmitter(void Function(ImportProgress progress)? onProgress) {
    final stopwatch = Stopwatch()..start();
    return ({
      required double value,
      required String phase,
      int? processed,
      int? total,
    }) {
      if (onProgress == null) {
        return;
      }

      Duration? remaining;
      if (processed != null &&
          total != null &&
          processed > 0 &&
          total > processed) {
        final elapsedMs = stopwatch.elapsedMilliseconds;
        final perUnitMs = elapsedMs / processed;
        final remainingMs = ((total - processed) * perUnitMs).round();
        remaining = Duration(milliseconds: remainingMs);
      }

      onProgress(
        ImportProgress(
          value: value.clamp(0.0, 1.0),
          phase: phase,
          processed: processed,
          total: total,
          estimatedRemaining: remaining,
        ),
      );
    };
  }

  String? _safeRelativePath(String rawPath) {
    final normalized = p.normalize(rawPath).replaceAll('\\', '/');
    if (normalized == '.' || normalized.isEmpty) {
      return null;
    }
    if (normalized.startsWith('/') || normalized.startsWith('..')) {
      return null;
    }
    if (normalized.contains('/../') || normalized == '..') {
      return null;
    }
    return normalized;
  }

  String? _firstUnsafeManifestPath(WardrobeManifest manifest) {
    for (final path in manifest.referencedAssetPaths()) {
      final safePath = _safeRelativePath(path);
      if (safePath == null || safePath != path.replaceAll('\\', '/')) {
        return path;
      }
    }
    return null;
  }

  ImportResult? _validateArchiveLimits(Archive archive) {
    if (archive.files.length > maxArchiveEntries) {
      return _archiveLimitFailure(
        'ZIP contains more than $maxArchiveEntries entries.',
      );
    }

    var totalBytes = 0;
    for (final file in archive.files) {
      if (file.size > maxArchiveEntryBytes) {
        return _archiveLimitFailure(
          'ZIP entry exceeds the ${_formatByteLimit(maxArchiveEntryBytes)} per-file limit: ${file.name}',
        );
      }
      totalBytes += file.size;
      if (totalBytes > maxArchiveUncompressedBytes) {
        return _archiveLimitFailure(
          'ZIP expands beyond the ${_formatByteLimit(maxArchiveUncompressedBytes)} total limit.',
        );
      }
    }
    return null;
  }

  ImportResult _archiveLimitFailure(String message) {
    return ImportResult.failure(
      reason: ImportFailureReason.invalidZip,
      message: message,
    );
  }

  String _formatByteLimit(int bytes) {
    final mebibytes = bytes ~/ (1024 * 1024);
    return '$mebibytes MiB';
  }

  Future<List<String>> _validateAssets(
    WardrobeManifest manifest,
    Directory packRoot, {
    void Function(int processed, int total)? onStep,
  }) async {
    final requiredPaths = manifest.referencedAssetPaths();

    final total = requiredPaths.isEmpty ? 1 : requiredPaths.length;
    var processed = 0;
    onStep?.call(processed, total);

    final missing = <String>[];
    for (final relativePath in requiredPaths) {
      final file = resolveAssetFile(packRoot, relativePath);
      if (!await file.exists()) {
        missing.add(relativePath);
      }
      processed += 1;
      onStep?.call(processed, total);
    }
    return missing;
  }

  Future<void> _writeManifest(Directory root, WardrobeManifest manifest) {
    final file = File(p.join(root.path, 'wardrobe.json'));
    final payload = jsonEncode(manifest.toJson());
    return file.writeAsString(payload, flush: true);
  }

  Future<Directory> _activePackDirectory() async {
    final appDir = await _appDirectoryProvider();
    return Directory(p.join(appDir.path, 'wardrobe_flutter', 'active_pack'));
  }
}

class _WorkspaceExportEntries {
  const _WorkspaceExportEntries({
    required this.manifestFile,
    required this.manifestContents,
    required this.assetFiles,
  });

  final File manifestFile;
  final String manifestContents;
  final List<MapEntry<String, File>> assetFiles;
}
