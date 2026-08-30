import 'dart:io';

import 'package:flutter/material.dart';

import '../services/wardrobe_repository.dart';

class OutfitView extends StatelessWidget {
  const OutfitView({
    super.key,
    required this.composition,
    required this.aspectRatio,
  });

  final OutfitComposition composition;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    if (!_hasUsableSource(composition.baseImagePath)) {
      return AspectRatio(
        aspectRatio: aspectRatio,
        child: _missingBasePlaceholder(),
      );
    }

    return AspectRatio(
      aspectRatio: aspectRatio,
      child: ColoredBox(
        color: Colors.grey.shade100,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _imageFromSource(
              composition.baseImagePath!,
              onErrorText: 'Base image failed',
              showPlaceholder: true,
            ),
            for (final overlayPath in composition.overlays)
              if (_hasUsableSource(overlayPath))
                _imageFromSource(overlayPath, onErrorText: 'Overlay failed'),
          ],
        ),
      ),
    );
  }

  bool _hasUsableSource(String? source) {
    if (source == null || source.isEmpty) {
      return false;
    }
    if (source.startsWith('data:')) {
      return true;
    }
    return File(source).existsSync();
  }

  Widget _imageFromSource(
    String source, {
    required String onErrorText,
    bool showPlaceholder = false,
  }) {
    if (source.startsWith('data:')) {
      return _buildImage(
        NetworkImage(source),
        source: source,
        onErrorText: onErrorText,
        showPlaceholder: showPlaceholder,
      );
    }

    return _buildImage(
      FileImage(File(source)),
      source: source,
      onErrorText: onErrorText,
      showPlaceholder: showPlaceholder,
    );
  }

  Widget _buildImage(
    ImageProvider image, {
    required String source,
    required String onErrorText,
    required bool showPlaceholder,
  }) {
    return Image(
      key: ValueKey<String>(source),
      image: image,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      frameBuilder:
          (
            BuildContext context,
            Widget child,
            int? frame,
            bool wasSynchronouslyLoaded,
          ) {
            if (wasSynchronouslyLoaded) {
              return child;
            }

            if (!showPlaceholder) {
              return child;
            }

            return Stack(
              fit: StackFit.expand,
              children: <Widget>[_renderPlaceholder(), child],
            );
          },
      errorBuilder:
          (BuildContext context, Object error, StackTrace? stackTrace) =>
              _renderError(onErrorText),
    );
  }

  Widget _renderError(String text) {
    return Center(
      child: ColoredBox(
        color: Colors.black54,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(text, style: const TextStyle(color: Colors.white)),
        ),
      ),
    );
  }

  Widget _renderPlaceholder() {
    return ColoredBox(color: Colors.grey.shade100);
  }

  Widget _missingBasePlaceholder() {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.grey.shade200,
      ),
      child: Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          color: Colors.grey.shade500,
          size: 44,
        ),
      ),
    );
  }
}
