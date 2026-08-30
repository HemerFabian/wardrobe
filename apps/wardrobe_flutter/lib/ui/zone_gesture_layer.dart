import 'package:flutter/material.dart';

class ZoneMapper {
  const ZoneMapper();

  static const double horizontalSwipeThreshold = 12;

  String mapPointToCategory(Offset point, Size size) {
    if (size.height <= 0) {
      return 'top';
    }

    final yRatio = (point.dy / size.height).clamp(0.0, 1.0);

    if (yRatio <= 0.24) {
      return 'headwear';
    }
    if (yRatio <= 0.56) {
      return 'top';
    }
    if (yRatio <= 0.83) {
      return 'bottom';
    }
    return 'shoes';
  }

  int horizontalDirection({required Offset start, required Offset end}) {
    final dx = end.dx - start.dx;
    if (dx.abs() < horizontalSwipeThreshold) {
      return 0;
    }
    return dx > 0 ? 1 : -1;
  }
}

class ZoneGestureLayer extends StatefulWidget {
  const ZoneGestureLayer({
    super.key,
    required this.onCategorySwipe,
    this.onCategoryLongPress,
    this.mapper = const ZoneMapper(),
    this.showDebugZones = false,
  });

  final void Function(String category, int direction) onCategorySwipe;
  final void Function(String category)? onCategoryLongPress;
  final ZoneMapper mapper;
  final bool showDebugZones;

  @override
  State<ZoneGestureLayer> createState() => _ZoneGestureLayerState();
}

class _ZoneGestureLayerState extends State<ZoneGestureLayer> {
  Offset? _start;
  Offset? _latestDragPoint;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (DragStartDetails details) {
            _start = details.localPosition;
            _latestDragPoint = details.localPosition;
          },
          onHorizontalDragUpdate: (DragUpdateDetails details) {
            _latestDragPoint = details.localPosition;
          },
          onHorizontalDragEnd: (DragEndDetails details) {
            final start = _start;
            final latestDragPoint = _latestDragPoint;
            _start = null;
            _latestDragPoint = null;
            if (start == null) {
              return;
            }

            final velocity = details.velocity.pixelsPerSecond.dx;
            final estimatedEnd = Offset(start.dx + velocity * 0.03, start.dy);
            final resolvedEnd = latestDragPoint == null
                ? estimatedEnd
                : Offset(
                    latestDragPoint.dx + velocity * 0.01,
                    latestDragPoint.dy,
                  );
            final direction = widget.mapper.horizontalDirection(
              start: start,
              end: resolvedEnd,
            );
            if (direction == 0) {
              return;
            }

            final category = widget.mapper.mapPointToCategory(start, size);
            widget.onCategorySwipe(category, direction);
          },
          onLongPressStart: (LongPressStartDetails details) {
            final callback = widget.onCategoryLongPress;
            if (callback == null) {
              return;
            }
            final category = widget.mapper.mapPointToCategory(
              details.localPosition,
              size,
            );
            callback(category);
          },
          child: widget.showDebugZones
              ? IgnorePointer(child: _DebugZones())
              : const SizedBox.expand(),
        );
      },
    );
  }
}

class _DebugZones extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: const <Widget>[
        Expanded(
          flex: 24,
          child: ColoredBox(
            color: Color.fromARGB(25, 33, 150, 243),
            child: Center(child: Text('headwear')),
          ),
        ),
        Expanded(
          flex: 32,
          child: ColoredBox(
            color: Color.fromARGB(25, 76, 175, 80),
            child: Center(child: Text('top')),
          ),
        ),
        Expanded(
          flex: 27,
          child: ColoredBox(
            color: Color.fromARGB(25, 255, 152, 0),
            child: Center(child: Text('bottom')),
          ),
        ),
        Expanded(
          flex: 17,
          child: ColoredBox(
            color: Color.fromARGB(25, 244, 67, 54),
            child: Center(child: Text('shoes')),
          ),
        ),
      ],
    );
  }
}
