import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'models/favorite_outfit.dart';
import 'services/content_pack_service.dart';
import 'services/favorites_service.dart';
import 'services/intake_workspace_service.dart';
import 'services/image_cache_service.dart';
import 'services/wardrobe_repository.dart';
import 'ui/outfit_view.dart';
import 'ui/filter_controls.dart';
import 'ui/edit_clothing_item_screen.dart';
import 'ui/intake/intake_screen.dart';
import 'ui/pose_selector.dart';
import 'ui/top_sheet_gallery.dart';
import 'ui/zone_gesture_layer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  final pickerImplementation = ImagePickerPlatform.instance;
  if (pickerImplementation is ImagePickerAndroid) {
    pickerImplementation.useAndroidPhotoPicker = true;
  }
  runApp(const WardrobeApp());
}

class WardrobeApp extends StatelessWidget {
  const WardrobeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wardrobe Viewer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1D4E89)),
        useMaterial3: true,
      ),
      home: const WardrobeHomeScreen(),
    );
  }
}

class WardrobeHomeScreen extends StatefulWidget {
  const WardrobeHomeScreen({super.key});

  @override
  State<WardrobeHomeScreen> createState() => _WardrobeHomeScreenState();
}

class _WardrobeHomeScreenState extends State<WardrobeHomeScreen>
    with WidgetsBindingObserver {
  static const double _poseViewportFallbackAspectRatio = 1072 / 1936;
  static const double _wardrobeOpenSwipeVelocityThreshold = 560;
  static const double _wardrobeSwipeTopExclusion = 18;
  static const double _shakeAccelerationThresholdSquared = 420;
  static const Duration _shakeCooldown = Duration(milliseconds: 900);
  static const Duration _snackBarDuration = Duration(milliseconds: 1400);
  static const Duration _errorSnackBarDuration = Duration(milliseconds: 2200);
  static const Duration _noMatchSnackBarDuration = Duration(milliseconds: 1800);

  final ContentPackService _contentPackService = ContentPackService();
  final FavoritesService _favoritesService = FavoritesService();
  final ImagePicker _imagePicker = ImagePicker();
  late final IntakeWorkspaceService _intakeWorkspaceService =
      IntakeWorkspaceService(_contentPackService);
  final WardrobeRepository _repository = WardrobeRepository();
  final ImageCacheService _imageCacheService = ImageCacheService();
  final GlobalKey _outfitViewportKey = GlobalKey();

  bool _bootstrapped = false;
  bool _loading = false;
  double _importProgress = 0;
  String? _importPhase;
  Duration? _importEta;
  String? _bootstrapError;
  double? _wardrobeSwipeStartGlobalY;
  bool _favoriteBusy = false;
  bool _regenerationBusy = false;
  bool _showingNoMatchSnackBar = false;
  Timer? _noMatchSnackBarTimer;
  int _noMatchSnackBarToken = 0;
  OutfitComposition? _displayedComposition;
  String? _displayedCompositionKey;
  int _compositionSwapToken = 0;
  StreamSubscription<UserAccelerometerEvent>? _shakeSubscription;
  DateTime? _lastShakeAt;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  TopSheetGalleryViewState _topSheetViewState =
      TopSheetGalleryViewState.initial;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appLifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    _startShakeDetection();
    _bootstrap();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _startShakeDetection();
      return;
    }
    _stopShakeDetection();
  }

  Future<void> _bootstrap() async {
    _repository.addListener(_onRepositoryChanged);

    try {
      final activePack = await _contentPackService.loadActivePack();
      if (activePack != null) {
        _repository.setContentPack(
          manifest: activePack.manifest,
          packRoot: activePack.root,
          assetPathOverrides: activePack.assetPathOverrides,
        );
        await _loadFavoritesForActivePack();
        if (mounted) {
          await _warmCache();
        }
      } else {
        await _importBuiltinPack();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _bootstrapError = 'Failed to load built-in pack: $error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _bootstrapped = true;
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopShakeDetection();
    _noMatchSnackBarTimer?.cancel();
    _repository.removeListener(_onRepositoryChanged);
    _repository.dispose();
    super.dispose();
  }

  void _startShakeDetection() {
    if (_appLifecycleState != AppLifecycleState.resumed) {
      return;
    }
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      return;
    }
    if (_shakeSubscription != null) {
      return;
    }

    _shakeSubscription = userAccelerometerEventStream().listen(
      _handleShakeSensorEvent,
      onError: (Object error, StackTrace stackTrace) {},
    );
  }

  void _stopShakeDetection() {
    _shakeSubscription?.cancel();
    _shakeSubscription = null;
  }

  void _handleShakeSensorEvent(UserAccelerometerEvent event) {
    if (_appLifecycleState != AppLifecycleState.resumed) {
      return;
    }
    if (!_repository.hasContentPack || _loading) {
      return;
    }

    final accelerationSquared =
        (event.x * event.x) + (event.y * event.y) + (event.z * event.z);
    if (accelerationSquared < _shakeAccelerationThresholdSquared) {
      return;
    }

    final now = DateTime.now();
    final lastShake = _lastShakeAt;
    if (lastShake != null && now.difference(lastShake) < _shakeCooldown) {
      return;
    }
    _lastShakeAt = now;

    final changed = _repository.randomizeOutfit();
    if (changed) {
      unawaited(HapticFeedback.mediumImpact());
    }
  }

  Future<void> _onRepositoryChanged() async {
    if (!mounted) {
      return;
    }
    if (!_repository.hasContentPack) {
      _compositionSwapToken++;
      if (_displayedComposition != null || _displayedCompositionKey != null) {
        setState(() {
          _displayedComposition = null;
          _displayedCompositionKey = null;
        });
      }
      return;
    }
    if (!_repository.hasActiveFilters && _showingNoMatchSnackBar) {
      _noMatchSnackBarTimer?.cancel();
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
    await _warmCache();
  }

  Future<void> _warmCache() async {
    if (!mounted || !_repository.hasContentPack) {
      return;
    }

    final composition = _repository.currentComposition();
    final paths = _compositionPaths(composition);
    final targetKey = _compositionKey(composition);
    final swapToken = ++_compositionSwapToken;

    if (paths.isNotEmpty) {
      await _imageCacheService.warmPaths(context, paths, force: true);
      if (!mounted || swapToken != _compositionSwapToken) {
        return;
      }
    }

    if (_displayedCompositionKey != targetKey) {
      setState(() {
        _displayedComposition = composition;
        _displayedCompositionKey = targetKey;
      });
    }

    final adjacent = _repository.adjacentImagePaths();
    if (adjacent.isNotEmpty) {
      unawaited(_imageCacheService.warmPaths(context, adjacent));
    }
  }

  List<String> _compositionPaths(OutfitComposition composition) {
    return <String>[
      if (composition.baseImagePath?.isNotEmpty ?? false)
        composition.baseImagePath!,
      ...composition.overlays.where((String path) => path.isNotEmpty),
    ];
  }

  String _compositionKey(OutfitComposition composition) {
    return <String>[
      composition.baseImagePath ?? '',
      ...composition.overlays,
    ].join('|');
  }

  Future<void> _importBuiltinPack() async {
    final data = await rootBundle.load('assets/builtin_pack/wardrobe_pack.zip');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    await _runImport(
      () => _contentPackService.importZipBytes(
        bytes,
        onProgress: _onImportProgress,
      ),
      showSnackBars: false,
      statusLabel: 'Loading built-in pack',
    );
  }

  Future<void> _importZipFromPicker() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['zip'],
      withData: kIsWeb,
      withReadStream: !kIsWeb,
    );
    if (picked == null || picked.files.isEmpty) {
      return;
    }

    final file = picked.files.single;
    if (!kIsWeb && file.path != null && file.path!.isNotEmpty) {
      await _runImport(
        () => _contentPackService.importZip(
          File(file.path!),
          onProgress: _onImportProgress,
        ),
        zipPathForHint: file.path!,
      );
      return;
    }

    if (!kIsWeb && file.readStream != null) {
      final tempZip = await _writeReadStreamToTempZip(file.readStream!);
      try {
        await _runImport(
          () => _contentPackService.importZip(
            tempZip,
            onProgress: _onImportProgress,
          ),
        );
        return;
      } finally {
        if (await tempZip.parent.exists()) {
          await tempZip.parent.delete(recursive: true);
        }
      }
    }

    if (file.bytes case final bytes? when bytes.isNotEmpty) {
      await _runImport(
        () => _contentPackService.importZipBytes(
          bytes,
          onProgress: _onImportProgress,
        ),
      );
      return;
    }

    if (file.readStream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.readStream!) {
        builder.add(chunk);
      }
      final data = builder.takeBytes();
      if (data.isNotEmpty) {
        await _runImport(
          () => _contentPackService.importZipBytes(
            data,
            onProgress: _onImportProgress,
          ),
        );
        return;
      }
    }

    _showSnack('No readable ZIP data received from picker.', isError: true);
  }

  Future<File> _writeReadStreamToTempZip(Stream<List<int>> readStream) async {
    final tempDir = await Directory.systemTemp.createTemp(
      'wardrobe_zip_import_',
    );
    final file = File('${tempDir.path}/import.zip');
    final sink = file.openWrite();
    await sink.addStream(readStream);
    await sink.close();
    return file;
  }

  void _onImportProgress(ImportProgress progress) {
    if (!mounted) {
      return;
    }
    setState(() {
      _importProgress = progress.value;
      _importPhase = progress.phase;
      _importEta = progress.estimatedRemaining;
    });
  }

  Future<void> _runImport(
    Future<ImportResult> Function() run, {
    String? zipPathForHint,
    bool showSnackBars = true,
    String? statusLabel,
  }) async {
    setState(() {
      _loading = true;
      _importProgress = 0;
      _importPhase = statusLabel ?? 'Starting import';
      _importEta = null;
      _bootstrapError = null;
    });

    try {
      final result = await run();
      if (!mounted) {
        return;
      }

      if (result.success) {
        _repository.setContentPack(
          manifest: result.manifest!,
          packRoot: result.packRoot!,
          assetPathOverrides: result.assetPathOverrides,
        );
        await _loadFavoritesForActivePack();
        await _warmCache();
        if (showSnackBars) {
          _showSnack('Import successful.');
        }
      } else {
        var message = result.message ?? 'Import failed.';
        if (zipPathForHint != null &&
            message.contains('Permission denied') &&
            zipPathForHint.startsWith('/sdcard/Download/')) {
          message =
              '$message\nHint: use /storage/emulated/0/Android/data/app.wardrobe.viewer/files/wardrobe_pack.zip';
        } else if (zipPathForHint != null &&
            message.contains('does not exist') &&
            zipPathForHint.startsWith('/sdcard/Android/data/')) {
          message =
              '$message\nHint: try /storage/emulated/0/Android/data/app.wardrobe.viewer/files/wardrobe_pack.zip';
        }
        if (showSnackBars) {
          _showSnack(message, isError: true);
        } else if (mounted) {
          setState(() {
            _bootstrapError = message;
          });
        }
      }
    } catch (error) {
      if (mounted) {
        final message = 'Import failed: $error';
        if (showSnackBars) {
          _showSnack(message, isError: true);
        } else {
          setState(() {
            _bootstrapError = message;
          });
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _importProgress = 0;
          _importPhase = null;
          _importEta = null;
        });
      }
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: isError ? _errorSnackBarDuration : _snackBarDuration,
        backgroundColor: isError ? Colors.red.shade700 : null,
      ),
    );
  }

  String _formatEta(Duration? value) {
    if (value == null) {
      return '';
    }
    final seconds = value.inSeconds;
    if (seconds <= 0) {
      return '<1s';
    }
    if (seconds < 60) {
      return '${seconds}s';
    }
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '${minutes}m ${remainingSeconds}s';
  }

  Future<void> _openTopSheet() async {
    _repository.beginPendingSelection();

    await showGeneralDialog<void>(
      context: context,
      barrierLabel: 'Wardrobe sheet',
      barrierDismissible: true,
      barrierColor: Colors.black45,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder:
          (
            BuildContext dialogContext,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
          ) {
            return Align(
              alignment: Alignment.topCenter,
              child: Material(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(12),
                ),
                child: SizedBox(
                  height: MediaQuery.of(context).size.height * 0.695,
                  child: TopSheetGallery(
                    repository: _repository,
                    initialViewState: _topSheetViewState,
                    onViewStateChanged: (TopSheetGalleryViewState viewState) {
                      _topSheetViewState = viewState;
                    },
                    lockClothesSelection: _repository.isClothingSwitchLocked,
                    onStartIntake: _loading ? null : _startIntakeFlow,
                    onImportPack: _loading ? null : _handleImportFromSheet,
                    onExportPack: _repository.hasContentPack && !_loading
                        ? _exportWorkspace
                        : null,
                    onClearPack: _repository.hasContentPack
                        ? _confirmClearPack
                        : null,
                    onDeleteClothingItem:
                        _repository.hasContentPack && !_loading
                        ? _deleteClothingItemFromSheet
                        : null,
                    onEditClothingItem: _repository.hasContentPack && !_loading
                        ? _editClothingItemFromSheet
                        : null,
                    onToggleClothingRegeneration:
                        _repository.hasContentPack && !_loading
                        ? _toggleItemRegenerationFromSheet
                        : null,
                    onEditPose: _repository.hasContentPack && !_loading
                        ? _editPoseFromSheet
                        : null,
                    onDeletePose: _repository.hasContentPack && !_loading
                        ? _deletePoseFromSheet
                        : null,
                    isBusy: _loading,
                  ),
                ),
              ),
            );
          },
      transitionBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
            Widget child,
          ) {
            final offset = Tween<Offset>(
              begin: const Offset(0, -1),
              end: Offset.zero,
            ).animate(animation);
            return SlideTransition(position: offset, child: child);
          },
    );

    if (_repository.hasContentPack) {
      _repository.applyPendingSelection();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _repository,
      builder: (BuildContext context, Widget? child) {
        final hasPack = _repository.hasContentPack;
        final bodyPadding = hasPack
            ? const EdgeInsets.symmetric(vertical: 12)
            : const EdgeInsets.all(12);
        final body = SafeArea(
          child: Padding(padding: bodyPadding, child: _buildBodyContent()),
        );

        return Scaffold(
          body: Stack(
            children: <Widget>[
              _buildWallpaper(),
              body,
              if (_loading) _buildImportOverlay(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBodyContent() {
    if (!_bootstrapped) {
      return _buildLoadingBody();
    }
    if (_repository.hasContentPack) {
      return _buildOutfitBody();
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _handleWardrobeSwipeStart,
      onVerticalDragEnd: _handleWardrobeSwipe,
      child: _buildBootstrapErrorBody(),
    );
  }

  Widget _buildLoadingBody() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CircularProgressIndicator(),
          SizedBox(height: 12),
          Text('Loading wardrobe...'),
        ],
      ),
    );
  }

  Widget _buildBootstrapErrorBody() {
    final message =
        _bootstrapError ??
        'No content pack is available yet. Swipe down to open Wardrobe and import a ZIP.';
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.cloud_off, size: 48, color: Colors.grey.shade500),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImportOverlay() {
    final progressText =
        '${(_importProgress * 100).toStringAsFixed(0)}% • ${_importPhase ?? 'Importing'}'
        '${_importEta == null ? '' : ' • ETA ${_formatEta(_importEta)}'}';

    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + bottomInset),
        child: Material(
          color: Colors.white,
          elevation: 8,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.file_upload_outlined),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _importPhase ?? 'Importing pack',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text('${(_importProgress * 100).toStringAsFixed(0)}%'),
                  ],
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(value: _importProgress),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    progressText,
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWallpaper() {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              Color(0xFFF6F8FB),
              Color(0xFFE8EEF6),
              Color(0xFFE1E9F3),
            ],
          ),
        ),
        child: CustomPaint(
          painter: _NoisePainter(color: Color(0x26FFFFFF), step: 6),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  Widget _buildOutfitBody() {
    final manifest = _repository.manifest!;
    final composition =
        _displayedComposition ?? _repository.currentComposition();
    final showFavoriteToggle =
        _repository.activePoseId != null && !_repository.isActivePosePending;
    final regenerationBundle = _repository.currentLookRegenerationBundle();
    final showRegenerationToggle = regenerationBundle != null;
    final showZoneDebug = const bool.fromEnvironment(
      'SHOW_ZONE_DEBUG',
      defaultValue: false,
    );
    void openFilters() {
      showWardrobeFilterPanel(context: context, repository: _repository);
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _handleWardrobeSwipeStart,
      onVerticalDragEnd: _handleWardrobeSwipe,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                if (_repository.hasMultiplePoses)
                  Expanded(
                    child: PoseSelector(
                      poseIds: _repository.availablePoses,
                      selectedPoseId: _repository.activePoseId!,
                      onSelected: _repository.selectPose,
                      poseLabelsById: <String, String>{
                        for (final pose in manifest.poses) pose.id: pose.name,
                      },
                      scrollable: true,
                      compact: true,
                    ),
                  )
                else
                  const Spacer(),
                if (_repository.hasMultiplePoses) const SizedBox(width: 8),
                FilterIconButton(onPressed: openFilters),
                if (showRegenerationToggle) const SizedBox(width: 8),
                if (showRegenerationToggle)
                  _RegenerateToggleButton(
                    state: _repository.currentLookRegenerationState,
                    isBusy: _regenerationBusy,
                    onLongPress:
                        (_loading ||
                            _regenerationBusy ||
                            !_repository.hasContentPack)
                        ? null
                        : _showCurrentLookRegenerationScopeSheet,
                    onPressed:
                        (_loading ||
                            _regenerationBusy ||
                            !_repository.hasContentPack)
                        ? null
                        : _toggleCurrentLookRegeneration,
                  ),
              ],
            ),
          ),
          if (_repository.hasActiveFilters) ...<Widget>[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilterSummaryBar(
                repository: _repository,
                onOpenFilters: openFilters,
                showWhenInactive: false,
                showOpenButtonInActive: false,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Center(
                    child: OutfitView(
                      key: _outfitViewportKey,
                      composition: composition,
                      aspectRatio: manifest.images.aspectRatio,
                    ),
                  ),
                ),
                Positioned.fill(
                  child: ZoneGestureLayer(
                    showDebugZones: showZoneDebug,
                    onCategorySwipe: (String category, int direction) {
                      _handleZoneCategorySwipe(
                        category: category,
                        direction: direction,
                      );
                    },
                    onCategoryLongPress: (String category) {
                      _handleZoneCategoryLongPress(category: category);
                    },
                  ),
                ),
                if (showFavoriteToggle)
                  Positioned.fill(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: manifest.images.aspectRatio,
                        child: LayoutBuilder(
                          builder:
                              (
                                BuildContext context,
                                BoxConstraints constraints,
                              ) {
                                final inset =
                                    (constraints.biggest.shortestSide * 0.035)
                                        .clamp(8.0, 16.0);
                                return Padding(
                                  padding: EdgeInsets.all(inset),
                                  child: Align(
                                    alignment: Alignment.topRight,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        _FavoriteToggleButton(
                                          isActive: _repository
                                              .isCurrentOutfitFavorited,
                                          isBusy: _favoriteBusy,
                                          onPressed:
                                              (_loading ||
                                                  _favoriteBusy ||
                                                  !_repository.hasContentPack)
                                              ? null
                                              : _toggleCurrentFavorite,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadFavoritesForActivePack() async {
    final packRoot = _repository.packRoot;
    if (!_repository.hasContentPack || packRoot == null) {
      _repository.setFavorites(const <FavoriteOutfit>[]);
      return;
    }

    final favorites = await _favoritesService.loadFavorites(packRoot: packRoot);
    _repository.setFavorites(favorites);
  }

  Future<void> _toggleCurrentFavorite() async {
    if (_loading || _favoriteBusy || !_repository.hasContentPack) {
      return;
    }

    final packRoot = _repository.packRoot;
    final draft = _repository.currentFavoriteDraft();
    if (packRoot == null || draft == null) {
      return;
    }

    setState(() {
      _favoriteBusy = true;
    });

    try {
      final alreadyFavorite = _repository.hasFavoriteKey(draft.key);
      if (alreadyFavorite) {
        await _favoritesService.removeFavorite(
          packRoot: packRoot,
          favoriteKey: draft.key,
        );
      } else {
        await _favoritesService.saveFavorite(
          packRoot: packRoot,
          favorite: draft.copyWith(createdAt: DateTime.now().toUtc()),
          orderedCategories: _repository.categories,
        );
      }

      final favorites = await _favoritesService.loadFavorites(
        packRoot: packRoot,
      );
      _repository.setFavorites(favorites);
    } catch (error) {
      if (mounted) {
        _showSnack('Failed to update favorite: $error', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _favoriteBusy = false;
        });
      }
    }
  }

  void _handleWardrobeSwipeStart(DragStartDetails details) {
    _wardrobeSwipeStartGlobalY = details.globalPosition.dy;
  }

  void _handleWardrobeSwipe(DragEndDetails details) {
    final swipeStart = _wardrobeSwipeStartGlobalY;
    _wardrobeSwipeStartGlobalY = null;

    final topExclusion =
        MediaQuery.of(context).padding.top + _wardrobeSwipeTopExclusion;
    if (swipeStart != null && swipeStart <= topExclusion) {
      return;
    }

    final velocity = details.velocity.pixelsPerSecond.dy;
    if (velocity > _wardrobeOpenSwipeVelocityThreshold) {
      _openTopSheet();
    }
  }

  void _handleImportFromSheet() {
    _importZipFromPicker();
  }

  Future<void> _startIntakeFlow() async {
    if (_loading) {
      return;
    }

    final picked = await _imagePicker.pickMultiImage();
    if (picked.isEmpty) {
      return;
    }

    final images = <IntakeImageHandle>[];
    for (final file in picked) {
      final handle = _toIntakeImageHandle(file);
      if (handle == null) {
        continue;
      }
      images.add(handle);
    }
    if (images.isEmpty) {
      _showSnack('No readable image data from picker.', isError: true);
      return;
    }

    if (!mounted) {
      return;
    }

    var poseViewportAspectRatio = _currentOutfitViewportAspectRatio();
    if (poseViewportAspectRatio == null) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) {
        return;
      }
      poseViewportAspectRatio = _currentOutfitViewportAspectRatio();
    }
    poseViewportAspectRatio ??= _poseViewportFallbackAspectRatio;

    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) {
          return IntakeScreen(
            images: images,
            workspaceService: _intakeWorkspaceService,
            poseViewportAspectRatio: poseViewportAspectRatio,
          );
        },
      ),
    );

    if (changed != true) {
      return;
    }

    await _reloadActiveWorkspace();
    _showSnack('Intake saved to local workspace.');
  }

  double? _currentOutfitViewportAspectRatio() {
    final context = _outfitViewportKey.currentContext;
    if (context == null) {
      return null;
    }
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return null;
    }
    final size = renderObject.size;
    if (size.width <= 0 || size.height <= 0) {
      return null;
    }
    return size.width / size.height;
  }

  IntakeImageHandle? _toIntakeImageHandle(XFile file) {
    final hasPath = !kIsWeb && file.path.trim().isNotEmpty;
    if (!hasPath && kIsWeb == false) {
      return null;
    }

    final normalizedName = file.name.trim().isEmpty
        ? 'image-${DateTime.now().millisecondsSinceEpoch}'
        : file.name.trim();
    final previewPath = hasPath ? file.path : null;
    Uint8List? cachedBytes;

    return IntakeImageHandle(
      name: normalizedName,
      previewPath: previewPath,
      loadBytes: () async {
        if (cachedBytes case final bytes? when bytes.isNotEmpty) {
          return bytes;
        }

        try {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) {
            cachedBytes = bytes;
            return cachedBytes;
          }
        } on Exception {
          return null;
        }

        return null;
      },
    );
  }

  Future<void> _reloadActiveWorkspace() async {
    final activePack = await _contentPackService.loadActivePack();
    if (activePack == null) {
      return;
    }

    _repository.setContentPack(
      manifest: activePack.manifest,
      packRoot: activePack.root,
      assetPathOverrides: activePack.assetPathOverrides,
      preserveCurrentState: true,
    );
    await _loadFavoritesForActivePack();
    await _warmCache();
  }

  Future<void> _deleteClothingItemFromSheet({
    required String category,
    required String itemId,
  }) async {
    if (category == WardrobeRepository.uncategorizedIntakeCategory) {
      await _intakeWorkspaceService.deletePendingIntakeItem(itemId: itemId);
    } else {
      await _intakeWorkspaceService.deleteClothingItem(
        category: category,
        itemId: itemId,
      );
    }
    await _reloadActiveWorkspace();
  }

  Future<void> _editClothingItemFromSheet({
    required String category,
    required String itemId,
  }) async {
    if (!mounted) {
      return;
    }

    final result = await Navigator.of(context).push<UpdateWardrobeItemResult>(
      MaterialPageRoute<UpdateWardrobeItemResult>(
        builder: (BuildContext context) {
          return EditClothingItemScreen(
            workspaceService: _intakeWorkspaceService,
            category: category,
            itemId: itemId,
          );
        },
      ),
    );
    if (result == null) {
      return;
    }

    await _reloadActiveWorkspace();
    if (!mounted) {
      return;
    }

    if (result.categoryChanged) {
      _showSnack(
        'Item moved to ${result.nextCategory}. '
        'Invalidated ${result.invalidatedAssetsCount} generated assets. Re-render is required.',
      );
      return;
    }
  }

  Future<void> _editPoseFromSheet({
    required String poseId,
    required String name,
  }) async {
    await _intakeWorkspaceService.updatePoseName(poseId: poseId, name: name);
    await _reloadActiveWorkspace();
  }

  Future<void> _toggleItemRegenerationFromSheet({
    required String category,
    required String itemId,
    required ClothingRegenerationScope scope,
  }) async {
    if (_regenerationBusy) {
      return;
    }
    setState(() {
      _regenerationBusy = true;
    });
    try {
      switch (scope) {
        case ClothingRegenerationScope.allPoses:
          await _intakeWorkspaceService.toggleItemRegeneration(
            category: category,
            itemId: itemId,
          );
          break;
        case ClothingRegenerationScope.activePose:
          final poseId = _repository.activePoseId;
          if (poseId == null) {
            return;
          }
          if (category == 'headwear' || category == 'shoes') {
            await _intakeWorkspaceService.toggleOverlayRegeneration(
              poseId: poseId,
              category: category,
              itemId: itemId,
            );
          } else {
            await _intakeWorkspaceService.togglePoseItemRegeneration(
              poseId: poseId,
              category: category,
              itemId: itemId,
            );
          }
          break;
      }
      await _reloadActiveWorkspace();
    } catch (error) {
      if (mounted) {
        _showSnack('Failed to update regenerate queue: $error', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _regenerationBusy = false;
        });
      }
    }
  }

  Future<void> _deletePoseFromSheet({required String poseId}) async {
    await _intakeWorkspaceService.deletePose(poseId: poseId);
    await _reloadActiveWorkspace();
  }

  Future<void> _toggleCurrentLookRegeneration() async {
    if (_regenerationBusy) {
      return;
    }
    final bundle = _repository.currentLookRegenerationBundle();
    if (bundle == null) {
      return;
    }

    setState(() {
      _regenerationBusy = true;
    });
    try {
      await _setCurrentLookQueued(
        bundle: bundle,
        enabled:
            _repository.currentLookRegenerationState !=
            CurrentLookRegenerationState.full,
      );
      await _reloadActiveWorkspace();
    } catch (error) {
      if (mounted) {
        _showSnack('Failed to update regenerate queue: $error', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _regenerationBusy = false;
        });
      }
    }
  }

  Future<void> _setCurrentLookQueued({
    required CurrentLookRegenerationBundle bundle,
    required bool enabled,
  }) async {
    final renderQueued = _repository.isRenderQueuedForRegeneration(
      poseId: bundle.renderTarget.poseId,
      topId: bundle.renderTarget.topId,
      bottomId: bundle.renderTarget.bottomId,
    );
    if (renderQueued != enabled) {
      await _intakeWorkspaceService.toggleRenderRegeneration(
        poseId: bundle.renderTarget.poseId,
        topId: bundle.renderTarget.topId,
        bottomId: bundle.renderTarget.bottomId,
      );
    }
    await _setOverlayQueued(target: bundle.headwearTarget, enabled: enabled);
    await _setOverlayQueued(target: bundle.shoesTarget, enabled: enabled);
  }

  Future<void> _setOverlayQueued({
    required CurrentOverlayRegenerationTarget? target,
    required bool enabled,
  }) async {
    if (target == null) {
      return;
    }
    final queued = _repository.isOverlayQueuedForRegeneration(
      poseId: target.poseId,
      category: target.category,
      itemId: target.itemId,
    );
    if (queued == enabled) {
      return;
    }
    await _intakeWorkspaceService.toggleOverlayRegeneration(
      poseId: target.poseId,
      category: target.category,
      itemId: target.itemId,
    );
  }

  Future<void> _toggleCurrentLookScope(
    CurrentLookRegenerationScope scope,
  ) async {
    if (_regenerationBusy) {
      return;
    }
    final bundle = _repository.currentLookRegenerationBundle();
    if (bundle == null) {
      return;
    }

    setState(() {
      _regenerationBusy = true;
    });
    try {
      switch (scope) {
        case CurrentLookRegenerationScope.look:
          await _setCurrentLookQueued(
            bundle: bundle,
            enabled:
                _repository.currentLookRegenerationState !=
                CurrentLookRegenerationState.full,
          );
          break;
        case CurrentLookRegenerationScope.render:
          await _intakeWorkspaceService.toggleRenderRegeneration(
            poseId: bundle.renderTarget.poseId,
            topId: bundle.renderTarget.topId,
            bottomId: bundle.renderTarget.bottomId,
          );
          break;
        case CurrentLookRegenerationScope.headwear:
          if (bundle.headwearTarget == null) {
            return;
          }
          await _intakeWorkspaceService.toggleOverlayRegeneration(
            poseId: bundle.headwearTarget!.poseId,
            category: bundle.headwearTarget!.category,
            itemId: bundle.headwearTarget!.itemId,
          );
          break;
        case CurrentLookRegenerationScope.shoes:
          if (bundle.shoesTarget == null) {
            return;
          }
          await _intakeWorkspaceService.toggleOverlayRegeneration(
            poseId: bundle.shoesTarget!.poseId,
            category: bundle.shoesTarget!.category,
            itemId: bundle.shoesTarget!.itemId,
          );
          break;
      }
      await _reloadActiveWorkspace();
    } catch (error) {
      if (mounted) {
        _showSnack('Failed to update regenerate queue: $error', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _regenerationBusy = false;
        });
      }
    }
  }

  Future<void> _showCurrentLookRegenerationScopeSheet() async {
    if (_regenerationBusy) {
      return;
    }
    final statuses = _repository.currentLookScopeStatuses();
    if (statuses.isEmpty) {
      return;
    }
    final scope = await showModalBottomSheet<CurrentLookRegenerationScope>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: statuses
                .map(
                  (CurrentLookScopeStatus status) => ListTile(
                    leading: Icon(
                      switch (status.scope) {
                        CurrentLookRegenerationScope.look =>
                          Icons.layers_outlined,
                        CurrentLookRegenerationScope.render =>
                          Icons.image_outlined,
                        CurrentLookRegenerationScope.headwear =>
                          Icons.face_retouching_natural_outlined,
                        CurrentLookRegenerationScope.shoes =>
                          Icons.directions_walk_outlined,
                      },
                      color: status.queued
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    title: Text(status.label),
                    trailing: status.queued
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () => Navigator.of(context).pop(status.scope),
                  ),
                )
                .toList(growable: false),
          ),
        );
      },
    );
    if (scope == null) {
      return;
    }
    await _toggleCurrentLookScope(scope);
  }

  void _handleZoneCategorySwipe({
    required String category,
    required int direction,
  }) {
    if (_repository.isClothingSwitchLocked) {
      _showSnack(
        'This pose is pending. Clothing changes are locked until rendering is complete.',
      );
      return;
    }
    final result = _repository.cycleCategoryFiltered(category, direction);
    if (result.changed) {
      return;
    }
    if (result.blockedNoMatches) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      _showingNoMatchSnackBar = true;
      _noMatchSnackBarTimer?.cancel();
      final snackBarToken = ++_noMatchSnackBarToken;
      _noMatchSnackBarTimer = Timer(_noMatchSnackBarDuration, () {
        if (!mounted || snackBarToken != _noMatchSnackBarToken) {
          return;
        }
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      });
      messenger
          .showSnackBar(
            SnackBar(
              content: Text(
                result.reason ?? 'No filtered items available for $category.',
              ),
              duration: _noMatchSnackBarDuration,
              action: SnackBarAction(
                label: 'Clear filters',
                onPressed: _repository.clearAllFilters,
              ),
            ),
          )
          .closed
          .then((_) {
            if (!mounted || snackBarToken != _noMatchSnackBarToken) {
              return;
            }
            _showingNoMatchSnackBar = false;
            _noMatchSnackBarTimer?.cancel();
          });
    }
  }

  void _handleZoneCategoryLongPress({required String category}) {
    if (!_repository.supportsDirectDeselect(category)) {
      return;
    }
    if (_repository.isClothingSwitchLocked) {
      _showSnack(
        'This pose is pending. Clothing changes are locked until rendering is complete.',
      );
      return;
    }
    final cleared = _repository.clearCategorySelection(category);
    if (cleared) {
      unawaited(HapticFeedback.selectionClick());
    }
  }

  Future<void> _exportWorkspace() async {
    setState(() {
      _loading = true;
      _importProgress = 0;
      _importPhase = 'Exporting workspace';
      _importEta = null;
    });
    try {
      const exportFileName = 'wardrobe_workspace.zip';
      String? exportPath;
      if (!kIsWeb && Platform.isAndroid) {
        exportPath = await _contentPackService.exportActiveWorkspaceWithPicker(
          fileName: exportFileName,
        );
      } else {
        try {
          if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
            final zipBytes = await _contentPackService
                .exportActiveWorkspaceZipBytes();
            exportPath = await FilePicker.platform.saveFile(
              dialogTitle: 'Export workspace ZIP',
              fileName: exportFileName,
              type: FileType.custom,
              allowedExtensions: const <String>['zip'],
              bytes: zipBytes,
            );
          } else {
            final targetPath = await FilePicker.platform.saveFile(
              dialogTitle: 'Export workspace ZIP',
              fileName: exportFileName,
              type: FileType.custom,
              allowedExtensions: const <String>['zip'],
            );
            if (targetPath != null && targetPath.isNotEmpty) {
              final file = await _contentPackService.exportActiveWorkspaceZip(
                fileName: exportFileName,
                outputFilePath: targetPath,
              );
              exportPath = file.path;
            } else {
              exportPath = targetPath;
            }
          }
        } on UnimplementedError {
          final file = await _contentPackService.exportActiveWorkspaceZip(
            fileName: exportFileName,
          );
          exportPath = file.path;
        }
      }
      if (!mounted) {
        return;
      }
      if (exportPath == null || exportPath.isEmpty) {
        _showSnack('Export cancelled.');
        return;
      }
      _showSnack('Workspace exported to $exportPath');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showSnack('Failed to export workspace: $error', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _importProgress = 0;
          _importPhase = null;
          _importEta = null;
        });
      }
    }
  }

  Future<void> _confirmClearPack() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Clear content pack?'),
          content: const Text(
            'This removes the currently active pack from this device.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Clear'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }

    setState(() {
      _loading = true;
      _importProgress = 0;
      _importPhase = 'Clearing pack';
      _importEta = null;
    });

    try {
      await _contentPackService.clearActivePack();
      _imageCacheService.clear();
      _repository.clearContentPack();
    } catch (error) {
      if (mounted) {
        _showSnack('Failed to clear pack: $error', isError: true);
        setState(() {
          _loading = false;
          _importProgress = 0;
          _importPhase = null;
          _importEta = null;
        });
      }
      return;
    }

    if (!mounted) {
      return;
    }

    await _importBuiltinPack();
    if (mounted && _repository.hasContentPack) {
      _showSnack('Default pack loaded.');
    }
  }
}

class _NoisePainter extends CustomPainter {
  _NoisePainter({required this.color, required this.step});

  final Color color;
  final double step;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final width = size.width.floor();
    final height = size.height.floor();

    for (int y = 0; y < height; y += step.toInt()) {
      for (int x = 0; x < width; x += step.toInt()) {
        final hash = _hash(x, y);
        if (hash % 11 == 0) {
          canvas.drawRect(
            Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1),
            paint,
          );
        }
      }
    }
  }

  int _hash(int x, int y) {
    var h = x * 374761393 + y * 668265263;
    h = (h ^ (h >> 13)) * 1274126177;
    return h & 0x7fffffff;
  }

  @override
  bool shouldRepaint(covariant _NoisePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.step != step;
}

class _FavoriteToggleButton extends StatefulWidget {
  const _FavoriteToggleButton({
    required this.isActive,
    required this.isBusy,
    required this.onPressed,
  });

  final bool isActive;
  final bool isBusy;
  final VoidCallback? onPressed;

  @override
  State<_FavoriteToggleButton> createState() => _FavoriteToggleButtonState();
}

class _FavoriteToggleButtonState extends State<_FavoriteToggleButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _activateController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 440),
  );
  late final Animation<double> _iconPop =
      TweenSequence<double>(<TweenSequenceItem<double>>[
        TweenSequenceItem<double>(
          tween: Tween<double>(
            begin: 1,
            end: 1.26,
          ).chain(CurveTween(curve: Curves.easeOutCubic)),
          weight: 45,
        ),
        TweenSequenceItem<double>(
          tween: Tween<double>(
            begin: 1.26,
            end: 1,
          ).chain(CurveTween(curve: Curves.easeOutBack)),
          weight: 55,
        ),
      ]).animate(_activateController);

  bool _pressed = false;

  @override
  void didUpdateWidget(covariant _FavoriteToggleButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) {
      _activateController.forward(from: 0);
    } else if (oldWidget.isActive && !widget.isActive) {
      _activateController.stop();
      _activateController.value = 0;
    }
  }

  @override
  void dispose() {
    _activateController.dispose();
    super.dispose();
  }

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  void _handleTap() {
    HapticFeedback.selectionClick();
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEnabled = widget.onPressed != null && !widget.isBusy;
    final activeValue = widget.isActive ? 1.0 : 0.0;

    return AnimatedBuilder(
      animation: _activateController,
      builder: (BuildContext context, Widget? child) {
        final burst = _activateController.value;
        final ringOpacity = (1 - Curves.easeOutQuart.transform(burst)).clamp(
          0.0,
          1.0,
        );
        final ringScale = 0.72 + (Curves.easeOutCubic.transform(burst) * 0.96);
        final iconScale = widget.isActive ? _iconPop.value : 1.0;
        final containerScale = _pressed ? 0.9 : 1.0;

        return AnimatedScale(
          scale: containerScale,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: <Widget>[
                if (ringOpacity > 0.01)
                  IgnorePointer(
                    child: OverflowBox(
                      minWidth: 0,
                      minHeight: 0,
                      maxWidth: 72,
                      maxHeight: 72,
                      child: Opacity(
                        opacity: ringOpacity * 0.55,
                        child: Transform.scale(
                          scale: ringScale,
                          child: Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFFFFC74F),
                                width: 2.2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: LinearGradient(
                        colors: <Color>[
                          Color.lerp(
                            const Color(0xFFFDFEFF),
                            const Color(0xFFFFF8DE),
                            activeValue,
                          )!,
                          Color.lerp(
                            const Color(0xFFF2F4F8),
                            const Color(0xFFFFDC73),
                            activeValue,
                          )!,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      border: Border.all(
                        color: Color.lerp(
                          Colors.black.withValues(alpha: 0.08),
                          const Color(0xFFFFC648),
                          activeValue,
                        )!,
                      ),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Color.lerp(
                            Colors.black.withValues(alpha: 0.12),
                            const Color(0x59FFC84D),
                            activeValue,
                          )!,
                          blurRadius: 16 + (12 * activeValue),
                          spreadRadius: 1 + (activeValue * 0.8),
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(999),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: isEnabled ? _handleTap : null,
                        onTapDown: isEnabled ? (_) => _setPressed(true) : null,
                        onTapUp: isEnabled ? (_) => _setPressed(false) : null,
                        onTapCancel: isEnabled
                            ? () => _setPressed(false)
                            : null,
                        child: Center(
                          child: Transform.scale(
                            scale: iconScale,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 180),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              transitionBuilder:
                                  (Widget child, Animation<double> animation) {
                                    return FadeTransition(
                                      opacity: animation,
                                      child: ScaleTransition(
                                        scale: Tween<double>(
                                          begin: 0.88,
                                          end: 1,
                                        ).animate(animation),
                                        child: child,
                                      ),
                                    );
                                  },
                              child: widget.isBusy
                                  ? SizedBox(
                                      key: const ValueKey<String>('busy'),
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: theme.colorScheme.primary,
                                      ),
                                    )
                                  : Icon(
                                      widget.isActive
                                          ? Icons.star_rounded
                                          : Icons.star_outline_rounded,
                                      key: ValueKey<bool>(widget.isActive),
                                      size: 23,
                                      color: widget.isActive
                                          ? const Color(0xFFFFB300)
                                          : theme.colorScheme.onSurfaceVariant,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RegenerateToggleButton extends StatelessWidget {
  const _RegenerateToggleButton({
    required this.state,
    required this.isBusy,
    required this.onPressed,
    this.onLongPress,
  });

  final CurrentLookRegenerationState state;
  final bool isBusy;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeValue = switch (state) {
      CurrentLookRegenerationState.none => 0.0,
      CurrentLookRegenerationState.partial => 0.55,
      CurrentLookRegenerationState.full => 1.0,
    };
    final accentColor = switch (state) {
      CurrentLookRegenerationState.none => theme.colorScheme.onSurfaceVariant,
      CurrentLookRegenerationState.partial => const Color(0xFFAD7B00),
      CurrentLookRegenerationState.full => const Color(0xFF156C38),
    };
    final borderRadius = BorderRadius.circular(12);

    return SizedBox(
      width: 40,
      height: 40,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          gradient: LinearGradient(
            colors: <Color>[
              Color.lerp(
                const Color(0xFFFDFEFF),
                state == CurrentLookRegenerationState.partial
                    ? const Color(0xFFFFF1CC)
                    : const Color(0xFFE4F7EC),
                activeValue,
              )!,
              Color.lerp(
                const Color(0xFFF2F4F8),
                state == CurrentLookRegenerationState.partial
                    ? const Color(0xFFFFCF66)
                    : const Color(0xFF8DDEAA),
                activeValue,
              )!,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(
            color: Color.lerp(
              Colors.black.withValues(alpha: 0.08),
              const Color(0xFF1E8E4A),
              activeValue,
            )!,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Color.lerp(
                Colors.black.withValues(alpha: 0.10),
                const Color(0x331E8E4A),
                activeValue,
              )!,
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: borderRadius,
          child: InkWell(
            borderRadius: borderRadius,
            onTap: onPressed == null || isBusy
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    onPressed?.call();
                  },
            onLongPress: onLongPress == null || isBusy
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    onLongPress?.call();
                  },
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: isBusy
                    ? SizedBox(
                        key: const ValueKey<String>('busy'),
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: theme.colorScheme.primary,
                        ),
                      )
                    : Icon(
                        Icons.autorenew_rounded,
                        key: ValueKey<CurrentLookRegenerationState>(state),
                        size: 22,
                        color: accentColor,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
