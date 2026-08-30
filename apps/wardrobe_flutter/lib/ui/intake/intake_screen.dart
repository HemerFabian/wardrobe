import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../services/intake_workspace_service.dart';
import 'selection_aspect.dart';

typedef IntakeBytesLoader = Future<Uint8List?> Function();

class IntakeImageHandle {
  IntakeImageHandle({
    required this.name,
    required this.loadBytes,
    this.previewPath,
  });

  final String name;
  final IntakeBytesLoader loadBytes;
  final String? previewPath;

  bool get hasPreviewPath => previewPath != null && previewPath!.isNotEmpty;
}

class _LoadedIntakeImage {
  const _LoadedIntakeImage({
    this.bytes,
    this.previewPath,
    required this.width,
    required this.height,
  });

  final Uint8List? bytes;
  final String? previewPath;
  final int width;
  final int height;

  bool get hasPreviewPath => previewPath != null && previewPath!.isNotEmpty;
}

enum IntakeMode { clothes, pose }

class IntakeScreen extends StatefulWidget {
  const IntakeScreen({
    super.key,
    required this.images,
    required this.workspaceService,
    this.poseViewportAspectRatio,
  });

  final List<IntakeImageHandle> images;
  final IntakeWorkspaceService workspaceService;
  final double? poseViewportAspectRatio;

  @override
  State<IntakeScreen> createState() => _IntakeScreenState();
}

class _IntakeScreenState extends State<IntakeScreen> {
  static const double _poseFallbackAspectRatio = 1072 / 1936;
  static const int _prefetchRadius = 2;
  static const int _retainRadius = 4;
  static const Duration _postSwipeSelectionDelay = Duration(milliseconds: 280);

  late final PageController _pageController;
  late final List<RectSelection> _selections;
  final Set<int> _poseSelectionInitialized = <int>{};
  final Map<int, _LoadedIntakeImage> _loadedImages =
      <int, _LoadedIntakeImage>{};
  final Map<int, Future<_LoadedIntakeImage?>> _pendingLoads =
      <int, Future<_LoadedIntakeImage?>>{};
  final Set<int> _loadErrors = <int>{};

  int _activeIndex = 0;
  IntakeMode _mode = IntakeMode.clothes;
  bool _busy = false;
  bool _changed = false;
  bool _selectionInteractionActive = false;
  bool _postSwipeSelectionDelayActive = false;
  Timer? _postSwipeSelectionDelayTimer;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _selections = List<RectSelection>.filled(
      widget.images.length,
      const RectSelection(left: 0.20, top: 0.18, width: 0.60, height: 0.62),
      growable: false,
    );
    _primeCacheAround(_activeIndex);
  }

  @override
  void dispose() {
    _postSwipeSelectionDelayTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.images[_activeIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_activeIndex + 1}/${widget.images.length}'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Close intake',
            onPressed: _busy ? null : () => Navigator.of(context).pop(_changed),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          SafeArea(
            child: Column(
              children: <Widget>[
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    physics:
                        _selectionInteractionActive ||
                            _postSwipeSelectionDelayActive
                        ? const NeverScrollableScrollPhysics()
                        : null,
                    itemCount: widget.images.length,
                    onPageChanged: (int index) {
                      _postSwipeSelectionDelayTimer?.cancel();
                      setState(() {
                        _activeIndex = index;
                        _trimCacheAround(index);
                        if (_mode == IntakeMode.pose) {
                          _applyPoseSelectionForIndex(
                            index,
                            resetToViewportFrame: !_poseSelectionInitialized
                                .contains(index),
                          );
                        }
                        _postSwipeSelectionDelayActive = true;
                      });
                      _primeCacheAround(index);
                      _postSwipeSelectionDelayTimer = Timer(
                        _postSwipeSelectionDelay,
                        () {
                          if (!mounted || !_postSwipeSelectionDelayActive) {
                            return;
                          }
                          setState(() {
                            _postSwipeSelectionDelayActive = false;
                          });
                        },
                      );
                    },
                    itemBuilder: (BuildContext context, int index) =>
                        _buildPage(index),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  child: _buildBottomBar(active),
                ),
              ],
            ),
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x88000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  void _primeCacheAround(int centerIndex) {
    for (
      int offset = -_prefetchRadius;
      offset <= _prefetchRadius;
      offset += 1
    ) {
      final index = centerIndex + offset;
      if (index < 0 || index >= widget.images.length) {
        continue;
      }
      unawaited(_ensureImageLoaded(index));
    }
  }

  Future<_LoadedIntakeImage?> _ensureImageLoaded(int index) {
    if (index < 0 || index >= widget.images.length) {
      return Future<_LoadedIntakeImage?>.value(null);
    }
    final cached = _loadedImages[index];
    if (cached != null) {
      return Future<_LoadedIntakeImage?>.value(cached);
    }
    final pending = _pendingLoads[index];
    if (pending != null) {
      return pending;
    }

    final loadFuture = _loadImageAt(index);
    _pendingLoads[index] = loadFuture;
    return loadFuture.whenComplete(() {
      _pendingLoads.remove(index);
    });
  }

  Future<_LoadedIntakeImage?> _loadImageAt(int index) async {
    final source = widget.images[index];

    final previewPath = source.hasPreviewPath ? source.previewPath : null;
    int? width;
    int? height;
    Uint8List? bytes;

    if (!kIsWeb && previewPath != null) {
      final dimensions = await _decodeImageSizeFromPath(previewPath);
      if (dimensions != null) {
        width = dimensions.width;
        height = dimensions.height;
      }
    }

    if (width == null || height == null) {
      bytes = await _loadSourceBytes(source);
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          setState(() {
            _loadErrors.add(index);
          });
        }
        return null;
      }

      final dimensions = await _decodeImageSizeFromBytes(bytes);
      if (dimensions == null) {
        if (mounted) {
          setState(() {
            _loadErrors.add(index);
          });
        }
        return null;
      }
      width = dimensions.width;
      height = dimensions.height;
    }

    final loaded = _LoadedIntakeImage(
      bytes: bytes,
      previewPath: previewPath,
      width: width,
      height: height,
    );
    if (!mounted) {
      return loaded;
    }

    setState(() {
      _loadErrors.remove(index);
      _loadedImages[index] = loaded;
      if (_mode == IntakeMode.pose) {
        _applyPoseSelectionForIndex(
          index,
          resetToViewportFrame: !_poseSelectionInitialized.contains(index),
        );
      }
      _trimCacheAround(_activeIndex);
    });
    return loaded;
  }

  Future<Uint8List?> _loadSourceBytes(IntakeImageHandle source) async {
    try {
      final bytes = await source.loadBytes();
      if (bytes == null || bytes.isEmpty) {
        return null;
      }
      return bytes;
    } on Exception {
      return null;
    }
  }

  Future<({int width, int height})?> _decodeImageSizeFromPath(
    String path,
  ) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(path);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          return (width: descriptor.width, height: descriptor.height);
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } on Exception {
      return null;
    }
  }

  Future<({int width, int height})?> _decodeImageSizeFromBytes(
    Uint8List bytes,
  ) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          return (width: descriptor.width, height: descriptor.height);
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } on Exception {
      return null;
    }
  }

  Future<Uint8List?> _ensureImageBytes({
    required int index,
    required _LoadedIntakeImage image,
  }) async {
    if (image.bytes case final bytes? when bytes.isNotEmpty) {
      return bytes;
    }

    final source = widget.images[index];
    final loadedBytes = await _loadSourceBytes(source);
    if (loadedBytes == null) {
      if (mounted) {
        setState(() {
          _loadErrors.add(index);
        });
      }
      return null;
    }

    if (!mounted) {
      return loadedBytes;
    }

    setState(() {
      _loadErrors.remove(index);
      _loadedImages[index] = _LoadedIntakeImage(
        bytes: loadedBytes,
        previewPath: image.previewPath,
        width: image.width,
        height: image.height,
      );
    });
    return loadedBytes;
  }

  void _trimCacheAround(int centerIndex) {
    final minIndex = math.max(0, centerIndex - _retainRadius);
    final maxIndex = math.min(
      widget.images.length - 1,
      centerIndex + _retainRadius,
    );
    _loadedImages.removeWhere(
      (int index, _LoadedIntakeImage _) => index < minIndex || index > maxIndex,
    );
    _loadErrors.removeWhere(
      (int index) => index < minIndex || index > maxIndex,
    );
  }

  Widget _buildPage(int index) {
    final loaded = _loadedImages[index];
    final loadFailed = _loadErrors.contains(index);
    if (loaded == null && !loadFailed) {
      unawaited(_ensureImageLoaded(index));
    }

    if (loaded == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                loadFailed ? Icons.broken_image_outlined : Icons.photo_outlined,
                color: Colors.white70,
                size: 44,
              ),
              const SizedBox(height: 12),
              Text(
                loadFailed ? 'Could not load image.' : 'Loading image...',
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              if (!loadFailed) ...<Widget>[
                const SizedBox(height: 12),
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final imageWidget = (!kIsWeb && loaded.hasPreviewPath)
        ? Image.file(
            File(loaded.previewPath!),
            fit: BoxFit.fill,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
          )
        : (loaded.bytes == null || loaded.bytes!.isEmpty)
        ? const ColoredBox(
            color: Colors.black,
            child: Center(
              child: Icon(Icons.image_not_supported, color: Colors.white70),
            ),
          )
        : Image.memory(
            loaded.bytes!,
            fit: BoxFit.fill,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
          );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final maxWidth = constraints.maxWidth;
        final maxHeight = constraints.maxHeight;
        final imageAspect = loaded.width / loaded.height;
        final fixedAspectRatio = _mode == IntakeMode.pose
            ? _poseSelectionAspectRatioForIndex(
                index,
                imageAspectRatioOverride: imageAspect,
              )
            : null;

        var targetWidth = maxWidth;
        var targetHeight = targetWidth / imageAspect;
        if (targetHeight > maxHeight) {
          targetHeight = maxHeight;
          targetWidth = targetHeight * imageAspect;
        }

        return Center(
          child: SizedBox(
            width: targetWidth,
            height: targetHeight,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                imageWidget,
                _SelectionOverlay(
                  selection: _selections[index],
                  fixedAspectRatio: fixedAspectRatio,
                  onChanged: (RectSelection next) {
                    setState(() {
                      _selections[index] = next;
                    });
                  },
                  onInteractionChanged: _setSelectionInteractionActive,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomBar(IntakeImageHandle active) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              active.name,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: _buildModeButton(
                    label: 'Clothes',
                    icon: Icons.checkroom_outlined,
                    selected: _mode == IntakeMode.clothes,
                    onPressed: _busy
                        ? null
                        : () {
                            setState(() {
                              _mode = IntakeMode.clothes;
                            });
                          },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildModeButton(
                    label: 'Pose',
                    icon: Icons.accessibility_new,
                    selected: _mode == IntakeMode.pose,
                    onPressed: _busy ? null : _activatePoseMode,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _confirmCurrentSelection,
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(
                      'Add',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeButton({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback? onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(44),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        foregroundColor: selected ? Colors.black : Colors.white,
        side: BorderSide(color: selected ? Colors.white : Colors.white38),
        backgroundColor: selected ? Colors.white : const Color(0x1FFFFFFF),
      ),
    );
  }

  void _activatePoseMode() {
    if (_mode == IntakeMode.pose) {
      return;
    }
    setState(() {
      _mode = IntakeMode.pose;
      _applyPoseSelectionForIndex(
        _activeIndex,
        resetToViewportFrame: !_poseSelectionInitialized.contains(_activeIndex),
      );
    });
  }

  void _applyPoseSelectionForIndex(
    int index, {
    required bool resetToViewportFrame,
  }) {
    if (index < 0 || index >= _selections.length) {
      return;
    }
    final imageAspectRatio = _imageAspectRatioForIndex(index);
    if (imageAspectRatio == null) {
      return;
    }
    final aspectRatio = _poseSelectionAspectRatioForIndex(
      index,
      imageAspectRatioOverride: imageAspectRatio,
    );
    final next = resetToViewportFrame
        ? _largestSelectionForAspect(aspectRatio)
        : _coerceSelectionToAspect(_selections[index], aspectRatio);
    _selections[index] = next;
    _poseSelectionInitialized.add(index);
  }

  double _poseViewportAspectRatio() {
    final configuredAspect = widget.poseViewportAspectRatio;
    if (configuredAspect != null && configuredAspect > 0) {
      return configuredAspect.clamp(0.2, 5.0).toDouble();
    }
    return _poseFallbackAspectRatio;
  }

  double? _imageAspectRatioForIndex(int index) {
    final loaded = _loadedImages[index];
    if (loaded == null || loaded.width <= 0 || loaded.height <= 0) {
      return null;
    }
    return loaded.width / loaded.height;
  }

  double _poseSelectionAspectRatioForIndex(
    int index, {
    double? imageAspectRatioOverride,
  }) {
    final imageAspectRatio =
        imageAspectRatioOverride ?? _imageAspectRatioForIndex(index) ?? 1.0;
    return normalizedSelectionAspectRatio(
      viewportAspectRatio: _poseViewportAspectRatio(),
      imageAspectRatio: imageAspectRatio,
    );
  }

  RectSelection _largestSelectionForAspect(double aspectRatio) {
    final safeAspect = aspectRatio <= 0
        ? _poseFallbackAspectRatio
        : aspectRatio;
    var width = 1.0;
    var height = 1.0;

    if (safeAspect >= 1.0) {
      height = 1.0 / safeAspect;
    } else {
      width = safeAspect;
    }

    return RectSelection(
      left: (1.0 - width) / 2.0,
      top: (1.0 - height) / 2.0,
      width: width,
      height: height,
    ).clamp();
  }

  RectSelection _coerceSelectionToAspect(
    RectSelection selection,
    double aspectRatio,
  ) {
    final safeAspect = aspectRatio <= 0
        ? _poseFallbackAspectRatio
        : aspectRatio;
    final clamped = selection.clamp();

    final centerX = clamped.left + (clamped.width / 2.0);
    final centerY = clamped.top + (clamped.height / 2.0);

    var width = clamped.width;
    var height = width / safeAspect;
    if (height > clamped.height) {
      height = clamped.height;
      width = height * safeAspect;
    }

    final maxWidthAtCenter = 2.0 * math.min(centerX, 1.0 - centerX);
    final maxHeightAtCenter = 2.0 * math.min(centerY, 1.0 - centerY);
    if (width > maxWidthAtCenter) {
      width = maxWidthAtCenter;
      height = width / safeAspect;
    }
    if (height > maxHeightAtCenter) {
      height = maxHeightAtCenter;
      width = height * safeAspect;
    }

    width = width.clamp(0.02, 1.0).toDouble();
    height = height.clamp(0.02, 1.0).toDouble();
    if (height > 0) {
      width = (height * safeAspect).clamp(0.02, 1.0).toDouble();
      height = (width / safeAspect).clamp(0.02, 1.0).toDouble();
    }

    final left = (centerX - (width / 2.0)).clamp(0.0, 1.0 - width).toDouble();
    final top = (centerY - (height / 2.0)).clamp(0.0, 1.0 - height).toDouble();
    return RectSelection(
      left: left,
      top: top,
      width: width,
      height: height,
    ).clamp();
  }

  Future<void> _confirmCurrentSelection() async {
    final image = await _ensureImageLoaded(_activeIndex);
    if (image == null) {
      if (mounted) {
        _showSnack(
          'Could not load the selected image. Please swipe to another image.',
          isError: true,
        );
      }
      return;
    }
    final imageBytes = await _ensureImageBytes(
      index: _activeIndex,
      image: image,
    );
    if (imageBytes == null || imageBytes.isEmpty) {
      _showSnack('Could not read image bytes for this item.', isError: true);
      return;
    }
    final selection = _selections[_activeIndex];

    if (_mode == IntakeMode.clothes) {
      setState(() {
        _busy = true;
      });
      try {
        await widget.workspaceService.saveClothingSelection(
          imageBytes: imageBytes,
          selection: selection,
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _changed = true;
        });
        _showSnack('Saved clothing item for import.');
      } catch (error) {
        _showSnack('Failed to save clothing selection: $error', isError: true);
      } finally {
        if (mounted) {
          setState(() {
            _busy = false;
          });
        }
      }
      return;
    }

    final poseData = await _showPoseDialog(
      imageBytes,
      imageWidth: image.width,
      imageHeight: image.height,
      selection: selection,
    );
    if (poseData == null) {
      return;
    }

    setState(() {
      _busy = true;
    });
    try {
      await widget.workspaceService.savePoseSelection(
        imageBytes: imageBytes,
        selection: poseData.useFullImage ? null : selection,
        markers: IntakePoseMarkers(
          neckY: poseData.neckY,
          ankleY: poseData.ankleY,
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _changed = true;
      });
      _showSnack('Saved pose markers.');
    } catch (error) {
      _showSnack('Failed to save pose: $error', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<_PoseDialogResult?> _showPoseDialog(
    Uint8List bytes, {
    required int imageWidth,
    required int imageHeight,
    required RectSelection selection,
  }) async {
    if (!mounted) {
      return null;
    }

    return showDialog<_PoseDialogResult>(
      context: context,
      builder: (BuildContext context) {
        return _PoseMarkerDialog(
          bytes: bytes,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
          selection: selection,
        );
      },
    );
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
        backgroundColor: isError ? Colors.red.shade700 : null,
      ),
    );
  }

  void _setSelectionInteractionActive(bool active) {
    if (_selectionInteractionActive == active) {
      return;
    }
    setState(() {
      _selectionInteractionActive = active;
    });
  }
}

class _SelectionOverlay extends StatefulWidget {
  const _SelectionOverlay({
    required this.selection,
    required this.fixedAspectRatio,
    required this.onChanged,
    required this.onInteractionChanged,
  });

  final RectSelection selection;
  final double? fixedAspectRatio;
  final ValueChanged<RectSelection> onChanged;
  final ValueChanged<bool> onInteractionChanged;

  @override
  State<_SelectionOverlay> createState() => _SelectionOverlayState();
}

class _SelectionOverlayState extends State<_SelectionOverlay> {
  static const double _resizeHandleSize = 30;
  static const double _resizeHitSize = 128;

  Offset? _moveStartGlobal;
  RectSelection? _moveStartSelection;

  Offset? _resizeStartGlobal;
  RectSelection? _resizeStartSelection;
  final Set<int> _interactionPointerIds = <int>{};

  void _holdInteractionForPointer(PointerDownEvent event) {
    _interactionPointerIds.add(event.pointer);
    _notifyInteractionState();
  }

  void _releaseInteractionForPointer(PointerEvent event) {
    if (_interactionPointerIds.remove(event.pointer)) {
      _notifyInteractionState();
    }
  }

  void _startMove(DragStartDetails details) {
    _moveStartGlobal = details.globalPosition;
    _moveStartSelection = widget.selection;
    widget.onInteractionChanged(true);
  }

  void _updateMove(DragUpdateDetails details, double width, double height) {
    final startGlobal = _moveStartGlobal;
    final startSelection = _moveStartSelection;
    if (startGlobal == null ||
        startSelection == null ||
        width <= 0 ||
        height <= 0) {
      return;
    }

    final base = startSelection.clamp();
    final delta = details.globalPosition - startGlobal;
    final nextLeft = (base.left + (delta.dx / width))
        .clamp(0.0, 1.0 - base.width)
        .toDouble();
    final nextTop = (base.top + (delta.dy / height))
        .clamp(0.0, 1.0 - base.height)
        .toDouble();
    final next = RectSelection(
      left: nextLeft,
      top: nextTop,
      width: base.width,
      height: base.height,
    );
    widget.onChanged(next);
  }

  void _endMove() {
    _moveStartGlobal = null;
    _moveStartSelection = null;
    _notifyInteractionState();
  }

  void _startResize(DragStartDetails details) {
    _resizeStartGlobal = details.globalPosition;
    _resizeStartSelection = widget.selection;
    widget.onInteractionChanged(true);
  }

  void _updateResize(DragUpdateDetails details, double width, double height) {
    final startGlobal = _resizeStartGlobal;
    final startSelection = _resizeStartSelection;
    if (startGlobal == null ||
        startSelection == null ||
        width <= 0 ||
        height <= 0) {
      return;
    }

    final delta = details.globalPosition - startGlobal;
    final fixedAspectRatio = widget.fixedAspectRatio;
    final next = fixedAspectRatio == null
        ? RectSelection(
            left: startSelection.left,
            top: startSelection.top,
            width: startSelection.width + (delta.dx / width),
            height: startSelection.height + (delta.dy / height),
          ).clamp()
        : _resizeWithFixedAspectRatio(
            startSelection: startSelection,
            delta: delta,
            width: width,
            height: height,
            aspectRatio: fixedAspectRatio,
          );
    widget.onChanged(next);
  }

  RectSelection _resizeWithFixedAspectRatio({
    required RectSelection startSelection,
    required Offset delta,
    required double width,
    required double height,
    required double aspectRatio,
  }) {
    final safeAspect = aspectRatio <= 0 ? (9 / 16) : aspectRatio;
    final widthFromDx = startSelection.width + (delta.dx / width);
    final widthFromDy =
        (startSelection.height + (delta.dy / height)) * safeAspect;
    final dxDelta = widthFromDx - startSelection.width;
    final dyDelta = widthFromDy - startSelection.width;

    var nextWidth =
        startSelection.width +
        (dxDelta.abs() >= dyDelta.abs() ? dxDelta : dyDelta);
    final maxWidth = math.min(
      1.0 - startSelection.left,
      (1.0 - startSelection.top) * safeAspect,
    );
    final minWidth = math.max(0.02, 0.02 * safeAspect);
    final safeMaxWidth = math.max(minWidth, maxWidth);
    nextWidth = nextWidth.clamp(minWidth, safeMaxWidth).toDouble();

    var nextHeight = nextWidth / safeAspect;
    final maxHeight = 1.0 - startSelection.top;
    if (nextHeight > maxHeight) {
      nextHeight = maxHeight;
      nextWidth = nextHeight * safeAspect;
    }

    return RectSelection(
      left: startSelection.left,
      top: startSelection.top,
      width: nextWidth,
      height: nextHeight,
    ).clamp();
  }

  void _endResize() {
    _resizeStartGlobal = null;
    _resizeStartSelection = null;
    _notifyInteractionState();
  }

  void _notifyInteractionState() {
    final active =
        _moveStartGlobal != null ||
        _resizeStartGlobal != null ||
        _interactionPointerIds.isNotEmpty;
    widget.onInteractionChanged(active);
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final resizeHitInset = (_resizeHitSize - _resizeHandleSize) / 2;

        final leftPx = selection.left * width;
        final topPx = selection.top * height;
        final rectWidthPx = selection.width * width;
        final rectHeightPx = selection.height * height;

        return Stack(
          children: <Widget>[
            Positioned(
              left: leftPx,
              top: topPx,
              width: rectWidthPx,
              height: rectHeightPx,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Positioned.fill(
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: _holdInteractionForPointer,
                      onPointerUp: _releaseInteractionForPointer,
                      onPointerCancel: _releaseInteractionForPointer,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onPanStart: _startMove,
                        onPanUpdate: (DragUpdateDetails details) =>
                            _updateMove(details, width, height),
                        onPanEnd: (_) => _endMove(),
                        onPanCancel: _endMove,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 2),
                            color: Colors.white.withValues(alpha: 0.10),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: -resizeHitInset,
                    bottom: -resizeHitInset,
                    width: _resizeHitSize,
                    height: _resizeHitSize,
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: _holdInteractionForPointer,
                      onPointerUp: _releaseInteractionForPointer,
                      onPointerCancel: _releaseInteractionForPointer,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onPanStart: _startResize,
                        onPanUpdate: (DragUpdateDetails details) =>
                            _updateResize(details, width, height),
                        onPanEnd: (_) => _endResize(),
                        onPanCancel: _endResize,
                        child: Align(
                          alignment: Alignment.center,
                          child: Container(
                            width: _resizeHandleSize,
                            height: _resizeHandleSize,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.open_in_full,
                              size: 18,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PoseDialogResult {
  const _PoseDialogResult({
    required this.neckY,
    required this.ankleY,
    required this.useFullImage,
  });

  final double neckY;
  final double ankleY;
  final bool useFullImage;
}

class _PoseMarkerDialog extends StatefulWidget {
  const _PoseMarkerDialog({
    required this.bytes,
    required this.imageWidth,
    required this.imageHeight,
    required this.selection,
  });

  final Uint8List bytes;
  final int imageWidth;
  final int imageHeight;
  final RectSelection selection;
  @override
  State<_PoseMarkerDialog> createState() => _PoseMarkerDialogState();
}

class _PoseMarkerDialogState extends State<_PoseMarkerDialog> {
  static const double _markerMinGap = 0.08;

  double _neckY = 0.24;
  double _ankleY = 0.88;
  bool _useFullImage = false;
  late final _PosePreviewImage _fullPreview;
  late final _PosePreviewImage _cropPreview;

  @override
  void initState() {
    super.initState();
    _fullPreview = _PosePreviewImage(
      bytes: widget.bytes,
      width: widget.imageWidth,
      height: widget.imageHeight,
    );
    _cropPreview = _buildCropPreview();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final activePreview = _useFullImage ? _fullPreview : _cropPreview;
    final imageAspect = activePreview.width > 0 && activePreview.height > 0
        ? activePreview.width / activePreview.height
        : 3 / 4;
    final availableHeight = media.size.height - media.viewInsets.vertical;
    final dialogContentHeight = math.min(availableHeight * 0.56, 520.0);

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      title: const Text('Pose markers'),
      content: SizedBox(
        width: math.min(media.size.width - 32, 520),
        height: dialogContentHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Drag blue line to neck and orange line to ankle/shoes.',
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _useFullImage,
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              title: const Text('Use full image as pose'),
              onChanged: (bool? value) {
                setState(() {
                  _useFullImage = value ?? false;
                });
              },
            ),
            Expanded(
              child: AspectRatio(
                aspectRatio: imageAspect,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        Image.memory(activePreview.bytes, fit: BoxFit.contain),
                        _DraggableMarkerLine(
                          y: _neckY,
                          color: Colors.lightBlueAccent,
                          label: 'Neck',
                          onChanged: _setNeckY,
                        ),
                        _DraggableMarkerLine(
                          y: _ankleY,
                          color: Colors.orangeAccent,
                          label: 'Ankle',
                          onChanged: _setAnkleY,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              _PoseDialogResult(
                neckY: _neckY,
                ankleY: _ankleY,
                useFullImage: _useFullImage,
              ),
            );
          },
          child: const Text('Add'),
        ),
      ],
    );
  }

  void _setNeckY(double rawY) {
    final next = rawY.clamp(0.0, _ankleY - _markerMinGap);
    setState(() {
      _neckY = next;
    });
  }

  void _setAnkleY(double rawY) {
    final next = rawY.clamp(_neckY + _markerMinGap, 1.0);
    setState(() {
      _ankleY = next;
    });
  }

  _PosePreviewImage _buildCropPreview() {
    final decoded = img.decodeImage(widget.bytes);
    if (decoded == null) {
      return _fullPreview;
    }

    final clamped = widget.selection.clamp();
    final x = (clamped.left * decoded.width).round();
    final y = (clamped.top * decoded.height).round();
    final width = math.max(1, (clamped.width * decoded.width).round());
    final height = math.max(1, (clamped.height * decoded.height).round());

    final cropX = math.max(0, math.min(decoded.width - 1, x));
    final cropY = math.max(0, math.min(decoded.height - 1, y));
    final cropW = math.max(1, math.min(decoded.width - cropX, width));
    final cropH = math.max(1, math.min(decoded.height - cropY, height));

    final cropped = img.copyCrop(
      decoded,
      x: cropX,
      y: cropY,
      width: cropW,
      height: cropH,
    );

    return _PosePreviewImage(
      bytes: Uint8List.fromList(img.encodePng(cropped)),
      width: cropped.width,
      height: cropped.height,
    );
  }
}

class _PosePreviewImage {
  const _PosePreviewImage({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

class _DraggableMarkerLine extends StatelessWidget {
  const _DraggableMarkerLine({
    required this.y,
    required this.color,
    required this.label,
    required this.onChanged,
  });

  final double y;
  final Color color;
  final String label;
  final ValueChanged<double> onChanged;

  static const double _lineThickness = 3;
  static const double _hitHeight = 44;
  static const double _handleSize = 30;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final height = constraints.maxHeight;
        return Align(
          alignment: Alignment(0, y * 2 - 1),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragUpdate: (DragUpdateDetails details) {
              onChanged(y + (details.delta.dy / height));
            },
            child: SizedBox(
              width: double.infinity,
              height: _hitHeight,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: color.withValues(alpha: 0.9),
                          ),
                          boxShadow: const <BoxShadow>[
                            BoxShadow(
                              color: Colors.black54,
                              blurRadius: 6,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          child: Text(
                            label,
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                              shadows: const <Shadow>[
                                Shadow(
                                  color: Colors.black,
                                  blurRadius: 4,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.center,
                    child: Container(height: _lineThickness, color: color),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Container(
                        width: _handleSize,
                        height: _handleSize,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(_handleSize / 2),
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: const Icon(
                          Icons.drag_handle,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
