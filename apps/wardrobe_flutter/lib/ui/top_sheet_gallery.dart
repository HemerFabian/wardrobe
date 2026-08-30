import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../services/wardrobe_repository.dart';
import 'filter_controls.dart';

enum _ManageDataAction { importPack, exportPack, clearPack }

enum _GallerySection { clothes, poses, favorites }

enum _ClothingCardMenuAction { edit, regenerate, delete }

enum _PoseCardMenuAction { edit, delete }

class TopSheetGalleryViewState {
  const TopSheetGalleryViewState({this.activeSectionIndex = 0});

  static const TopSheetGalleryViewState initial = TopSheetGalleryViewState();

  final int activeSectionIndex;

  TopSheetGalleryViewState copyWith({int? activeSectionIndex}) {
    return TopSheetGalleryViewState(
      activeSectionIndex: activeSectionIndex ?? this.activeSectionIndex,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is TopSheetGalleryViewState &&
        other.activeSectionIndex == activeSectionIndex;
  }

  @override
  int get hashCode => activeSectionIndex.hashCode;
}

class TopSheetGallery extends StatefulWidget {
  const TopSheetGallery({
    super.key,
    required this.repository,
    this.lockClothesSelection = false,
    this.onImportPack,
    this.onExportPack,
    this.onStartIntake,
    this.onClearPack,
    this.onDeleteClothingItem,
    this.onEditClothingItem,
    this.onToggleClothingRegeneration,
    this.onEditPose,
    this.onDeletePose,
    this.isBusy = false,
    this.initialViewState = TopSheetGalleryViewState.initial,
    this.onViewStateChanged,
  });

  final WardrobeRepository repository;
  final bool lockClothesSelection;
  final VoidCallback? onImportPack;
  final VoidCallback? onExportPack;
  final VoidCallback? onStartIntake;
  final VoidCallback? onClearPack;
  final Future<void> Function({
    required String category,
    required String itemId,
  })?
  onDeleteClothingItem;
  final Future<void> Function({
    required String category,
    required String itemId,
  })?
  onEditClothingItem;
  final Future<void> Function({
    required String category,
    required String itemId,
    required ClothingRegenerationScope scope,
  })?
  onToggleClothingRegeneration;
  final Future<void> Function({required String poseId, required String name})?
  onEditPose;
  final Future<void> Function({required String poseId})? onDeletePose;
  final bool isBusy;
  final TopSheetGalleryViewState initialViewState;
  final ValueChanged<TopSheetGalleryViewState>? onViewStateChanged;

  @override
  State<TopSheetGallery> createState() => _TopSheetGalleryState();
}

class _TopSheetGalleryState extends State<TopSheetGallery> {
  static const double _horizontalSwipeVelocityThreshold = 360;
  static const double _verticalSwipeVelocityThreshold = 520;
  static const double _stickyHeaderHeight = 36;
  static const double _clothesScrollTopPadding = 8;
  static const Duration _noMatchSnackBarDuration = Duration(milliseconds: 1800);
  static const Key _clothesViewportContainerKey = Key(
    'top-sheet-clothes-viewport',
  );

  _GallerySection _activeSection = _GallerySection.clothes;
  bool _deleteBusy = false;
  bool _showingNoMatchSnackBar = false;
  Timer? _noMatchSnackBarTimer;
  Timer? _jumpCompletionTimer;
  int _noMatchSnackBarToken = 0;
  final ScrollController _clothesScrollController = ScrollController();
  final GlobalKey _clothesViewportKey = GlobalKey();
  final Map<String, GlobalKey> _clothesSectionKeys = <String, GlobalKey>{};
  final Map<String, GlobalKey> _clothesItemKeys = <String, GlobalKey>{};
  List<ClothesNavSection> _clothesSections = const <ClothesNavSection>[];
  String? _activeCategory;
  String? _activeClothesSectionKey;
  bool _focusAlignmentScheduled = false;
  bool _isJumpingToSection = false;
  TopSheetGalleryViewState? _lastReportedViewState;

  bool get _isInteractionLocked => widget.isBusy || _deleteBusy;
  bool get _isClothesSelectionLocked =>
      _isInteractionLocked || widget.lockClothesSelection;

  @override
  void initState() {
    super.initState();
    _activeSection = _gallerySectionForIndex(
      widget.initialViewState.activeSectionIndex,
    );
    _activeCategory = widget.repository.clothesMainCategories.firstOrNull;
    _activeClothesSectionKey = _activeCategory == null
        ? null
        : widget.repository.firstSectionKeyForCategory(_activeCategory!);
    _clothesScrollController.addListener(_handleClothesScroll);
    widget.repository.addListener(_handleRepositoryChanged);
    _scheduleInitialScrollBehavior();
  }

  @override
  void dispose() {
    widget.repository.removeListener(_handleRepositoryChanged);
    _clothesScrollController.removeListener(_handleClothesScroll);
    _clothesScrollController.dispose();
    _noMatchSnackBarTimer?.cancel();
    _jumpCompletionTimer?.cancel();
    super.dispose();
  }

  void _handleRepositoryChanged() {
    if (!mounted) {
      return;
    }
    if (!widget.repository.hasActiveFilters && _showingNoMatchSnackBar) {
      _noMatchSnackBarTimer?.cancel();
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
    setState(() {});
    if (_needsRepositoryFocusAlignment()) {
      _scheduleInitialScrollBehavior();
    }
    _notifyViewStateChanged();
  }

  @override
  Widget build(BuildContext context) {
    final categories = widget.repository.clothesMainCategories;
    final hasCategories = categories.isNotEmpty;
    final clothesSections = hasCategories
        ? widget.repository.clothesSections()
        : const <ClothesNavSection>[];
    _syncClothesSections(
      clothesSections: clothesSections,
      categories: categories,
    );
    final poses = widget.repository.poseItems();
    final hasPoses = poses.isNotEmpty;
    final favorites = widget.repository.favoriteItems();
    final hasFavorites = favorites.isNotEmpty;

    if (_activeSection == _GallerySection.clothes && !hasCategories) {
      _activeSection = hasPoses
          ? _GallerySection.poses
          : _GallerySection.favorites;
    } else if (_activeSection == _GallerySection.poses && !hasPoses) {
      _activeSection = hasCategories
          ? _GallerySection.clothes
          : _GallerySection.favorites;
    }

    if (hasCategories &&
        (_activeCategory == null || !categories.contains(_activeCategory))) {
      _activeCategory = categories.first;
    }
    if (!hasCategories) {
      _activeCategory = null;
    }

    void openFiltersPanel() {
      showWardrobeFilterPanel(context: context, repository: widget.repository);
    }

    return SafeArea(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragEnd: _handleVerticalSwipe,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  const Icon(Icons.checkroom),
                  const SizedBox(width: 8),
                  const Text(
                    'Wardrobe',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const Spacer(),
                  PopupMenuButton<_ManageDataAction>(
                    tooltip: 'Manage Data',
                    onSelected: _handleManageDataAction,
                    itemBuilder: (BuildContext context) {
                      final canImport =
                          widget.onImportPack != null && !_isInteractionLocked;
                      final canExport =
                          widget.onExportPack != null && !_isInteractionLocked;
                      final canClear =
                          widget.onClearPack != null && !_isInteractionLocked;
                      return <PopupMenuEntry<_ManageDataAction>>[
                        PopupMenuItem<_ManageDataAction>(
                          value: _ManageDataAction.exportPack,
                          enabled: canExport,
                          child: const Row(
                            children: <Widget>[
                              Icon(Icons.ios_share_outlined, size: 18),
                              SizedBox(width: 8),
                              Text('Export'),
                            ],
                          ),
                        ),
                        PopupMenuItem<_ManageDataAction>(
                          value: _ManageDataAction.importPack,
                          enabled: canImport,
                          child: const Row(
                            children: <Widget>[
                              Icon(Icons.file_upload_outlined, size: 18),
                              SizedBox(width: 8),
                              Text('Import'),
                            ],
                          ),
                        ),
                        PopupMenuItem<_ManageDataAction>(
                          value: _ManageDataAction.clearPack,
                          enabled: canClear,
                          child: Row(
                            children: <Widget>[
                              Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: canClear
                                    ? Theme.of(context).colorScheme.error
                                    : null,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Clear',
                                style: canClear
                                    ? TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      )
                                    : null,
                              ),
                            ],
                          ),
                        ),
                      ];
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const <Widget>[
                          Icon(Icons.more_horiz, size: 18),
                          SizedBox(width: 6),
                          Text('Manage Data'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: <Widget>[
                    if (widget.onStartIntake != null)
                      FilledButton.tonalIcon(
                        onPressed: _isInteractionLocked
                            ? null
                            : () {
                                Navigator.of(context).pop();
                                widget.onStartIntake?.call();
                              },
                        icon: const Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 18,
                        ),
                        label: const Text('Add Photos'),
                      )
                    else
                      const Spacer(),
                    if (widget.onStartIntake != null) const Spacer(),
                    FilterIconButton(onPressed: openFiltersPanel),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SegmentedButton<_GallerySection>(
                        showSelectedIcon: false,
                        segments: const <ButtonSegment<_GallerySection>>[
                          ButtonSegment<_GallerySection>(
                            value: _GallerySection.clothes,
                            icon: Icon(Icons.checkroom_outlined),
                            label: Text('Clothes'),
                          ),
                          ButtonSegment<_GallerySection>(
                            value: _GallerySection.poses,
                            icon: Icon(Icons.accessibility_new),
                            label: Text('Poses'),
                          ),
                          ButtonSegment<_GallerySection>(
                            value: _GallerySection.favorites,
                            icon: Icon(Icons.star_outline_rounded),
                            label: Text('Favorites'),
                          ),
                        ],
                        selected: <_GallerySection>{_activeSection},
                        onSelectionChanged: (Set<_GallerySection> values) {
                          if (values.isEmpty) {
                            return;
                          }
                          final nextSection = values.first;
                          setState(() {
                            _activeSection = nextSection;
                          });
                          if (nextSection == _GallerySection.clothes) {
                            _scheduleInitialScrollBehavior();
                          }
                          _notifyViewStateChanged();
                        },
                      ),
                    ),
                    if (_activeSection == _GallerySection.clothes &&
                        hasCategories)
                      Expanded(
                        child: Column(
                          children: <Widget>[
                            if (widget.lockClothesSelection)
                              Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .secondaryContainer
                                      .withValues(alpha: 0.58),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  'Pending pose selected: clothing changes are locked.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSecondaryContainer,
                                  ),
                                ),
                              ),
                            if (widget.repository.hasActiveFilters)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: FilterSummaryBar(
                                  repository: widget.repository,
                                  compact: true,
                                  showWhenInactive: false,
                                  showOpenButtonInActive: false,
                                  onOpenFilters: openFiltersPanel,
                                ),
                              ),
                            Expanded(
                              child: _buildClothesPanel(
                                categories: categories,
                                sections: clothesSections,
                              ),
                            ),
                          ],
                        ),
                      )
                    else if (_activeSection == _GallerySection.poses &&
                        hasPoses)
                      Expanded(
                        child: GridView.builder(
                          shrinkWrap: true,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                mainAxisSpacing: 10,
                                crossAxisSpacing: 10,
                                childAspectRatio: 0.8,
                              ),
                          itemCount: poses.length,
                          itemBuilder: (BuildContext context, int index) {
                            final pose = poses[index];
                            return _PoseGalleryCard(
                              item: pose,
                              onTap: _isInteractionLocked
                                  ? null
                                  : () {
                                      widget.repository.selectPose(pose.id);
                                      setState(() {});
                                    },
                              onEdit:
                                  _isInteractionLocked ||
                                      widget.onEditPose == null
                                  ? null
                                  : () => _openEditPose(item: pose),
                              onDelete:
                                  _isInteractionLocked ||
                                      widget.onDeletePose == null
                                  ? null
                                  : () => _confirmDeletePose(item: pose),
                            );
                          },
                        ),
                      )
                    else if (_activeSection == _GallerySection.favorites &&
                        hasFavorites)
                      Expanded(
                        child: GridView.builder(
                          shrinkWrap: true,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: 10,
                                crossAxisSpacing: 10,
                                childAspectRatio: 0.72,
                              ),
                          itemCount: favorites.length,
                          itemBuilder: (BuildContext context, int index) {
                            final favorite = favorites[index];
                            return _FavoriteGalleryCard(
                              item: favorite,
                              onTap: _isInteractionLocked
                                  ? null
                                  : () {
                                      widget.repository.selectPendingFavorite(
                                        favorite.key,
                                      );
                                      setState(() {});
                                    },
                            );
                          },
                        ),
                      )
                    else
                      Expanded(
                        child: Center(
                          child: Text(
                            _emptyStateTextForCurrentSection(),
                            style: TextStyle(color: Colors.grey.shade600),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _syncClothesSections({
    required List<ClothesNavSection> clothesSections,
    required List<String> categories,
  }) {
    _clothesSections = clothesSections;

    final validKeys = clothesSections
        .map((ClothesNavSection section) => section.key)
        .toSet();
    _clothesSectionKeys.removeWhere(
      (String key, GlobalKey value) => !validKeys.contains(key),
    );
    for (final section in clothesSections) {
      _clothesSectionKeys.putIfAbsent(section.key, () => GlobalKey());
    }

    final validItemKeys = clothesSections
        .expand(
          (ClothesNavSection section) => section.items.map(
            (GalleryItem item) =>
                _itemRenderKey(sectionKey: section.key, itemId: item.id),
          ),
        )
        .toSet();
    _clothesItemKeys.removeWhere(
      (String key, GlobalKey value) => !validItemKeys.contains(key),
    );
    for (final section in clothesSections) {
      for (final item in section.items) {
        _clothesItemKeys.putIfAbsent(
          _itemRenderKey(sectionKey: section.key, itemId: item.id),
          () => GlobalKey(),
        );
      }
    }

    if (clothesSections.isEmpty) {
      _activeCategory = null;
      _activeClothesSectionKey = null;
      _notifyViewStateChanged();
      return;
    }

    final currentSection = _activeClothesSectionKey == null
        ? null
        : clothesSections
              .where(
                (ClothesNavSection section) =>
                    section.key == _activeClothesSectionKey,
              )
              .firstOrNull;
    final nextSection = currentSection ?? clothesSections.first;
    final didChange =
        _activeCategory != nextSection.category ||
        _activeClothesSectionKey != nextSection.key;
    _activeCategory = nextSection.category;
    _activeClothesSectionKey = nextSection.key;
    if (didChange) {
      _notifyViewStateChanged();
    }
  }

  String _itemRenderKey({required String sectionKey, required String? itemId}) {
    return '$sectionKey|${itemId ?? '__none__'}';
  }

  ClothesNavSection? _resolvedClothesSection({
    required List<ClothesNavSection> sections,
  }) {
    if (sections.isEmpty) {
      return null;
    }

    final focus = widget.repository.clothesFocus;
    if (focus != null) {
      if (focus.itemId != null) {
        final section = _sectionForCategoryItem(
          category: focus.category,
          itemId: focus.itemId,
        );
        if (section != null) {
          return section;
        }
      }

      if (focus.sectionKey != null) {
        final section = sections
            .where((ClothesNavSection entry) => entry.key == focus.sectionKey)
            .firstOrNull;
        if (section != null) {
          return section;
        }
      }

      final section = sections
          .where((ClothesNavSection entry) => entry.category == focus.category)
          .firstOrNull;
      if (section != null) {
        return section;
      }
    }

    return sections.first;
  }

  ClothesNavSection? _activeClothesSection({
    required List<ClothesNavSection> sections,
  }) {
    if (sections.isEmpty) {
      return null;
    }
    if (_activeClothesSectionKey != null) {
      final current = sections
          .where(
            (ClothesNavSection section) =>
                section.key == _activeClothesSectionKey,
          )
          .firstOrNull;
      if (current != null) {
        return current;
      }
    }
    return sections.first;
  }

  Widget _buildClothesPanel({
    required List<String> categories,
    required List<ClothesNavSection> sections,
  }) {
    final railNodes = widget.repository.clothesRailNodes(sections: sections);
    final activeSection = _activeClothesSection(sections: sections);
    final activeSectionKey = activeSection?.key;
    final activeCategory = activeSection?.category;

    if (activeCategory != null && activeCategory != _activeCategory) {
      _activeCategory = activeCategory;
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: _handleHorizontalSwipe,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Theme.of(context).colorScheme.surface,
              Theme.of(
                context,
              ).colorScheme.surfaceContainer.withValues(alpha: 0.94),
            ],
          ),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 1,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                width: 56,
                child: _buildClothesRail(
                  categories: categories,
                  railNodes: railNodes,
                  activeSectionKey: activeSectionKey,
                  activeCategory: activeCategory,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Column(
                    children: <Widget>[
                      Container(
                        height: _stickyHeaderHeight,
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.6),
                          border: Border(
                            bottom: BorderSide(color: Colors.grey.shade200),
                          ),
                        ),
                        child: Text(
                          activeSection?.displayLabel ?? 'Clothes',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Container(
                          key: _clothesViewportContainerKey,
                          child: SingleChildScrollView(
                            key: _clothesViewportKey,
                            controller: _clothesScrollController,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                8,
                                _clothesScrollTopPadding,
                                8,
                                0,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: _buildClothesSectionChildren(
                                  sections,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildClothesSectionChildren(List<ClothesNavSection> sections) {
    final children = <Widget>[];
    for (var index = 0; index < sections.length; index++) {
      if (index > 0) {
        final nextLabel = sections[index].displayLabel;
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
            child: Row(
              children: <Widget>[
                Expanded(child: Divider(color: Colors.grey.shade300)),
                const SizedBox(width: 8),
                Text(
                  'NEXT • $nextLabel',
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.35,
                  ),
                ),
              ],
            ),
          ),
        );
      }

      final section = sections[index];
      children.add(
        KeyedSubtree(
          key: _clothesSectionKeys[section.key],
          child: _buildClothesSection(section: section),
        ),
      );
    }
    return children;
  }

  Widget _buildClothesRail({
    required List<String> categories,
    required List<ClothesRailNode> railNodes,
    required String? activeSectionKey,
    required String? activeCategory,
  }) {
    final nodesByCategory = <String, ClothesRailNode>{
      for (final node in railNodes) node.category: node,
    };

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: categories.length,
      itemBuilder: (BuildContext context, int index) {
        final category = categories[index];
        final node =
            nodesByCategory[category] ??
            ClothesRailNode(
              category: category,
              label: _prettyCategory(category),
              hasItems: false,
              subcategories: const <ClothesRailSubcategoryNode>[],
            );
        final isActiveCategory =
            category == activeCategory || category == _activeCategory;
        return _buildRailCategoryNode(
          node: node,
          isActiveCategory: isActiveCategory,
          activeSectionKey: activeSectionKey,
          isFirst: index == 0,
          isLast: index == categories.length - 1,
        );
      },
    );
  }

  Widget _buildRailCategoryNode({
    required ClothesRailNode node,
    required bool isActiveCategory,
    required String? activeSectionKey,
    required bool isFirst,
    required bool isLast,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final lineColor = Colors.grey.shade300;
    const primaryNodeSize = 34.0;
    const secondaryNodeSize = 8.0;
    const secondaryNodeTapSize = 14.0;
    const secondaryNodesTopGap = 2.0;
    const connectorWidth = 2.0;
    final connectorLeft = (primaryNodeSize - connectorWidth) / 2;
    final connectorEdgeInset = primaryNodeSize / 2;

    final dotNodes = node.subcategories.take(3).toList(growable: false);
    final overflowNodes = node.subcategories
        .skip(dotNodes.length)
        .toList(growable: false);
    final hasOverflowBadge = overflowNodes.isNotEmpty;
    final overflowIsActive = overflowNodes.any(
      (ClothesRailSubcategoryNode subcategory) =>
          subcategory.sectionKey == activeSectionKey,
    );
    final hasSecondaryNodes = dotNodes.isNotEmpty || hasOverflowBadge;
    final connectorBottomInset = isLast
        ? (hasSecondaryNodes ? secondaryNodeTapSize / 2 : connectorEdgeInset)
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Stack(
        children: <Widget>[
          Positioned(
            left: connectorLeft,
            top: isFirst ? connectorEdgeInset : 0,
            bottom: connectorBottomInset,
            child: Container(width: connectorWidth, color: lineColor),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: primaryNodeSize,
                  height: primaryNodeSize,
                  child: Tooltip(
                    message: 'Jump to ${node.label}',
                    child: Material(
                      color: Colors.transparent,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () async {
                          final sectionKey = widget.repository
                              .firstSectionKeyForCategory(node.category);
                          if (sectionKey == null) {
                            return;
                          }
                          await _scrollToSection(sectionKey: sectionKey);
                        },
                        child: Container(
                          width: primaryNodeSize,
                          height: primaryNodeSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isActiveCategory
                                ? null
                                : Colors.white.withValues(alpha: 0.74),
                            gradient: isActiveCategory
                                ? LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: <Color>[
                                      colorScheme.primary,
                                      colorScheme.secondary,
                                    ],
                                  )
                                : null,
                            border: Border.all(
                              color: isActiveCategory
                                  ? colorScheme.primary.withValues(alpha: 0.4)
                                  : Colors.white.withValues(alpha: 0.9),
                            ),
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: isActiveCategory
                                    ? colorScheme.primary.withValues(
                                        alpha: 0.28,
                                      )
                                    : Colors.black.withValues(alpha: 0.06),
                                blurRadius: isActiveCategory ? 10 : 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: IconTheme(
                            data: IconThemeData(
                              color: isActiveCategory
                                  ? colorScheme.onPrimary
                                  : Colors.grey.shade700,
                            ),
                            child: _iconForCategory(node.category),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (dotNodes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: secondaryNodesTopGap),
                    child: Column(
                      children: <Widget>[
                        for (final subcategory in dotNodes)
                          SizedBox(
                            width: primaryNodeSize,
                            height: secondaryNodeTapSize,
                            child: Center(
                              child: Tooltip(
                                message:
                                    'Jump to ${node.label} / ${subcategory.label}',
                                child: Material(
                                  color: Colors.transparent,
                                  shape: const CircleBorder(),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: () async {
                                      await _scrollToSection(
                                        sectionKey: subcategory.sectionKey,
                                      );
                                    },
                                    child: SizedBox(
                                      width: secondaryNodeTapSize,
                                      height: secondaryNodeTapSize,
                                      child: Center(
                                        child: Container(
                                          width: secondaryNodeSize,
                                          height: secondaryNodeSize,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color:
                                                activeSectionKey ==
                                                    subcategory.sectionKey
                                                ? colorScheme.primary
                                                : Colors.grey.shade400,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (hasOverflowBadge)
                          SizedBox(
                            width: primaryNodeSize,
                            height: secondaryNodeTapSize,
                            child: Center(
                              child: Tooltip(
                                message: 'More ${node.label} sections',
                                child: Material(
                                  color: Colors.transparent,
                                  borderRadius: BorderRadius.circular(999),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: () => _showOverflowSubcategorySheet(
                                      node: node,
                                      overflowNodes: overflowNodes,
                                      activeSectionKey: activeSectionKey,
                                    ),
                                    child: Container(
                                      key: Key(
                                        'rail-overflow-${node.category}',
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: overflowIsActive
                                            ? colorScheme.primary
                                            : Colors.white,
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        border: Border.all(
                                          color: overflowIsActive
                                              ? colorScheme.primary
                                              : Colors.grey.shade400,
                                        ),
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        '+${overflowNodes.length}',
                                        style: TextStyle(
                                          fontSize: 8,
                                          fontWeight: FontWeight.w700,
                                          color: overflowIsActive
                                              ? colorScheme.onPrimary
                                              : Colors.grey.shade700,
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showOverflowSubcategorySheet({
    required ClothesRailNode node,
    required List<ClothesRailSubcategoryNode> overflowNodes,
    required String? activeSectionKey,
  }) async {
    if (overflowNodes.isEmpty) {
      return;
    }

    final selectedSectionKey = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) {
        final maxHeight = MediaQuery.of(context).size.height * 0.5;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${node.label} sections',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: <Widget>[
                      for (final subcategory in overflowNodes)
                        ListTile(
                          title: Text(subcategory.label),
                          trailing: activeSectionKey == subcategory.sectionKey
                              ? const Icon(Icons.check_rounded)
                              : null,
                          onTap: () =>
                              Navigator.of(context).pop(subcategory.sectionKey),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (selectedSectionKey == null) {
      return;
    }
    await _scrollToSection(sectionKey: selectedSectionKey);
  }

  Widget _buildClothesSection({required ClothesNavSection section}) {
    final hasNoFilterMatches =
        widget.repository.hasActiveFilters &&
        widget.repository.filteredMatchCountForCategory(section.category) == 0;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final gridWidth = constraints.maxWidth;
        final crossAxisCount = gridWidth >= 230
            ? 3
            : (gridWidth >= 150 ? 2 : 1);

        return Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 4,
                    height: 14,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      section.displayLabel,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (hasNoFilterMatches)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.errorContainer.withValues(alpha: 0.52),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '0 matches for active filters in ${_prettyCategory(section.category)}.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (section.items.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.55),
                    border: Border.all(color: Colors.grey.shade200),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'No items in this category yet.',
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                  ),
                )
              else
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.82,
                  ),
                  itemCount: section.items.length,
                  itemBuilder: (BuildContext context, int index) {
                    final item = section.items[index];
                    return KeyedSubtree(
                      key:
                          _clothesItemKeys[_itemRenderKey(
                            sectionKey: section.key,
                            itemId: item.id,
                          )],
                      child: _GalleryCard(
                        item: item,
                        onTap: item.isDisabled || _isClothesSelectionLocked
                            ? null
                            : () {
                                _selectPendingItem(
                                  category: section.category,
                                  itemId: item.id,
                                );
                              },
                        onEdit:
                            item.id == null ||
                                _isInteractionLocked ||
                                section.category ==
                                    WardrobeRepository
                                        .uncategorizedIntakeCategory ||
                                widget.onEditClothingItem == null
                            ? null
                            : () => _openEditClothingItem(
                                category: section.category,
                                itemId: item.id!,
                              ),
                        onRegenerate:
                            item.id == null ||
                                item.isPending ||
                                _isInteractionLocked ||
                                section.category ==
                                    WardrobeRepository
                                        .uncategorizedIntakeCategory ||
                                widget.onToggleClothingRegeneration == null
                            ? null
                            : () => _toggleClothingRegeneration(
                                category: section.category,
                                item: item,
                              ),
                        isQueuedForRegeneration: item.id == null
                            ? false
                            : _isClothingQueuedForRegeneration(
                                category: section.category,
                                itemId: item.id!,
                              ),
                        onDelete:
                            item.id == null ||
                                _isInteractionLocked ||
                                widget.onDeleteClothingItem == null
                            ? null
                            : () => _confirmDeleteClothingItem(
                                item: item,
                                category: section.category,
                              ),
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  void _scheduleInitialScrollBehavior({int attempt = 0}) {
    if (_focusAlignmentScheduled) {
      return;
    }
    _focusAlignmentScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _focusAlignmentScheduled = false;
      if (!mounted) {
        return;
      }
      await _applyInitialScrollBehavior(attempt: attempt);
    });
  }

  Future<void> _applyInitialScrollBehavior({required int attempt}) async {
    final focused = await _scrollToRepositoryFocus(animate: false);
    final aligned = focused && _repositoryFocusAligned();
    if (!aligned && attempt < 6) {
      setState(() {});
      _scheduleInitialScrollBehavior(attempt: attempt + 1);
      return;
    }
    _notifyViewStateChanged();
  }

  Future<bool> _scrollToRepositoryFocus({required bool animate}) async {
    final focus = widget.repository.clothesFocus;
    final section = _resolvedClothesSection(sections: _clothesSections);
    if (section == null) {
      return false;
    }

    final targetItemId =
        focus != null &&
            focus.itemId != null &&
            section.category == focus.category &&
            section.items.any((GalleryItem item) => item.id == focus.itemId)
        ? focus.itemId
        : null;

    final alignedSection = await _scrollToSection(
      sectionKey: section.key,
      animate: animate,
    );
    if (!alignedSection) {
      return false;
    }
    if (targetItemId != null) {
      await WidgetsBinding.instance.endOfFrame;
      await _scrollToItem(
        category: section.category,
        itemId: targetItemId,
        animate: false,
        preferredTopInset: 46,
      );
    }
    return true;
  }

  Future<bool> _scrollToItem({
    required String category,
    required String? itemId,
    required bool animate,
    double preferredTopInset = 0,
  }) async {
    final targetSection = _sectionForCategoryItem(
      category: category,
      itemId: itemId,
    );
    if (targetSection == null) {
      return false;
    }
    if (itemId == null) {
      return _scrollToSection(sectionKey: targetSection.key, animate: animate);
    }

    final itemContext =
        _clothesItemKeys[_itemRenderKey(
              sectionKey: targetSection.key,
              itemId: itemId,
            )]
            ?.currentContext;
    if (itemContext == null) {
      return _scrollToSection(sectionKey: targetSection.key, animate: animate);
    }
    return _scrollToContext(
      targetContext: itemContext,
      targetSection: targetSection,
      focusedItemId: itemId,
      animate: animate,
      topInset: preferredTopInset,
    );
  }

  Future<bool> _scrollToSection({
    required String sectionKey,
    bool animate = true,
  }) async {
    final targetSection = _clothesSections
        .where((ClothesNavSection section) => section.key == sectionKey)
        .firstOrNull;
    if (targetSection == null) {
      return false;
    }
    final sectionContext = _clothesSectionKeys[sectionKey]?.currentContext;
    if (sectionContext == null) {
      return false;
    }
    return _scrollToContext(
      targetContext: sectionContext,
      targetSection: targetSection,
      focusedItemId: null,
      animate: animate,
    );
  }

  Future<bool> _scrollToContext({
    required BuildContext targetContext,
    required ClothesNavSection targetSection,
    required String? focusedItemId,
    required bool animate,
    double topInset = 0,
  }) async {
    final targetOffset = _targetOffsetForContext(
      targetContext,
      topInset: topInset,
    );
    if (targetOffset == null) {
      return false;
    }

    _isJumpingToSection = true;
    try {
      if ((_clothesScrollController.offset - targetOffset).abs() > 0.5) {
        if (animate) {
          await _clothesScrollController.animateTo(
            targetOffset,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          );
        } else {
          _clothesScrollController.jumpTo(targetOffset);
          await WidgetsBinding.instance.endOfFrame;
        }
      }
      _setActiveSection(targetSection, focusedItemId: focusedItemId);
      return true;
    } finally {
      _jumpCompletionTimer?.cancel();
      _jumpCompletionTimer = Timer(const Duration(milliseconds: 120), () {
        _isJumpingToSection = false;
      });
    }
  }

  double? _targetOffsetForContext(
    BuildContext targetContext, {
    double topInset = 0,
  }) {
    if (!_clothesScrollController.hasClients) {
      return null;
    }

    final viewportContext = _clothesViewportKey.currentContext;
    final viewportRenderObject = viewportContext?.findRenderObject();
    final targetRenderObject = targetContext.findRenderObject();
    if (viewportRenderObject is! RenderBox ||
        !viewportRenderObject.hasSize ||
        targetRenderObject is! RenderBox ||
        !targetRenderObject.hasSize) {
      return null;
    }

    final viewportTop = viewportRenderObject.localToGlobal(Offset.zero).dy;
    final targetTop = targetRenderObject.localToGlobal(Offset.zero).dy;
    final maxExtent = _clothesScrollController.position.maxScrollExtent;
    return (_clothesScrollController.offset +
            (targetTop - viewportTop) -
            _clothesScrollTopPadding -
            topInset)
        .clamp(0.0, maxExtent)
        .toDouble();
  }

  ClothesNavSection? _firstSectionForCategory(String category) {
    for (final section in _clothesSections) {
      if (section.category == category) {
        return section;
      }
    }
    return null;
  }

  ClothesNavSection? _sectionForCategoryItem({
    required String category,
    required String? itemId,
  }) {
    final firstSection = _firstSectionForCategory(category);
    if (itemId == null) {
      return firstSection;
    }
    for (final section in _clothesSections) {
      if (section.category != category) {
        continue;
      }
      if (section.items.any((GalleryItem item) => item.id == itemId)) {
        return section;
      }
    }
    return firstSection;
  }

  bool _needsRepositoryFocusAlignment() {
    if (_activeSection != _GallerySection.clothes || _clothesSections.isEmpty) {
      return false;
    }
    return !_repositoryFocusAligned();
  }

  bool _repositoryFocusAligned() {
    final section = _resolvedClothesSection(sections: _clothesSections);
    if (section == null || !_isSectionNearViewportTop(section.key)) {
      return false;
    }

    final focus = widget.repository.clothesFocus;
    if (focus?.itemId == null) {
      return true;
    }
    return _isClothesItemVisible(
      sectionKey: section.key,
      itemId: focus!.itemId!,
    );
  }

  bool _isSectionNearViewportTop(String sectionKey, {double tolerance = 28}) {
    final context = _clothesSectionKeys[sectionKey]?.currentContext;
    if (context == null) {
      return false;
    }
    final viewportContext = _clothesViewportKey.currentContext;
    final viewportRenderObject = viewportContext?.findRenderObject();
    final sectionRenderObject = context.findRenderObject();
    if (viewportRenderObject is! RenderBox ||
        !viewportRenderObject.hasSize ||
        sectionRenderObject is! RenderBox ||
        !sectionRenderObject.hasSize) {
      return false;
    }
    final viewportTop = viewportRenderObject.localToGlobal(Offset.zero).dy;
    final sectionTop = sectionRenderObject.localToGlobal(Offset.zero).dy;
    final delta = sectionTop - viewportTop;
    return delta >= 0 && delta <= tolerance;
  }

  bool _isContextVisibleInClothesViewport(BuildContext targetContext) {
    final viewportContext = _clothesViewportKey.currentContext;
    final viewportRenderObject = viewportContext?.findRenderObject();
    final targetRenderObject = targetContext.findRenderObject();
    if (viewportRenderObject is! RenderBox ||
        !viewportRenderObject.hasSize ||
        targetRenderObject is! RenderBox ||
        !targetRenderObject.hasSize) {
      return false;
    }
    final viewportRect =
        viewportRenderObject.localToGlobal(Offset.zero) &
        viewportRenderObject.size;
    final targetRect =
        targetRenderObject.localToGlobal(Offset.zero) & targetRenderObject.size;
    return targetRect.bottom > viewportRect.top &&
        targetRect.top < viewportRect.bottom;
  }

  bool _isClothesItemVisible({
    required String sectionKey,
    required String itemId,
  }) {
    final itemContext =
        _clothesItemKeys[_itemRenderKey(sectionKey: sectionKey, itemId: itemId)]
            ?.currentContext;
    if (itemContext == null) {
      return false;
    }
    return _isContextVisibleInClothesViewport(itemContext);
  }

  void _setActiveSection(ClothesNavSection section, {String? focusedItemId}) {
    if (_activeClothesSectionKey == section.key &&
        _activeCategory == section.category) {
      widget.repository.setClothesFocus(
        category: section.category,
        sectionKey: section.key,
        itemId: focusedItemId,
        notify: false,
      );
      return;
    }
    if (mounted) {
      setState(() {
        _activeClothesSectionKey = section.key;
        _activeCategory = section.category;
      });
    } else {
      _activeClothesSectionKey = section.key;
      _activeCategory = section.category;
    }
    widget.repository.setClothesFocus(
      category: section.category,
      sectionKey: section.key,
      itemId: focusedItemId,
      notify: false,
    );
    _notifyViewStateChanged();
  }

  void _handleClothesScroll() {
    _notifyViewStateChanged();
    if (_isJumpingToSection || _activeSection != _GallerySection.clothes) {
      return;
    }
    _updateActiveSectionFromScroll();
  }

  void _updateActiveSectionFromScroll() {
    final viewportContext = _clothesViewportKey.currentContext;
    if (viewportContext == null || _clothesSections.isEmpty) {
      return;
    }

    final viewportRenderObject = viewportContext.findRenderObject();
    if (viewportRenderObject is! RenderBox || !viewportRenderObject.hasSize) {
      return;
    }

    final thresholdY = viewportRenderObject.localToGlobal(Offset.zero).dy + 12;
    ClothesNavSection? nextSection;
    double bestTop = double.negativeInfinity;
    double closestTop = double.infinity;
    ClothesNavSection? closestSection;

    for (final section in _clothesSections) {
      final keyContext = _clothesSectionKeys[section.key]?.currentContext;
      if (keyContext == null) {
        continue;
      }
      final renderObject = keyContext.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) {
        continue;
      }
      final top = renderObject.localToGlobal(Offset.zero).dy;

      if (top <= thresholdY && top > bestTop) {
        bestTop = top;
        nextSection = section;
      }
      if (top < closestTop) {
        closestTop = top;
        closestSection = section;
      }
    }

    final resolved = nextSection ?? closestSection;
    if (resolved == null || resolved.key == _activeClothesSectionKey) {
      return;
    }

    _setActiveSection(resolved, focusedItemId: null);
  }

  Widget _iconForCategory(String category) {
    switch (category) {
      case 'headwear':
        return Icon(MdiIcons.hatFedora, size: 18);
      case 'top':
        return Icon(MdiIcons.tshirtCrew, size: 18);
      case 'bottom':
        return const PantsIcon(size: 18);
      case 'shoes':
        return Icon(MdiIcons.shoeSneaker, size: 18);
      case WardrobeRepository.uncategorizedIntakeCategory:
        return const Icon(Icons.question_mark_rounded, size: 18);
      default:
        return const Icon(Icons.category, size: 18);
    }
  }

  String _prettyCategory(String category) {
    if (category == WardrobeRepository.uncategorizedIntakeCategory) {
      return WardrobeRepository.uncategorizedIntakeLabel;
    }
    if (category.isEmpty) {
      return category;
    }
    return '${category[0].toUpperCase()}${category.substring(1)}';
  }

  String _emptyStateTextForCurrentSection() {
    switch (_activeSection) {
      case _GallerySection.clothes:
        return 'No categories yet. Add photos to start.';
      case _GallerySection.poses:
        return 'No poses yet. Add photos to create one.';
      case _GallerySection.favorites:
        return 'No favorites yet. Tap the star on an outfit.';
    }
  }

  void _handleHorizontalSwipe(DragEndDetails details) {
    if (_activeSection != _GallerySection.clothes) {
      return;
    }
    final activeCategory = _activeCategory;
    if (_isClothesSelectionLocked ||
        activeCategory == null ||
        activeCategory == WardrobeRepository.uncategorizedIntakeCategory) {
      return;
    }
    final velocity = details.velocity.pixelsPerSecond.dx;
    if (velocity.abs() < _horizontalSwipeVelocityThreshold) {
      return;
    }
    final direction = velocity > 0 ? 1 : -1;
    final result = widget.repository.cyclePendingCategoryFiltered(
      activeCategory,
      direction,
    );
    if (result.changed) {
      setState(() {});
      return;
    }
    if (result.blockedNoMatches && mounted) {
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
                result.reason ??
                    'No filtered items available for this category.',
              ),
              duration: _noMatchSnackBarDuration,
              action: SnackBarAction(
                label: 'Clear filters',
                onPressed: widget.repository.clearAllFilters,
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

  void _selectPendingItem({required String category, required String? itemId}) {
    final targetSection = _sectionForCategoryItem(
      category: category,
      itemId: itemId,
    );
    _activeCategory = category;
    _activeClothesSectionKey = targetSection?.key ?? _activeClothesSectionKey;
    final shouldToggleOffCurrentSelection =
        itemId != null &&
        widget.repository.supportsTapDeselectInWardrobe(category) &&
        widget.repository.pendingSelectionFor(category) == itemId;
    widget.repository.selectPendingItem(
      category,
      shouldToggleOffCurrentSelection ? null : itemId,
    );
    setState(() {});
    _notifyViewStateChanged();
  }

  _GallerySection _gallerySectionForIndex(int index) {
    if (index <= 0) {
      return _GallerySection.clothes;
    }
    if (index == 1) {
      return _GallerySection.poses;
    }
    return _GallerySection.favorites;
  }

  int _gallerySectionIndex(_GallerySection section) {
    switch (section) {
      case _GallerySection.clothes:
        return 0;
      case _GallerySection.poses:
        return 1;
      case _GallerySection.favorites:
        return 2;
    }
  }

  void _notifyViewStateChanged() {
    final callback = widget.onViewStateChanged;
    if (callback == null) {
      return;
    }
    final nextState = TopSheetGalleryViewState(
      activeSectionIndex: _gallerySectionIndex(_activeSection),
    );
    if (nextState == _lastReportedViewState) {
      return;
    }
    _lastReportedViewState = nextState;
    callback(nextState);
  }

  Future<void> _openEditClothingItem({
    required String category,
    required String itemId,
  }) async {
    final callback = widget.onEditClothingItem;
    if (callback == null || _isInteractionLocked) {
      return;
    }
    try {
      await callback(category: category, itemId: itemId);
      if (!mounted) {
        return;
      }
      setState(() {});
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to edit item: $error'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  Future<void> _openEditPose({required PoseGalleryItem item}) async {
    final callback = widget.onEditPose;
    if (callback == null || _isInteractionLocked) {
      return;
    }

    var draftName = item.label;
    try {
      final updatedName = await showDialog<String>(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: const Text('Edit Pose Name'),
            content: TextFormField(
              initialValue: item.label,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Front Pose',
              ),
              onChanged: (String value) {
                draftName = value;
              },
              onFieldSubmitted: (String value) {
                Navigator.of(dialogContext).pop(value.trim());
              },
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(draftName.trim()),
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
      final normalizedName = updatedName?.trim() ?? '';
      if (normalizedName.isEmpty) {
        return;
      }

      await callback(poseId: item.id, name: normalizedName);
      if (!mounted) {
        return;
      }
      setState(() {});
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to edit pose: $error'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  Future<void> _toggleClothingRegeneration({
    required String category,
    required GalleryItem item,
  }) async {
    final itemId = item.id;
    final callback = widget.onToggleClothingRegeneration;
    if (itemId == null || callback == null || _isInteractionLocked) {
      return;
    }

    final scope = await _showClothingRegenerationScopeSheet(
      category: category,
      itemId: itemId,
    );
    if (scope == null) {
      return;
    }

    try {
      await callback(category: category, itemId: itemId, scope: scope);
      if (!mounted) {
        return;
      }
      setState(() {});
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update regenerate queue: $error'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  bool _isClothingQueuedForRegeneration({
    required String category,
    required String itemId,
  }) {
    if (widget.repository.isItemQueuedForRegeneration(category, itemId)) {
      return true;
    }
    final poseId = widget.repository.activePoseId;
    if (poseId == null) {
      return false;
    }
    if (category == 'headwear' || category == 'shoes') {
      return widget.repository.isOverlayQueuedForRegeneration(
        poseId: poseId,
        category: category,
        itemId: itemId,
      );
    }
    return widget.repository.isPoseItemQueuedForRegeneration(
      poseId: poseId,
      category: category,
      itemId: itemId,
    );
  }

  Future<ClothingRegenerationScope?> _showClothingRegenerationScopeSheet({
    required String category,
    required String itemId,
  }) {
    final poseId = widget.repository.activePoseId;
    final isActivePoseQueued = poseId == null
        ? false
        : (category == 'headwear' || category == 'shoes')
        ? widget.repository.isOverlayQueuedForRegeneration(
            poseId: poseId,
            category: category,
            itemId: itemId,
          )
        : widget.repository.isPoseItemQueuedForRegeneration(
            poseId: poseId,
            category: category,
            itemId: itemId,
          );

    return showModalBottomSheet<ClothingRegenerationScope>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: Icon(
                  Icons.public_rounded,
                  color:
                      widget.repository.isItemQueuedForRegeneration(
                        category,
                        itemId,
                      )
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: const Text('All poses'),
                trailing:
                    widget.repository.isItemQueuedForRegeneration(
                      category,
                      itemId,
                    )
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.of(
                  context,
                ).pop(ClothingRegenerationScope.allPoses),
              ),
              ListTile(
                leading: Icon(
                  Icons.accessibility_new_rounded,
                  color: isActivePoseQueued
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: const Text('Active pose'),
                trailing: isActivePoseQueued
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: poseId == null
                    ? null
                    : () => Navigator.of(
                        context,
                      ).pop(ClothingRegenerationScope.activePose),
              ),
            ],
          ),
        );
      },
    );
  }

  void _handleVerticalSwipe(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (velocity < -_verticalSwipeVelocityThreshold) {
      Navigator.of(context).pop();
    }
  }

  void _handleManageDataAction(_ManageDataAction action) {
    if (_isInteractionLocked) {
      return;
    }

    final VoidCallback? callback = switch (action) {
      _ManageDataAction.importPack => widget.onImportPack,
      _ManageDataAction.exportPack => widget.onExportPack,
      _ManageDataAction.clearPack => widget.onClearPack,
    };
    if (callback == null) {
      return;
    }

    Navigator.of(context).pop();
    callback();
  }

  Future<void> _confirmDeleteClothingItem({
    required GalleryItem item,
    required String category,
  }) async {
    final itemId = item.id;
    final callback = widget.onDeleteClothingItem;
    if (itemId == null || callback == null || _isInteractionLocked) {
      return;
    }

    final confirmed = await _confirmDeleteDialog(
      title: 'Delete clothing item?',
      message:
          'Are you sure you want to delete "${item.label}" from "${_prettyCategory(category)}"?',
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _deleteBusy = true;
    });

    try {
      await callback(category: category, itemId: itemId);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Deleted "${item.label}".')));
      setState(() {});
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to delete "${item.label}": $error'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _deleteBusy = false;
        });
      }
    }
  }

  Future<void> _confirmDeletePose({required PoseGalleryItem item}) async {
    final callback = widget.onDeletePose;
    if (callback == null || _isInteractionLocked) {
      return;
    }

    final confirmed = await _confirmDeleteDialog(
      title: 'Delete pose?',
      message: 'Are you sure you want to delete "${item.label}"?',
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _deleteBusy = true;
    });

    try {
      await callback(poseId: item.id);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Deleted "${item.label}".')));
      setState(() {});
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to delete "${item.label}": $error'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _deleteBusy = false;
        });
      }
    }
  }

  Future<bool?> _confirmDeleteDialog({
    required String title,
    required String message,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black87,
                side: BorderSide(color: Colors.grey.shade300),
              ),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }
}

class _PoseGalleryCard extends StatelessWidget {
  const _PoseGalleryCard({
    required this.item,
    required this.onTap,
    this.onEdit,
    this.onDelete,
  });

  final PoseGalleryItem item;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final borderColor = item.isSelected
        ? Theme.of(context).colorScheme.primary
        : Colors.grey.shade300;

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: borderColor,
              width: item.isSelected ? 2 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        _thumb(item.thumbPath),
                        if (item.isPending)
                          Positioned.fill(
                            child: ColoredBox(
                              color: Colors.grey.withValues(alpha: 0.42),
                              child: const Center(
                                child: Text(
                                  'Pending',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (onEdit != null || onDelete != null)
                          Positioned(
                            top: 0,
                            left: 0,
                            child: Material(
                              color: Colors.black.withValues(alpha: 0.58),
                              shape: const CircleBorder(),
                              child: PopupMenuButton<_PoseCardMenuAction>(
                                tooltip: 'Pose actions',
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                constraints: const BoxConstraints(
                                  minWidth: 112,
                                ),
                                onSelected: (_PoseCardMenuAction action) {
                                  switch (action) {
                                    case _PoseCardMenuAction.edit:
                                      onEdit?.call();
                                      return;
                                    case _PoseCardMenuAction.delete:
                                      onDelete?.call();
                                      return;
                                  }
                                },
                                itemBuilder: (BuildContext menuContext) {
                                  final entries =
                                      <PopupMenuEntry<_PoseCardMenuAction>>[];
                                  if (onEdit != null) {
                                    entries.add(
                                      const PopupMenuItem<_PoseCardMenuAction>(
                                        value: _PoseCardMenuAction.edit,
                                        child: Row(
                                          children: <Widget>[
                                            Icon(Icons.edit_outlined, size: 18),
                                            SizedBox(width: 8),
                                            Text('Edit'),
                                          ],
                                        ),
                                      ),
                                    );
                                  }
                                  if (onDelete != null) {
                                    entries.add(
                                      PopupMenuItem<_PoseCardMenuAction>(
                                        value: _PoseCardMenuAction.delete,
                                        child: Row(
                                          children: <Widget>[
                                            Icon(
                                              Icons.delete_outline,
                                              size: 18,
                                              color: Theme.of(
                                                menuContext,
                                              ).colorScheme.error,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              'Delete',
                                              style: TextStyle(
                                                color: Theme.of(
                                                  menuContext,
                                                ).colorScheme.error,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }
                                  return entries;
                                },
                                child: const Padding(
                                  padding: EdgeInsets.all(3),
                                  child: Icon(
                                    Icons.info_outline,
                                    size: 16,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  item.label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumb(String? path) {
    if (path == null ||
        (path.isNotEmpty &&
            !path.startsWith('data:') &&
            !File(path).existsSync())) {
      return Container(
        color: Colors.grey.shade100,
        alignment: Alignment.center,
        child: const Icon(Icons.image_not_supported),
      );
    }

    if (path.startsWith('data:')) {
      return Image.network(
        path,
        fit: BoxFit.cover,
        errorBuilder:
            (BuildContext context, Object error, StackTrace? stackTrace) =>
                Container(
                  color: Colors.grey.shade100,
                  alignment: Alignment.center,
                  child: const Icon(Icons.error),
                ),
      );
    }

    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder:
          (BuildContext context, Object error, StackTrace? stackTrace) =>
              Container(
                color: Colors.grey.shade100,
                alignment: Alignment.center,
                child: const Icon(Icons.error),
              ),
    );
  }
}

class _FavoriteGalleryCard extends StatelessWidget {
  const _FavoriteGalleryCard({required this.item, required this.onTap});

  final FavoriteGalleryItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = item.isSelected
        ? Theme.of(context).colorScheme.primary
        : Colors.grey.shade300;

    return Opacity(
      opacity: item.isDisabled ? 0.74 : 1,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: borderColor,
                width: item.isSelected ? 2 : 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          _compositionPreview(item.composition),
                          if (item.isDisabled)
                            Positioned.fill(
                              child: ColoredBox(
                                color: Colors.black.withValues(alpha: 0.36),
                                child: const Center(
                                  child: Text(
                                    'Unavailable',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.62),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(
                                  Icons.star_rounded,
                                  size: 14,
                                  color: Color(0xFFFFD54F),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item.label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.subtitle,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _compositionPreview(OutfitComposition composition) {
    final basePath = composition.baseImagePath;
    if (!_hasUsableSource(basePath)) {
      return Container(
        color: Colors.grey.shade100,
        alignment: Alignment.center,
        child: const Icon(Icons.image_not_supported),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _imageLayer(basePath!),
        for (final overlay in composition.overlays)
          if (_hasUsableSource(overlay)) _imageLayer(overlay),
      ],
    );
  }

  Widget _imageLayer(String path) {
    if (path.startsWith('data:')) {
      return Image.network(
        path,
        fit: BoxFit.cover,
        errorBuilder:
            (BuildContext context, Object error, StackTrace? stackTrace) =>
                Container(
                  color: Colors.grey.shade100,
                  alignment: Alignment.center,
                  child: const Icon(Icons.error),
                ),
      );
    }

    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder:
          (BuildContext context, Object error, StackTrace? stackTrace) =>
              Container(
                color: Colors.grey.shade100,
                alignment: Alignment.center,
                child: const Icon(Icons.error),
              ),
    );
  }

  bool _hasUsableSource(String? path) {
    if (path == null || path.isEmpty) {
      return false;
    }
    if (path.startsWith('data:')) {
      return true;
    }
    return File(path).existsSync();
  }
}

class PantsIcon extends StatelessWidget {
  const PantsIcon({super.key, this.size});

  final double? size;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final resolvedSize = size ?? iconTheme.size ?? 24;
    final color = iconTheme.color ?? Colors.black;

    return CustomPaint(
      size: Size.square(resolvedSize),
      painter: _PantsIconPainter(color: color),
    );
  }
}

class _PantsIconPainter extends CustomPainter {
  const _PantsIconPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale, scale);

    final path = Path()
      ..moveTo(6, 3)
      ..lineTo(18, 3)
      ..lineTo(18, 6)
      ..lineTo(16.5, 21)
      ..lineTo(13.5, 21)
      ..lineTo(12, 12)
      ..lineTo(10.5, 21)
      ..lineTo(7.5, 21)
      ..lineTo(6, 6)
      ..close();

    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PantsIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _GalleryCard extends StatelessWidget {
  const _GalleryCard({
    required this.item,
    required this.onTap,
    this.onDelete,
    this.onEdit,
    this.onRegenerate,
    this.isQueuedForRegeneration = false,
  });

  final GalleryItem item;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;
  final VoidCallback? onRegenerate;
  final bool isQueuedForRegeneration;

  @override
  Widget build(BuildContext context) {
    final borderColor = item.isSelected
        ? Theme.of(context).colorScheme.primary
        : Colors.grey.shade300;

    final pendingOverlay = item.isPending
        ? Positioned.fill(
            child: ColoredBox(
              color: Colors.grey.withValues(alpha: 0.42),
              child: const Center(
                child: Text(
                  'Pending',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    final editAction =
        onEdit == null && onDelete == null && onRegenerate == null
        ? const SizedBox.shrink()
        : Positioned(
            top: 0,
            left: 0,
            child: PopupMenuButton<_ClothingCardMenuAction>(
              tooltip: 'Item actions',
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              constraints: const BoxConstraints(minWidth: 120),
              onSelected: (_ClothingCardMenuAction action) {
                switch (action) {
                  case _ClothingCardMenuAction.edit:
                    onEdit?.call();
                    return;
                  case _ClothingCardMenuAction.regenerate:
                    onRegenerate?.call();
                    return;
                  case _ClothingCardMenuAction.delete:
                    onDelete?.call();
                    return;
                }
              },
              itemBuilder: (BuildContext menuContext) {
                final entries = <PopupMenuEntry<_ClothingCardMenuAction>>[];
                if (onEdit != null) {
                  entries.add(
                    const PopupMenuItem<_ClothingCardMenuAction>(
                      value: _ClothingCardMenuAction.edit,
                      child: Row(
                        children: <Widget>[
                          Icon(Icons.edit_outlined, size: 18),
                          SizedBox(width: 8),
                          Text('Edit'),
                        ],
                      ),
                    ),
                  );
                }
                if (onRegenerate != null) {
                  entries.add(
                    PopupMenuItem<_ClothingCardMenuAction>(
                      value: _ClothingCardMenuAction.regenerate,
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.autorenew_rounded,
                            size: 18,
                            color: isQueuedForRegeneration
                                ? Theme.of(menuContext).colorScheme.primary
                                : null,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Regenerate…',
                            style: isQueuedForRegeneration
                                ? TextStyle(
                                    color: Theme.of(
                                      menuContext,
                                    ).colorScheme.primary,
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                  );
                }
                if (onDelete != null) {
                  entries.add(
                    PopupMenuItem<_ClothingCardMenuAction>(
                      value: _ClothingCardMenuAction.delete,
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: Theme.of(menuContext).colorScheme.error,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Delete',
                            style: TextStyle(
                              color: Theme.of(menuContext).colorScheme.error,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return entries;
              },
              child: const SizedBox(
                width: 36,
                height: 36,
                child: Center(
                  child: Material(
                    color: Color.fromRGBO(0, 0, 0, 0.58),
                    shape: CircleBorder(),
                    child: Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(
                        Icons.info_outline,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );

    final pinnedBadge = item.isPinned
        ? Positioned(
            left: 6,
            bottom: 6,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text(
                  'Pinned',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    return Semantics(
      label: item.label,
      button: true,
      enabled: onTap != null,
      child: Opacity(
        opacity: item.isDisabled ? 0.65 : 1,
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: borderColor,
                  width: item.isSelected ? 2 : 1,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            if (item.isNone)
                              Container(
                                color: Colors.grey.shade100,
                                alignment: Alignment.center,
                                child: const Icon(Icons.block),
                              )
                            else
                              _thumb(item.thumbPath),
                            pendingOverlay,
                            editAction,
                            pinnedBadge,
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumb(String? path) {
    if (path == null ||
        (path.isNotEmpty &&
            !path.startsWith('data:') &&
            !File(path).existsSync())) {
      return Container(
        color: Colors.grey.shade100,
        alignment: Alignment.center,
        child: const Icon(Icons.image_not_supported),
      );
    }

    if (path.startsWith('data:')) {
      return Image.network(
        path,
        fit: BoxFit.cover,
        errorBuilder:
            (BuildContext context, Object error, StackTrace? stackTrace) =>
                Container(
                  color: Colors.grey.shade100,
                  alignment: Alignment.center,
                  child: const Icon(Icons.error),
                ),
      );
    }

    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder:
          (BuildContext context, Object error, StackTrace? stackTrace) =>
              Container(
                color: Colors.grey.shade100,
                alignment: Alignment.center,
                child: const Icon(Icons.error),
              ),
    );
  }
}
