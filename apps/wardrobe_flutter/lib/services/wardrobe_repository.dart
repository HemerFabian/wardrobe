import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/favorite_outfit.dart';
import '../models/wardrobe.dart';

enum WardrobeGlobalFilterField { color, material, tags, style, pattern }

enum WardrobeCycleStatus { changed, blockedNoMatches, noop }

class WardrobeCycleResult {
  const WardrobeCycleResult({
    required this.status,
    this.reason,
    this.category,
    this.previousValue,
    this.nextValue,
  });

  const WardrobeCycleResult.changed({
    required String category,
    required String? previousValue,
    required String? nextValue,
  }) : this(
         status: WardrobeCycleStatus.changed,
         category: category,
         previousValue: previousValue,
         nextValue: nextValue,
       );

  const WardrobeCycleResult.blockedNoMatches({
    required String category,
    String? reason,
  }) : this(
         status: WardrobeCycleStatus.blockedNoMatches,
         category: category,
         reason: reason,
       );

  const WardrobeCycleResult.noop({String? reason, String? category})
    : this(
        status: WardrobeCycleStatus.noop,
        reason: reason,
        category: category,
      );

  final WardrobeCycleStatus status;
  final String? reason;
  final String? category;
  final String? previousValue;
  final String? nextValue;

  bool get changed => status == WardrobeCycleStatus.changed;
  bool get blockedNoMatches => status == WardrobeCycleStatus.blockedNoMatches;
}

class WardrobeFilterState {
  const WardrobeFilterState({
    this.globalColors = const <String>{},
    this.globalMaterials = const <String>{},
    this.globalTags = const <String>{},
    this.globalStyles = const <String>{},
    this.globalPatterns = const <String>{},
    this.localTypeFilters = const <String, Set<String>>{},
  });

  static const WardrobeFilterState empty = WardrobeFilterState();

  final Set<String> globalColors;
  final Set<String> globalMaterials;
  final Set<String> globalTags;
  final Set<String> globalStyles;
  final Set<String> globalPatterns;
  final Map<String, Set<String>> localTypeFilters;

  bool get hasAnyFilter {
    return globalColors.isNotEmpty ||
        globalMaterials.isNotEmpty ||
        globalTags.isNotEmpty ||
        globalStyles.isNotEmpty ||
        globalPatterns.isNotEmpty ||
        localTypeFilters.values.any((Set<String> values) => values.isNotEmpty);
  }

  int get activeValueCount {
    var total =
        globalColors.length +
        globalMaterials.length +
        globalTags.length +
        globalStyles.length +
        globalPatterns.length;
    for (final values in localTypeFilters.values) {
      total += values.length;
    }
    return total;
  }

  Set<String> valuesForGlobalField(WardrobeGlobalFilterField field) {
    return switch (field) {
      WardrobeGlobalFilterField.color => globalColors,
      WardrobeGlobalFilterField.material => globalMaterials,
      WardrobeGlobalFilterField.tags => globalTags,
      WardrobeGlobalFilterField.style => globalStyles,
      WardrobeGlobalFilterField.pattern => globalPatterns,
    };
  }

  WardrobeFilterState copyWith({
    Set<String>? globalColors,
    Set<String>? globalMaterials,
    Set<String>? globalTags,
    Set<String>? globalStyles,
    Set<String>? globalPatterns,
    Map<String, Set<String>>? localTypeFilters,
  }) {
    return WardrobeFilterState(
      globalColors: globalColors ?? this.globalColors,
      globalMaterials: globalMaterials ?? this.globalMaterials,
      globalTags: globalTags ?? this.globalTags,
      globalStyles: globalStyles ?? this.globalStyles,
      globalPatterns: globalPatterns ?? this.globalPatterns,
      localTypeFilters: localTypeFilters ?? this.localTypeFilters,
    );
  }
}

class WardrobeFilterFacets {
  const WardrobeFilterFacets({
    required this.colors,
    required this.materials,
    required this.tags,
    required this.styles,
    required this.patterns,
    required this.localTypesByCategory,
  });

  final List<String> colors;
  final List<String> materials;
  final List<String> tags;
  final List<String> styles;
  final List<String> patterns;
  final Map<String, List<String>> localTypesByCategory;
}

class WardrobeActiveFilterChip {
  const WardrobeActiveFilterChip({
    required this.key,
    required this.label,
    required this.value,
    required this.isLocalType,
    this.category,
    this.globalField,
  });

  final String key;
  final String label;
  final String value;
  final bool isLocalType;
  final String? category;
  final WardrobeGlobalFilterField? globalField;
}

class GalleryItem {
  const GalleryItem({
    required this.id,
    required this.label,
    required this.isNone,
    required this.thumbPath,
    required this.isSelected,
    required this.isDisabled,
    required this.isPending,
    this.isPinned = false,
  });

  final String? id;
  final String label;
  final bool isNone;
  final String? thumbPath;
  final bool isSelected;
  final bool isDisabled;
  final bool isPending;
  final bool isPinned;
}

class PoseGalleryItem {
  const PoseGalleryItem({
    required this.id,
    required this.label,
    required this.thumbPath,
    required this.isSelected,
    required this.isPending,
  });

  final String id;
  final String label;
  final String? thumbPath;
  final bool isSelected;
  final bool isPending;
}

class FavoriteGalleryItem {
  const FavoriteGalleryItem({
    required this.key,
    required this.label,
    required this.subtitle,
    required this.composition,
    required this.isSelected,
    required this.isDisabled,
  });

  final String key;
  final String label;
  final String subtitle;
  final OutfitComposition composition;
  final bool isSelected;
  final bool isDisabled;
}

class OutfitComposition {
  const OutfitComposition({
    required this.baseImagePath,
    required this.overlays,
  });

  final String? baseImagePath;
  final List<String> overlays;
}

class CurrentRenderRegenerationTarget {
  const CurrentRenderRegenerationTarget({
    required this.poseId,
    required this.topId,
    required this.bottomId,
  });

  final String poseId;
  final String topId;
  final String bottomId;

  String get key => 'render|$poseId|$topId|$bottomId';
}

class CurrentOverlayRegenerationTarget {
  const CurrentOverlayRegenerationTarget({
    required this.poseId,
    required this.category,
    required this.itemId,
  });

  final String poseId;
  final String category;
  final String itemId;

  String get key => 'overlay|$poseId|$category|$itemId';
}

class CurrentLookRegenerationBundle {
  const CurrentLookRegenerationBundle({
    required this.renderTarget,
    this.headwearTarget,
    this.shoesTarget,
  });

  final CurrentRenderRegenerationTarget renderTarget;
  final CurrentOverlayRegenerationTarget? headwearTarget;
  final CurrentOverlayRegenerationTarget? shoesTarget;
}

enum CurrentLookRegenerationState { none, partial, full }

enum ClothingRegenerationScope { allPoses, activePose }

enum CurrentLookRegenerationScope { look, render, headwear, shoes }

class CurrentLookScopeStatus {
  const CurrentLookScopeStatus({
    required this.scope,
    required this.label,
    required this.queued,
  });

  final CurrentLookRegenerationScope scope;
  final String label;
  final bool queued;
}

class CurrentOutfitState {
  const CurrentOutfitState({required this.poseId, required this.selection});

  final String poseId;
  final Map<String, String?> selection;
}

class ClothesNavSection {
  const ClothesNavSection({
    required this.key,
    required this.category,
    required this.categoryLabel,
    required this.subcategoryKey,
    required this.subcategoryLabel,
    required this.items,
    required this.isEmptyCategoryFallback,
  });

  final String key;
  final String category;
  final String categoryLabel;
  final String? subcategoryKey;
  final String subcategoryLabel;
  final List<GalleryItem> items;
  final bool isEmptyCategoryFallback;

  bool get hasExplicitSubcategory => subcategoryKey != null;

  bool get hasItems => items.isNotEmpty;

  String get displayLabel => hasExplicitSubcategory
      ? '$categoryLabel / $subcategoryLabel'
      : categoryLabel;
}

class ClothesRailNode {
  const ClothesRailNode({
    required this.category,
    required this.label,
    required this.hasItems,
    required this.subcategories,
  });

  final String category;
  final String label;
  final bool hasItems;
  final List<ClothesRailSubcategoryNode> subcategories;
}

class ClothesRailSubcategoryNode {
  const ClothesRailSubcategoryNode({
    required this.sectionKey,
    required this.label,
  });

  final String sectionKey;
  final String label;
}

class WardrobeClothesFocus {
  const WardrobeClothesFocus({
    required this.category,
    this.sectionKey,
    this.itemId,
  });

  final String category;
  final String? sectionKey;
  final String? itemId;

  WardrobeClothesFocus copyWith({
    String? category,
    String? sectionKey,
    String? itemId,
  }) {
    return WardrobeClothesFocus(
      category: category ?? this.category,
      sectionKey: sectionKey ?? this.sectionKey,
      itemId: itemId ?? this.itemId,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is WardrobeClothesFocus &&
        other.category == category &&
        other.sectionKey == sectionKey &&
        other.itemId == itemId;
  }

  @override
  int get hashCode => Object.hash(category, sectionKey, itemId);
}

class WardrobeRepository extends ChangeNotifier {
  static const String uncategorizedIntakeCategory = 'uncategorized';
  static const String uncategorizedIntakeLabel = 'Unknown';
  static const String _uncategorizedSubcategoryLabel = 'Other';
  static const Set<String> _wardrobeTapDeselectCategories = <String>{
    'headwear',
    'shoes',
  };

  WardrobeManifest? _manifest;
  Directory? _packRoot;
  Map<String, String> _assetPathOverrides = <String, String>{};
  String? _activePoseId;
  WardrobeClothesFocus? _clothesFocus;

  Map<String, String?> _committedSelection = <String, String?>{};
  Map<String, String?> _pendingSelection = <String, String?>{};
  Map<String, FavoriteOutfit> _favoritesByKey = <String, FavoriteOutfit>{};
  WardrobeFilterState _filterState = WardrobeFilterState.empty;

  WardrobeManifest? get manifest => _manifest;
  Directory? get packRoot => _packRoot;
  String? get activePoseId => _activePoseId;
  WardrobeClothesFocus? get clothesFocus => _clothesFocus;
  String? get activeCategory => _clothesFocus?.category;
  WardrobeFilterState get filterState => _filterState;
  bool get hasActiveFilters => _filterState.hasAnyFilter;

  bool get hasContentPack => _manifest != null && _packRoot != null;
  bool get hasFavorites => _favoritesByKey.isNotEmpty;
  bool supportsDirectDeselect(String category) =>
      _wardrobeTapDeselectCategories.contains(category);
  bool supportsTapDeselectInWardrobe(String category) =>
      supportsDirectDeselect(category);
  bool get hidesDefaultPackContent {
    final manifest = _manifest;
    if (manifest == null) {
      return false;
    }
    return _shouldHideDefaultPackContent(manifest);
  }

  bool get isClothingSwitchLocked {
    final activePose = _activePose;
    if (activePose == null) {
      return true;
    }
    return !activePose.renderReady;
  }

  bool get isActivePosePending {
    final activePose = _activePose;
    return activePose != null && !activePose.renderReady;
  }

  List<FavoriteOutfit> get favorites {
    final list = _favoritesByKey.values.toList(growable: false);
    list.sort(
      (FavoriteOutfit left, FavoriteOutfit right) =>
          right.createdAt.compareTo(left.createdAt),
    );
    return list;
  }

  List<String> get categories =>
      _manifest == null ? const <String>[] : _manifest!.orderedCategories;

  List<String> get clothesMainCategories {
    final manifest = _manifest;
    if (manifest == null) {
      return const <String>[];
    }

    final ordered = <String>[...WardrobeManifest.preferredCategoryOrder];
    for (final category in manifest.orderedCategories) {
      if (!ordered.contains(category)) {
        ordered.add(category);
      }
    }
    if (_visibleIntakeQueueForManifest(manifest).isNotEmpty &&
        !ordered.contains(uncategorizedIntakeCategory)) {
      ordered.add(uncategorizedIntakeCategory);
    }
    return ordered;
  }

  bool _shouldIncludeNoneGalleryItem(String category) {
    return category != 'top' &&
        category != 'bottom' &&
        !_wardrobeTapDeselectCategories.contains(category);
  }

  List<String> get availablePoses {
    final manifest = _manifest;
    if (manifest == null) {
      return const <String>[];
    }
    return _visiblePosesForManifest(
      manifest,
    ).map((WardrobePose pose) => pose.id).toList(growable: false);
  }

  bool get hasMultiplePoses => availablePoses.length > 1;

  WardrobeFilterFacets filterFacets() {
    final manifest = _manifest;
    if (manifest == null) {
      return const WardrobeFilterFacets(
        colors: <String>[],
        materials: <String>[],
        tags: <String>[],
        styles: <String>[],
        patterns: <String>[],
        localTypesByCategory: <String, List<String>>{},
      );
    }

    final colorValues = <String>{};
    final materialValues = <String>{};
    final tagValues = <String>{};
    final styleValues = <String>{};
    final patternValues = <String>{};
    final localTypes = <String, Set<String>>{};
    final localTypeCategories = clothesMainCategories
        .where(_isLocalTypeFilterCategory)
        .toList(growable: false);

    for (final category in localTypeCategories) {
      for (final item in _visibleItemsForCategory(
        manifest: manifest,
        category: category,
      )) {
        _addFacetValue(colorValues, item.colorPrimary);
        _addFacetValue(materialValues, item.material);
        _addFacetValue(styleValues, item.styleOccasion);
        _addFacetValue(patternValues, item.patternDesign);
        for (final tag in item.tags) {
          _addFacetValue(tagValues, tag);
        }

        final normalizedType = _normalizedFacetValue(item.subcategory);
        if (normalizedType == null) {
          continue;
        }
        localTypes.putIfAbsent(category, () => <String>{}).add(normalizedType);
      }
    }

    return WardrobeFilterFacets(
      colors: _sortedValues(colorValues),
      materials: _sortedValues(materialValues),
      tags: _sortedValues(tagValues),
      styles: _sortedValues(styleValues),
      patterns: _sortedValues(patternValues),
      localTypesByCategory: <String, List<String>>{
        for (final category in localTypeCategories)
          category: _sortedValues(localTypes[category] ?? const <String>{}),
      },
    );
  }

  List<WardrobeActiveFilterChip> activeFilterChips() {
    final chips = <WardrobeActiveFilterChip>[];

    void addGlobal(
      WardrobeGlobalFilterField field,
      String label,
      Set<String> values,
    ) {
      for (final value in _sortedValues(values)) {
        chips.add(
          WardrobeActiveFilterChip(
            key: 'global:${field.name}:$value',
            label: label,
            value: value,
            isLocalType: false,
            globalField: field,
          ),
        );
      }
    }

    addGlobal(
      WardrobeGlobalFilterField.color,
      'Color',
      _filterState.globalColors,
    );
    addGlobal(
      WardrobeGlobalFilterField.material,
      'Material',
      _filterState.globalMaterials,
    );
    addGlobal(WardrobeGlobalFilterField.tags, 'Tag', _filterState.globalTags);
    addGlobal(
      WardrobeGlobalFilterField.style,
      'Style',
      _filterState.globalStyles,
    );
    addGlobal(
      WardrobeGlobalFilterField.pattern,
      'Pattern',
      _filterState.globalPatterns,
    );

    final localEntries = _filterState.localTypeFilters.entries.toList(
      growable: true,
    )..sort((left, right) => left.key.compareTo(right.key));
    for (final entry in localEntries) {
      if (!_isLocalTypeFilterCategory(entry.key)) {
        continue;
      }
      final categoryLabel = _prettyCategory(entry.key);
      for (final value in _sortedValues(entry.value)) {
        chips.add(
          WardrobeActiveFilterChip(
            key: 'local:${entry.key}:$value',
            label: '$categoryLabel Type',
            value: value,
            isLocalType: true,
            category: entry.key,
          ),
        );
      }
    }

    return chips;
  }

  int filteredMatchCountForCategory(String category) {
    final manifest = _manifest;
    if (manifest == null) {
      return 0;
    }
    if (category == uncategorizedIntakeCategory) {
      return itemsForCategory(
        category,
      ).where((GalleryItem item) => !item.isNone).length;
    }
    return _visibleItemsForCategory(manifest: manifest, category: category)
        .where((WardrobeItem item) => item.renderReady && _matchesFilters(item))
        .length;
  }

  void toggleGlobalFilterValue(WardrobeGlobalFilterField field, String value) {
    final normalized = _normalizedFacetValue(value);
    if (normalized == null) {
      return;
    }
    final current = Set<String>.from(_filterState.valuesForGlobalField(field));
    if (!current.add(normalized)) {
      current.remove(normalized);
    }
    _filterState = switch (field) {
      WardrobeGlobalFilterField.color => _filterState.copyWith(
        globalColors: Set<String>.unmodifiable(current),
      ),
      WardrobeGlobalFilterField.material => _filterState.copyWith(
        globalMaterials: Set<String>.unmodifiable(current),
      ),
      WardrobeGlobalFilterField.tags => _filterState.copyWith(
        globalTags: Set<String>.unmodifiable(current),
      ),
      WardrobeGlobalFilterField.style => _filterState.copyWith(
        globalStyles: Set<String>.unmodifiable(current),
      ),
      WardrobeGlobalFilterField.pattern => _filterState.copyWith(
        globalPatterns: Set<String>.unmodifiable(current),
      ),
    };
    _syncClothesFocusForCurrentState();
    notifyListeners();
  }

  void toggleLocalTypeFilter(String category, String value) {
    final normalizedCategory = category.trim();
    final normalizedValue = _normalizedFacetValue(value);
    if (normalizedValue == null ||
        !_isLocalTypeFilterCategory(normalizedCategory)) {
      return;
    }
    final next = <String, Set<String>>{
      for (final entry in _filterState.localTypeFilters.entries)
        entry.key: Set<String>.from(entry.value),
    };
    final values = next.putIfAbsent(normalizedCategory, () => <String>{});
    if (!values.add(normalizedValue)) {
      values.remove(normalizedValue);
    }
    if (values.isEmpty) {
      next.remove(normalizedCategory);
    }

    _filterState = _filterState.copyWith(
      localTypeFilters: <String, Set<String>>{
        for (final entry in next.entries)
          entry.key: Set<String>.unmodifiable(entry.value),
      },
    );
    _syncClothesFocusForCurrentState();
    notifyListeners();
  }

  void clearAllFilters() {
    if (!_filterState.hasAnyFilter) {
      return;
    }
    _filterState = WardrobeFilterState.empty;
    _syncClothesFocusForCurrentState();
    notifyListeners();
  }

  void clearFilterField(WardrobeGlobalFilterField field) {
    final values = _filterState.valuesForGlobalField(field);
    if (values.isEmpty) {
      return;
    }
    _filterState = switch (field) {
      WardrobeGlobalFilterField.color => _filterState.copyWith(
        globalColors: const <String>{},
      ),
      WardrobeGlobalFilterField.material => _filterState.copyWith(
        globalMaterials: const <String>{},
      ),
      WardrobeGlobalFilterField.tags => _filterState.copyWith(
        globalTags: const <String>{},
      ),
      WardrobeGlobalFilterField.style => _filterState.copyWith(
        globalStyles: const <String>{},
      ),
      WardrobeGlobalFilterField.pattern => _filterState.copyWith(
        globalPatterns: const <String>{},
      ),
    };
    _syncClothesFocusForCurrentState();
    notifyListeners();
  }

  void clearLocalTypeFilter(String category) {
    final normalizedCategory = category.trim();
    if (!_isLocalTypeFilterCategory(normalizedCategory) ||
        !_filterState.localTypeFilters.containsKey(normalizedCategory)) {
      return;
    }
    final next = <String, Set<String>>{
      for (final entry in _filterState.localTypeFilters.entries)
        if (entry.key != normalizedCategory)
          entry.key: Set<String>.from(entry.value),
    };
    _filterState = _filterState.copyWith(
      localTypeFilters: <String, Set<String>>{
        for (final entry in next.entries)
          entry.key: Set<String>.unmodifiable(entry.value),
      },
    );
    _syncClothesFocusForCurrentState();
    notifyListeners();
  }

  bool isGlobalFilterValueSelected(
    WardrobeGlobalFilterField field,
    String value,
  ) {
    final normalized = _normalizedFacetValue(value);
    if (normalized == null) {
      return false;
    }
    return _filterState.valuesForGlobalField(field).contains(normalized);
  }

  bool isLocalTypeFilterSelected(String category, String value) {
    final normalized = _normalizedFacetValue(value);
    final normalizedCategory = category.trim();
    if (normalized == null || !_isLocalTypeFilterCategory(normalizedCategory)) {
      return false;
    }
    return _filterState.localTypeFilters[normalizedCategory]?.contains(
          normalized,
        ) ??
        false;
  }

  List<ClothesNavSection> clothesSections() {
    final manifest = _manifest;
    if (manifest == null) {
      return const <ClothesNavSection>[];
    }

    final sections = <ClothesNavSection>[];
    for (final category in clothesMainCategories) {
      if (category == uncategorizedIntakeCategory) {
        final items = itemsForCategory(category);
        sections.add(
          ClothesNavSection(
            key: _sectionKeyFor(category: category, subcategoryKey: null),
            category: category,
            categoryLabel: _prettyCategory(category),
            subcategoryKey: null,
            subcategoryLabel: uncategorizedIntakeLabel,
            items: items,
            isEmptyCategoryFallback: items.isEmpty,
          ),
        );
        continue;
      }

      final categoryItems = itemsForCategory(category)
          .where((GalleryItem item) {
            return !item.isNone;
          })
          .toList(growable: false);
      final grouped = <String, List<GalleryItem>>{};
      final labels = <String, String>{};

      for (final item in categoryItems) {
        final subcategory = _subcategoryForItem(
          category: category,
          itemId: item.id,
        );
        final normalizedKey = _normalizeSubcategoryKey(subcategory);
        final bucketKey = normalizedKey ?? '';
        grouped.putIfAbsent(bucketKey, () => <GalleryItem>[]).add(item);
        labels[bucketKey] = _displaySubcategoryLabel(subcategory);
      }

      if (_shouldIncludeNoneGalleryItem(category)) {
        grouped.putIfAbsent('', () => <GalleryItem>[]);
        labels[''] = _uncategorizedSubcategoryLabel;
        grouped['']!.insert(
          0,
          GalleryItem(
            id: null,
            label: 'None',
            isNone: true,
            thumbPath: null,
            isSelected: _pendingSelection[category] == null,
            isDisabled: false,
            isPending: false,
          ),
        );
      }

      if (grouped.isEmpty) {
        grouped[''] = <GalleryItem>[];
        labels[''] = _uncategorizedSubcategoryLabel;
      }

      final orderedGroupKeys = grouped.keys.toList(growable: true)
        ..sort((String left, String right) {
          if (left.isEmpty && right.isNotEmpty) {
            return -1;
          }
          if (right.isEmpty && left.isNotEmpty) {
            return 1;
          }
          return (labels[left] ?? left).compareTo(labels[right] ?? right);
        });

      for (final groupKey in orderedGroupKeys) {
        final subcategoryKey = groupKey.isEmpty ? null : groupKey;
        final items = grouped[groupKey] ?? const <GalleryItem>[];
        final label = labels[groupKey] ?? _uncategorizedSubcategoryLabel;
        sections.add(
          ClothesNavSection(
            key: _sectionKeyFor(
              category: category,
              subcategoryKey: subcategoryKey,
            ),
            category: category,
            categoryLabel: _prettyCategory(category),
            subcategoryKey: subcategoryKey,
            subcategoryLabel: label,
            items: items,
            isEmptyCategoryFallback: items.isEmpty,
          ),
        );
      }
    }

    return sections;
  }

  List<ClothesRailNode> clothesRailNodes({List<ClothesNavSection>? sections}) {
    final resolvedSections = sections ?? clothesSections();
    final byCategory = <String, List<ClothesNavSection>>{};
    for (final section in resolvedSections) {
      byCategory
          .putIfAbsent(section.category, () => <ClothesNavSection>[])
          .add(section);
    }

    final nodes = <ClothesRailNode>[];
    for (final category in clothesMainCategories) {
      final categorySections =
          byCategory[category] ?? const <ClothesNavSection>[];
      final subcategories = categorySections
          .where((ClothesNavSection section) {
            return section.hasExplicitSubcategory && section.hasItems;
          })
          .map(
            (ClothesNavSection section) => ClothesRailSubcategoryNode(
              sectionKey: section.key,
              label: section.subcategoryLabel,
            ),
          )
          .toList(growable: false);
      final hasItems = categorySections.any((ClothesNavSection section) {
        return section.items.any((GalleryItem item) => !item.isNone);
      });

      nodes.add(
        ClothesRailNode(
          category: category,
          label: _prettyCategory(category),
          hasItems: hasItems,
          subcategories: subcategories,
        ),
      );
    }

    return nodes;
  }

  String? firstSectionKeyForCategory(String category) {
    for (final section in clothesSections()) {
      if (section.category == category) {
        return section.key;
      }
    }
    return null;
  }

  String? sectionKeyForCategoryItem({
    required String category,
    required String? itemId,
  }) {
    final sections = clothesSections();
    return _sectionForCategoryItem(
      sections: sections,
      category: category,
      itemId: itemId,
    )?.key;
  }

  void _setClothesFocusForCategoryItem({
    required String category,
    required String? itemId,
    required bool notify,
  }) {
    setClothesFocus(
      category: category,
      sectionKey:
          sectionKeyForCategoryItem(category: category, itemId: itemId) ??
          firstSectionKeyForCategory(category),
      itemId: itemId,
      notify: notify,
    );
  }

  void _syncClothesFocusForCurrentState() {
    _clothesFocus = _normalizedClothesFocusForCurrentState(_clothesFocus);
  }

  WardrobeClothesFocus? _normalizedClothesFocusForCurrentState(
    WardrobeClothesFocus? focus,
  ) {
    final sections = clothesSections();
    if (sections.isEmpty) {
      return null;
    }

    ClothesNavSection? resolvedSection;
    String? resolvedItemId;

    if (focus != null) {
      if (focus.itemId != null) {
        resolvedSection = _sectionForCategoryItem(
          sections: sections,
          category: focus.category,
          itemId: focus.itemId,
        );
        if (resolvedSection != null &&
            resolvedSection.items.any(
              (GalleryItem item) => item.id == focus.itemId,
            )) {
          resolvedItemId = focus.itemId;
        }
      }

      resolvedSection ??= sections
          .where((ClothesNavSection section) => section.key == focus.sectionKey)
          .firstOrNull;
      resolvedSection ??= sections
          .where(
            (ClothesNavSection section) => section.category == focus.category,
          )
          .firstOrNull;
    }

    resolvedSection ??= sections.first;

    return WardrobeClothesFocus(
      category: resolvedSection.category,
      sectionKey: resolvedSection.key,
      itemId: resolvedItemId,
    );
  }

  ClothesNavSection? _sectionForCategoryItem({
    required List<ClothesNavSection> sections,
    required String category,
    required String? itemId,
  }) {
    final firstSection = sections
        .where((ClothesNavSection section) => section.category == category)
        .firstOrNull;
    if (itemId == null) {
      return firstSection;
    }
    for (final section in sections) {
      if (section.category != category) {
        continue;
      }
      if (section.items.any((GalleryItem item) => item.id == itemId)) {
        return section;
      }
    }
    return firstSection;
  }

  void setClothesFocus({
    required String category,
    String? sectionKey,
    String? itemId,
    bool notify = true,
  }) {
    final nextFocus = _normalizedClothesFocusForCurrentState(
      WardrobeClothesFocus(
        category: category,
        sectionKey: sectionKey,
        itemId: itemId,
      ),
    );
    if (_clothesFocus == nextFocus) {
      return;
    }
    _clothesFocus = nextFocus;
    if (notify) {
      notifyListeners();
    }
  }

  void setContentPack({
    required WardrobeManifest manifest,
    required Directory packRoot,
    Map<String, String>? assetPathOverrides,
    bool preserveCurrentState = false,
  }) {
    final previousState = preserveCurrentState ? currentOutfitState() : null;
    _manifest = manifest;
    _packRoot = packRoot;
    _assetPathOverrides = assetPathOverrides ?? <String, String>{};
    final visiblePoses = _visiblePosesForManifest(manifest);
    if (previousState != null &&
        visiblePoses.any((pose) => pose.id == previousState.poseId)) {
      _activePoseId = previousState.poseId;
    } else if (visiblePoses.isNotEmpty) {
      _activePoseId = visiblePoses.first.id;
    } else {
      _activePoseId = _shouldHideDefaultPackContent(manifest)
          ? null
          : manifest.defaultPoseId;
    }
    _committedSelection = previousState == null
        ? _defaultSelectionForManifest(manifest)
        : _normalizeSelectionForManifest(manifest, previousState.selection);
    _pendingSelection = Map<String, String?>.from(_committedSelection);
    _clothesFocus = _normalizedClothesFocusForCurrentState(null);
    _favoritesByKey = <String, FavoriteOutfit>{};
    _filterState = WardrobeFilterState.empty;
    notifyListeners();
  }

  void clearContentPack() {
    _manifest = null;
    _packRoot = null;
    _assetPathOverrides = <String, String>{};
    _activePoseId = null;
    _clothesFocus = null;
    _committedSelection = <String, String?>{};
    _pendingSelection = <String, String?>{};
    _favoritesByKey = <String, FavoriteOutfit>{};
    _filterState = WardrobeFilterState.empty;
    notifyListeners();
  }

  void setFavorites(Iterable<FavoriteOutfit> favorites) {
    final manifest = _manifest;
    if (manifest == null) {
      _favoritesByKey = <String, FavoriteOutfit>{};
      notifyListeners();
      return;
    }

    final normalizedFavorites = <String, FavoriteOutfit>{};
    for (final favorite in favorites) {
      final selection = FavoriteOutfit.normalizeSelection(
        selection: favorite.selection,
        categories: manifest.orderedCategories,
      );
      final key = FavoriteOutfit.buildKey(
        selection: selection,
        categories: manifest.orderedCategories,
      );
      final normalized = favorite.copyWith(key: key, selection: selection);
      final existing = normalizedFavorites[key];
      if (existing == null ||
          normalized.createdAt.isAfter(existing.createdAt)) {
        normalizedFavorites[key] = normalized;
      }
    }

    _favoritesByKey = normalizedFavorites;
    notifyListeners();
  }

  bool hasFavoriteKey(String key) => _favoritesByKey.containsKey(key);

  FavoriteOutfit? currentFavoriteDraft() {
    final manifest = _manifest;
    if (manifest == null) {
      return null;
    }

    final normalizedSelection = FavoriteOutfit.normalizeSelection(
      selection: _committedSelection,
      categories: manifest.orderedCategories,
    );
    final key = FavoriteOutfit.buildKey(
      selection: normalizedSelection,
      categories: manifest.orderedCategories,
    );

    return FavoriteOutfit(
      key: key,
      selection: normalizedSelection,
      createdAt: DateTime.now().toUtc(),
    );
  }

  bool get isCurrentOutfitFavorited {
    final current = currentFavoriteDraft();
    if (current == null) {
      return false;
    }
    return _favoritesByKey.containsKey(current.key);
  }

  List<FavoriteGalleryItem> favoriteItems() {
    final manifest = _manifest;
    final packRoot = _packRoot;
    if (manifest == null || packRoot == null) {
      return const <FavoriteGalleryItem>[];
    }

    final visiblePoseIds = availablePoses.toSet();
    final activePoseId = _activePoseId;
    final previewPoseId =
        activePoseId != null && visiblePoseIds.contains(activePoseId)
        ? activePoseId
        : (availablePoses.firstOrNull ?? manifest.defaultPoseId);
    final normalizedPending = FavoriteOutfit.normalizeSelection(
      selection: _pendingSelection,
      categories: manifest.orderedCategories,
    );

    return favorites
        .map((FavoriteOutfit favorite) {
          final selected = _selectionEquals(
            left: normalizedPending,
            right: FavoriteOutfit.normalizeSelection(
              selection: favorite.selection,
              categories: manifest.orderedCategories,
            ),
            categories: manifest.orderedCategories,
          );
          final selection = _normalizeSelectionForManifest(
            manifest,
            favorite.selection,
          );

          final composition =
              previewPoseId != null && visiblePoseIds.contains(previewPoseId)
              ? _compositionForSelection(
                  manifest: manifest,
                  packRoot: packRoot,
                  poseId: previewPoseId,
                  selection: selection,
                )
              : const OutfitComposition(
                  baseImagePath: null,
                  overlays: <String>[],
                );
          final topLabel = _itemLabel(
            manifest: manifest,
            category: 'top',
            itemId: selection['top'],
          );
          final bottomLabel = _itemLabel(
            manifest: manifest,
            category: 'bottom',
            itemId: selection['bottom'],
          );

          return FavoriteGalleryItem(
            key: favorite.key,
            label: '$topLabel + $bottomLabel',
            subtitle: previewPoseId == null
                ? 'No pose available'
                : _poseLabel(manifest, previewPoseId),
            composition: composition,
            isSelected: selected,
            isDisabled: composition.baseImagePath == null,
          );
        })
        .toList(growable: false);
  }

  void selectPendingFavorite(String favoriteKey) {
    final manifest = _manifest;
    final favorite = _favoritesByKey[favoriteKey];
    if (manifest == null || favorite == null) {
      return;
    }

    _pendingSelection = _normalizeSelectionForManifest(
      manifest,
      favorite.selection,
    );
    _syncClothesFocusForCurrentState();
    notifyListeners();
  }

  void beginPendingSelection() {
    _pendingSelection = Map<String, String?>.from(_committedSelection);
    _syncClothesFocusForCurrentState();
  }

  void discardPendingSelection() {
    _pendingSelection = Map<String, String?>.from(_committedSelection);
    _syncClothesFocusForCurrentState();
  }

  void applyPendingSelection() {
    _committedSelection = Map<String, String?>.from(_pendingSelection);
    _syncClothesFocusForCurrentState();
    notifyListeners();
  }

  void selectCategory(String category) {
    if (!clothesMainCategories.contains(category)) {
      return;
    }
    setClothesFocus(
      category: category,
      sectionKey: firstSectionKeyForCategory(category),
    );
  }

  String? committedSelectionFor(String category) =>
      _committedSelection[category];

  String? pendingSelectionFor(String category) => _pendingSelection[category];

  List<GalleryItem> itemsForCategory(String category) {
    final manifest = _manifest;
    if (manifest == null) {
      return const <GalleryItem>[];
    }

    if (category == uncategorizedIntakeCategory) {
      return _visibleIntakeQueueForManifest(manifest)
          .map((WardrobePendingIntakeItem item) {
            return GalleryItem(
              id: item.id,
              label: _displayItemLabel(item.id),
              isNone: false,
              thumbPath: _absolutePendingThumbPath(item),
              isSelected: false,
              isDisabled: true,
              isPending: true,
              isPinned: false,
            );
          })
          .toList(growable: false);
    }

    final selectedItemId = _pendingSelection[category];
    final galleryItems = <GalleryItem>[];

    if (_shouldIncludeNoneGalleryItem(category)) {
      galleryItems.add(
        GalleryItem(
          id: null,
          label: 'None',
          isNone: true,
          thumbPath: null,
          isSelected: selectedItemId == null,
          isDisabled: false,
          isPending: false,
          isPinned: false,
        ),
      );
    }

    final allItems = _visibleItemsForCategory(
      manifest: manifest,
      category: category,
    );
    final indexedItems = allItems.asMap().entries.toList(growable: false)
      ..sort((
        MapEntry<int, WardrobeItem> left,
        MapEntry<int, WardrobeItem> right,
      ) {
        if (left.value.renderReady == right.value.renderReady) {
          return left.key.compareTo(right.key);
        }
        return left.value.renderReady ? -1 : 1;
      });

    final selectedItem = allItems
        .where((WardrobeItem item) => item.id == selectedItemId)
        .firstOrNull;
    final filteredIds = <String>{};

    for (final entry in indexedItems) {
      final item = entry.value;
      if (!_matchesFilters(item)) {
        continue;
      }
      final disabled = !item.renderReady;
      filteredIds.add(item.id);
      galleryItems.add(
        GalleryItem(
          id: item.id,
          label: _displayItemLabelForItem(item),
          isNone: false,
          thumbPath: _absoluteThumbPath(category: category, itemId: item.id),
          isSelected: selectedItemId == item.id,
          isDisabled: disabled,
          isPending: disabled,
          isPinned: false,
        ),
      );
    }

    if (selectedItem != null &&
        !filteredIds.contains(selectedItem.id) &&
        selectedItem.id.isNotEmpty) {
      final disabled = !selectedItem.renderReady;
      galleryItems.add(
        GalleryItem(
          id: selectedItem.id,
          label: _displayItemLabelForItem(selectedItem),
          isNone: false,
          thumbPath: _absoluteThumbPath(
            category: category,
            itemId: selectedItem.id,
          ),
          isSelected: true,
          isDisabled: disabled,
          isPending: disabled,
          isPinned: true,
        ),
      );
    }

    return galleryItems;
  }

  List<PoseGalleryItem> poseItems() {
    final manifest = _manifest;
    final packRoot = _packRoot;
    if (manifest == null) {
      return const <PoseGalleryItem>[];
    }

    return _visiblePosesForManifest(manifest)
        .map((WardrobePose pose) {
          final previewRelativePath =
              _firstNonEmpty(pose.thumbPath, pose.path) ??
              _fallbackRenderPathForPose(manifest, pose.id);
          return PoseGalleryItem(
            id: pose.id,
            label: pose.name,
            thumbPath:
                previewRelativePath == null ||
                    previewRelativePath.isEmpty ||
                    packRoot == null
                ? null
                : _absolutePath(packRoot, previewRelativePath),
            isSelected: pose.id == _activePoseId,
            isPending: !pose.renderReady,
          );
        })
        .toList(growable: false);
  }

  String? _fallbackRenderPathForPose(WardrobeManifest manifest, String poseId) {
    final preferredRender = manifest.findRender(
      poseId: poseId,
      topId: _pendingSelection['top'] ?? _committedSelection['top'],
      bottomId: _pendingSelection['bottom'] ?? _committedSelection['bottom'],
    );
    if (preferredRender != null && preferredRender.path.isNotEmpty) {
      return preferredRender.path;
    }

    final firstPoseRender = manifest.renders
        .where((WardrobeRender render) => render.poseId == poseId)
        .firstOrNull;
    if (firstPoseRender != null && firstPoseRender.path.isNotEmpty) {
      return firstPoseRender.path;
    }
    return null;
  }

  String? _firstNonEmpty(String? first, String? second) {
    if (first != null && first.isNotEmpty) {
      return first;
    }
    if (second != null && second.isNotEmpty) {
      return second;
    }
    return null;
  }

  WardrobeItem? itemForCategory(String category, String itemId) {
    final manifest = _manifest;
    if (manifest == null || itemId.trim().isEmpty) {
      return null;
    }
    return _visibleItemsForCategory(
      manifest: manifest,
      category: category,
    ).where((WardrobeItem item) => item.id == itemId).firstOrNull;
  }

  bool restorePendingSelectionForCategory(String category, String? itemId) {
    return _setSelectionValue(
      selection: _pendingSelection,
      category: category,
      itemId: itemId,
      requireRenderable: true,
      trackInteraction: false,
      notify: true,
    );
  }

  bool restoreCommittedSelectionForCategory(String category, String? itemId) {
    final changedCommitted = _setSelectionValue(
      selection: _committedSelection,
      category: category,
      itemId: itemId,
      requireRenderable: true,
      trackInteraction: false,
      notify: false,
    );
    final changedPending = _setSelectionValue(
      selection: _pendingSelection,
      category: category,
      itemId: itemId,
      requireRenderable: true,
      trackInteraction: false,
      notify: false,
    );
    if (changedCommitted || changedPending) {
      _syncClothesFocusForCurrentState();
      notifyListeners();
      return true;
    }
    return false;
  }

  bool clearCategorySelection(String category) {
    if (!supportsDirectDeselect(category)) {
      return false;
    }

    final changedCommitted = _setSelectionValue(
      selection: _committedSelection,
      category: category,
      itemId: null,
      requireRenderable: true,
      trackInteraction: false,
      notify: false,
    );
    final changedPending = _setSelectionValue(
      selection: _pendingSelection,
      category: category,
      itemId: null,
      requireRenderable: true,
      trackInteraction: false,
      notify: false,
    );
    if (changedCommitted || changedPending) {
      _setClothesFocusForCategoryItem(
        category: category,
        itemId: null,
        notify: false,
      );
      notifyListeners();
      return true;
    }
    return false;
  }

  void selectPendingItem(String category, String? itemId) {
    _setSelectionValue(
      selection: _pendingSelection,
      category: category,
      itemId: itemId,
      requireRenderable: true,
      trackInteraction: true,
      notify: true,
    );
  }

  void cyclePendingCategory(String category, int direction) {
    cyclePendingCategoryFiltered(category, direction);
  }

  void cycleCategory(String category, int direction) {
    cycleCategoryFiltered(category, direction);
  }

  WardrobeCycleResult cyclePendingCategoryFiltered(
    String category,
    int direction,
  ) {
    return _cycleSelectionCategory(
      category: category,
      direction: direction,
      selection: _pendingSelection,
      mirrorSelection: null,
      applyFilters: true,
    );
  }

  WardrobeCycleResult cycleCategoryFiltered(String category, int direction) {
    return _cycleSelectionCategory(
      category: category,
      direction: direction,
      selection: _committedSelection,
      mirrorSelection: _pendingSelection,
      applyFilters: true,
    );
  }

  WardrobeCycleResult _cycleSelectionCategory({
    required String category,
    required int direction,
    required Map<String, String?> selection,
    required Map<String, String?>? mirrorSelection,
    required bool applyFilters,
  }) {
    final manifest = _manifest;
    if (manifest == null) {
      return const WardrobeCycleResult.noop(reason: 'No manifest loaded.');
    }

    final cycleValues = _cycleValuesForCategory(
      category: category,
      applyFilters: applyFilters,
    );
    if (cycleValues.isEmpty) {
      if (applyFilters && hasActiveFilters) {
        return WardrobeCycleResult.blockedNoMatches(
          category: category,
          reason: 'No items match active filters.',
        );
      }
      return const WardrobeCycleResult.noop(reason: 'No available values.');
    }

    final current = selection[category];
    var index = cycleValues.indexOf(current);
    if (index < 0) {
      index = 0;
    }

    final normalizedDirection = direction >= 0 ? 1 : -1;
    final nextIndex = (index + normalizedDirection) % cycleValues.length;
    final wrappedIndex = nextIndex < 0
        ? nextIndex + cycleValues.length
        : nextIndex;

    final nextValue = cycleValues[wrappedIndex];
    if (nextValue == current) {
      return WardrobeCycleResult.noop(
        category: category,
        reason: 'Selection unchanged.',
      );
    }
    selection[category] = nextValue;
    if (mirrorSelection != null) {
      mirrorSelection[category] = nextValue;
    }
    _setClothesFocusForCategoryItem(
      category: category,
      itemId: nextValue,
      notify: false,
    );
    notifyListeners();
    return WardrobeCycleResult.changed(
      category: category,
      previousValue: current,
      nextValue: nextValue,
    );
  }

  bool _setSelectionValue({
    required Map<String, String?> selection,
    required String category,
    required String? itemId,
    required bool requireRenderable,
    required bool trackInteraction,
    required bool notify,
  }) {
    final manifest = _manifest;
    if (manifest == null || category == uncategorizedIntakeCategory) {
      return false;
    }

    final validItems = _visibleItemsForCategory(
      manifest: manifest,
      category: category,
    );
    final validIds = validItems.map((WardrobeItem item) => item.id).toSet();
    if (itemId != null && !validIds.contains(itemId)) {
      return false;
    }

    final selectedItem = validItems
        .where((WardrobeItem item) => item.id == itemId)
        .firstOrNull;
    if (requireRenderable &&
        selectedItem != null &&
        !selectedItem.renderReady) {
      return false;
    }

    if (selection[category] == itemId) {
      return false;
    }
    selection[category] = itemId;
    if (trackInteraction) {
      _setClothesFocusForCategoryItem(
        category: category,
        itemId: itemId,
        notify: false,
      );
    }
    if (notify) {
      notifyListeners();
    }
    return true;
  }

  void selectPose(String poseId) {
    final manifest = _manifest;
    if (manifest == null || !availablePoses.contains(poseId)) {
      return;
    }

    final preservedSelection = _normalizeSelectionForManifest(
      manifest,
      _committedSelection,
    );
    _activePoseId = poseId;
    _committedSelection = preservedSelection;
    _pendingSelection = Map<String, String?>.from(_committedSelection);
    _syncClothesFocusForCurrentState();
    notifyListeners();
  }

  bool randomizeOutfit({Random? random}) {
    final manifest = _manifest;
    final poseId = _activePoseId;
    if (manifest == null || poseId == null) {
      return false;
    }

    final poseRenders = manifest.renders
        .where((WardrobeRender render) => render.poseId == poseId)
        .toList(growable: false);
    if (poseRenders.isEmpty) {
      return false;
    }

    final rng = random ?? Random();
    final currentTopId = _committedSelection['top'];
    final currentBottomId = _committedSelection['bottom'];

    WardrobeRender selectedRender =
        poseRenders[rng.nextInt(poseRenders.length)];
    if (poseRenders.length > 1 &&
        selectedRender.topId == currentTopId &&
        selectedRender.bottomId == currentBottomId) {
      var offset = rng.nextInt(poseRenders.length - 1) + 1;
      final currentIndex = poseRenders.indexOf(selectedRender);
      selectedRender =
          poseRenders[(currentIndex + offset) % poseRenders.length];
    }

    final nextSelection = _normalizeSelectionForManifest(
      manifest,
      _committedSelection,
    );
    nextSelection['top'] = selectedRender.topId;
    nextSelection['bottom'] = selectedRender.bottomId;

    for (final category in manifest.orderedCategories) {
      if (category == 'top' || category == 'bottom') {
        continue;
      }
      final options = _cycleValuesForCategory(
        category: category,
        applyFilters: false,
      );
      if (options.isEmpty) {
        continue;
      }
      nextSelection[category] = options[rng.nextInt(options.length)];
    }

    _committedSelection = nextSelection;
    _pendingSelection = Map<String, String?>.from(_committedSelection);
    _syncClothesFocusForCurrentState();
    notifyListeners();
    return true;
  }

  bool isItemQueuedForRegeneration(String category, String itemId) {
    final manifest = _manifest;
    if (manifest == null) {
      return false;
    }
    final normalizedCategory = category.trim().toLowerCase();
    final normalizedItemId = itemId.trim();
    if (normalizedCategory.isEmpty || normalizedItemId.isEmpty) {
      return false;
    }
    return manifest.regeneration.items.any(
      (WardrobeRegenerationRequest request) =>
          request.category == normalizedCategory &&
          request.itemId == normalizedItemId,
    );
  }

  bool isPoseItemQueuedForRegeneration({
    required String poseId,
    required String category,
    required String itemId,
  }) {
    final manifest = _manifest;
    if (manifest == null) {
      return false;
    }
    final normalizedPoseId = poseId.trim();
    final normalizedCategory = category.trim().toLowerCase();
    final normalizedItemId = itemId.trim();
    if (normalizedPoseId.isEmpty ||
        normalizedCategory.isEmpty ||
        normalizedItemId.isEmpty) {
      return false;
    }
    return manifest.regeneration.targets.any(
      (WardrobeRegenerationTarget request) =>
          request.type == WardrobeRegenerationTargetType.poseItem &&
          request.poseId == normalizedPoseId &&
          request.category == normalizedCategory &&
          request.itemId == normalizedItemId,
    );
  }

  bool isRenderQueuedForRegeneration({
    required String poseId,
    required String topId,
    required String bottomId,
  }) {
    final manifest = _manifest;
    if (manifest == null) {
      return false;
    }
    final normalizedPoseId = poseId.trim();
    final normalizedTopId = topId.trim();
    final normalizedBottomId = bottomId.trim();
    if (normalizedPoseId.isEmpty ||
        normalizedTopId.isEmpty ||
        normalizedBottomId.isEmpty) {
      return false;
    }
    return manifest.regeneration.targets.any(
      (WardrobeRegenerationTarget request) =>
          request.type == WardrobeRegenerationTargetType.render &&
          request.poseId == normalizedPoseId &&
          request.topId == normalizedTopId &&
          request.bottomId == normalizedBottomId,
    );
  }

  bool isOverlayQueuedForRegeneration({
    required String poseId,
    required String category,
    required String itemId,
  }) {
    final manifest = _manifest;
    if (manifest == null) {
      return false;
    }
    final normalizedPoseId = poseId.trim();
    final normalizedCategory = category.trim().toLowerCase();
    final normalizedItemId = itemId.trim();
    if (normalizedPoseId.isEmpty ||
        normalizedCategory.isEmpty ||
        normalizedItemId.isEmpty) {
      return false;
    }
    return manifest.regeneration.targets.any(
      (WardrobeRegenerationTarget request) =>
          request.type == WardrobeRegenerationTargetType.overlay &&
          request.poseId == normalizedPoseId &&
          request.category == normalizedCategory &&
          request.itemId == normalizedItemId,
    );
  }

  CurrentLookRegenerationBundle? currentLookRegenerationBundle() {
    final manifest = _manifest;
    final poseId = _activePoseId;
    if (manifest == null || poseId == null) {
      return null;
    }

    final pose = manifest.poses
        .where((WardrobePose candidate) => candidate.id == poseId)
        .firstOrNull;
    if (pose == null || !pose.renderReady) {
      return null;
    }

    final topId = _committedSelection['top'];
    final bottomId = _committedSelection['bottom'];
    if (topId == null || bottomId == null) {
      return null;
    }

    return CurrentLookRegenerationBundle(
      renderTarget: CurrentRenderRegenerationTarget(
        poseId: poseId,
        topId: topId,
        bottomId: bottomId,
      ),
      headwearTarget: _currentOverlayTarget(
        poseId: poseId,
        category: 'headwear',
      ),
      shoesTarget: _currentOverlayTarget(poseId: poseId, category: 'shoes'),
    );
  }

  CurrentOverlayRegenerationTarget? _currentOverlayTarget({
    required String poseId,
    required String category,
  }) {
    final manifest = _manifest;
    if (manifest == null) {
      return null;
    }
    final itemId = _committedSelection[category];
    if (itemId == null || itemId.isEmpty) {
      return null;
    }
    final exists = manifest
        .itemsForCategory(category)
        .any((WardrobeItem item) => item.id == itemId);
    if (!exists) {
      return null;
    }
    return CurrentOverlayRegenerationTarget(
      poseId: poseId,
      category: category,
      itemId: itemId,
    );
  }

  CurrentOutfitState? currentOutfitState() {
    final manifest = _manifest;
    final poseId = _activePoseId;
    if (manifest == null || poseId == null) {
      return null;
    }

    return CurrentOutfitState(
      poseId: poseId,
      selection: _normalizeSelectionForManifest(manifest, _committedSelection),
    );
  }

  bool restoreCurrentOutfitState(CurrentOutfitState state) {
    final manifest = _manifest;
    if (manifest == null || !availablePoses.contains(state.poseId)) {
      return false;
    }

    _activePoseId = state.poseId;
    _committedSelection = _normalizeSelectionForManifest(
      manifest,
      state.selection,
    );
    _pendingSelection = Map<String, String?>.from(_committedSelection);
    _syncClothesFocusForCurrentState();
    notifyListeners();
    return true;
  }

  CurrentLookRegenerationState get currentLookRegenerationState {
    final bundle = currentLookRegenerationBundle();
    if (bundle == null) {
      return CurrentLookRegenerationState.none;
    }

    var total = 1;
    var queued =
        isRenderQueuedForRegeneration(
          poseId: bundle.renderTarget.poseId,
          topId: bundle.renderTarget.topId,
          bottomId: bundle.renderTarget.bottomId,
        )
        ? 1
        : 0;

    if (bundle.headwearTarget != null) {
      total += 1;
      if (isOverlayQueuedForRegeneration(
        poseId: bundle.headwearTarget!.poseId,
        category: bundle.headwearTarget!.category,
        itemId: bundle.headwearTarget!.itemId,
      )) {
        queued += 1;
      }
    }
    if (bundle.shoesTarget != null) {
      total += 1;
      if (isOverlayQueuedForRegeneration(
        poseId: bundle.shoesTarget!.poseId,
        category: bundle.shoesTarget!.category,
        itemId: bundle.shoesTarget!.itemId,
      )) {
        queued += 1;
      }
    }

    if (queued <= 0) {
      return CurrentLookRegenerationState.none;
    }
    if (queued >= total) {
      return CurrentLookRegenerationState.full;
    }
    return CurrentLookRegenerationState.partial;
  }

  List<CurrentLookScopeStatus> currentLookScopeStatuses() {
    final bundle = currentLookRegenerationBundle();
    if (bundle == null) {
      return const <CurrentLookScopeStatus>[];
    }

    return <CurrentLookScopeStatus>[
      CurrentLookScopeStatus(
        scope: CurrentLookRegenerationScope.look,
        label: 'Whole look',
        queued:
            currentLookRegenerationState == CurrentLookRegenerationState.full,
      ),
      CurrentLookScopeStatus(
        scope: CurrentLookRegenerationScope.render,
        label: 'Only visible render',
        queued: isRenderQueuedForRegeneration(
          poseId: bundle.renderTarget.poseId,
          topId: bundle.renderTarget.topId,
          bottomId: bundle.renderTarget.bottomId,
        ),
      ),
      if (bundle.headwearTarget != null)
        CurrentLookScopeStatus(
          scope: CurrentLookRegenerationScope.headwear,
          label: 'Only headwear',
          queued: isOverlayQueuedForRegeneration(
            poseId: bundle.headwearTarget!.poseId,
            category: bundle.headwearTarget!.category,
            itemId: bundle.headwearTarget!.itemId,
          ),
        ),
      if (bundle.shoesTarget != null)
        CurrentLookScopeStatus(
          scope: CurrentLookRegenerationScope.shoes,
          label: 'Only shoes',
          queued: isOverlayQueuedForRegeneration(
            poseId: bundle.shoesTarget!.poseId,
            category: bundle.shoesTarget!.category,
            itemId: bundle.shoesTarget!.itemId,
          ),
        ),
    ];
  }

  OutfitComposition currentComposition() {
    final manifest = _manifest;
    final packRoot = _packRoot;
    final poseId = _activePoseId;
    if (manifest == null || packRoot == null || poseId == null) {
      return const OutfitComposition(baseImagePath: null, overlays: <String>[]);
    }

    return _compositionForSelection(
      manifest: manifest,
      packRoot: packRoot,
      poseId: poseId,
      selection: _committedSelection,
    );
  }

  List<String> warmupImagePaths() {
    final manifest = _manifest;
    final packRoot = _packRoot;
    if (manifest == null || packRoot == null) {
      return const <String>[];
    }

    final paths = <String>{
      ...manifest.renders.map(
        (WardrobeRender render) => _absolutePath(packRoot, render.path),
      ),
      ...manifest.overlays.map(
        (WardrobeOverlay overlay) => _absolutePath(packRoot, overlay.path),
      ),
    };

    for (final pose in manifest.poses) {
      if (pose.thumbPath != null && pose.thumbPath!.isNotEmpty) {
        paths.add(_absolutePath(packRoot, pose.thumbPath!));
      }
    }

    for (final items in manifest.categories.values) {
      for (final item in items) {
        if (item.thumbPath != null && item.thumbPath!.isNotEmpty) {
          paths.add(_absolutePath(packRoot, item.thumbPath!));
        }
      }
    }

    return paths.toList(growable: false);
  }

  List<String> adjacentImagePaths() {
    final manifest = _manifest;
    final packRoot = _packRoot;
    final poseId = _activePoseId;
    if (manifest == null || packRoot == null || poseId == null) {
      return const <String>[];
    }

    final baseSelection = Map<String, String?>.from(_committedSelection);
    final paths = <String>{};

    for (final category in categories) {
      final values = _cycleValuesForCategory(
        category: category,
        applyFilters: true,
      );
      if (values.isEmpty) {
        continue;
      }

      final current = _committedSelection[category];
      var index = values.indexOf(current);
      if (index < 0) {
        index = 0;
      }

      for (final direction in const <int>[-1, 1]) {
        final nextIndex = (index + direction) % values.length;
        final wrappedIndex = nextIndex < 0
            ? nextIndex + values.length
            : nextIndex;
        final nextValue = values[wrappedIndex];
        final selection = Map<String, String?>.from(baseSelection)
          ..[category] = nextValue;
        final composition = _compositionForSelection(
          manifest: manifest,
          packRoot: packRoot,
          poseId: poseId,
          selection: selection,
        );
        if (composition.baseImagePath != null) {
          paths.add(composition.baseImagePath!);
        }
        paths.addAll(composition.overlays);
      }
    }

    return paths.toList(growable: false);
  }

  String _sectionKeyFor({
    required String category,
    required String? subcategoryKey,
  }) {
    if (subcategoryKey == null || subcategoryKey.isEmpty) {
      return '$category::root';
    }
    return '$category::$subcategoryKey';
  }

  String? _subcategoryForItem({
    required String category,
    required String? itemId,
  }) {
    final manifest = _manifest;
    if (manifest == null || itemId == null) {
      return null;
    }

    final item = manifest
        .itemsForCategory(category)
        .where((WardrobeItem candidate) => candidate.id == itemId)
        .firstOrNull;
    return item?.subcategory;
  }

  String? _normalizeSubcategoryKey(String? rawSubcategory) {
    final normalized = rawSubcategory?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return normalized.toLowerCase();
  }

  String _displaySubcategoryLabel(String? rawSubcategory) {
    final normalized = rawSubcategory?.trim();
    if (normalized == null || normalized.isEmpty) {
      return _uncategorizedSubcategoryLabel;
    }
    return normalized;
  }

  String _prettyCategory(String category) {
    if (category == uncategorizedIntakeCategory) {
      return uncategorizedIntakeLabel;
    }
    if (category.isEmpty) {
      return category;
    }
    return '${category[0].toUpperCase()}${category.substring(1)}';
  }

  bool _isLocalTypeFilterCategory(String category) {
    final normalized = category.trim();
    return normalized.isNotEmpty &&
        normalized != uncategorizedIntakeCategory &&
        clothesMainCategories.contains(normalized);
  }

  bool _matchesFilters(WardrobeItem item) {
    if (!_filterState.hasAnyFilter) {
      return true;
    }

    if (_isLocalTypeFilterCategory(item.category)) {
      final localTypeFilters = _filterState.localTypeFilters[item.category];
      if (localTypeFilters != null && localTypeFilters.isNotEmpty) {
        final itemType = _normalizedFacetValue(item.subcategory);
        if (itemType == null || !localTypeFilters.contains(itemType)) {
          return false;
        }
      }
    }

    if (_filterState.globalColors.isNotEmpty) {
      final value = _normalizedFacetValue(item.colorPrimary);
      if (value == null || !_filterState.globalColors.contains(value)) {
        return false;
      }
    }
    if (_filterState.globalMaterials.isNotEmpty) {
      final value = _normalizedFacetValue(item.material);
      if (value == null || !_filterState.globalMaterials.contains(value)) {
        return false;
      }
    }
    if (_filterState.globalStyles.isNotEmpty) {
      final value = _normalizedFacetValue(item.styleOccasion);
      if (value == null || !_filterState.globalStyles.contains(value)) {
        return false;
      }
    }
    if (_filterState.globalPatterns.isNotEmpty) {
      final value = _normalizedFacetValue(item.patternDesign);
      if (value == null || !_filterState.globalPatterns.contains(value)) {
        return false;
      }
    }
    if (_filterState.globalTags.isNotEmpty) {
      final normalizedTags = item.tags
          .map(_normalizedFacetValue)
          .whereType<String>()
          .toSet();
      if (normalizedTags.isEmpty) {
        return false;
      }
      final hasAnyTag = normalizedTags.any(_filterState.globalTags.contains);
      if (!hasAnyTag) {
        return false;
      }
    }

    return true;
  }

  void _addFacetValue(Set<String> target, String? value) {
    final normalized = _normalizedFacetValue(value);
    if (normalized == null) {
      return;
    }
    target.add(normalized);
  }

  String? _normalizedFacetValue(String? value) {
    final trimmed = (value ?? '').trim().toLowerCase();
    if (trimmed.isEmpty || trimmed == 'unknown') {
      return null;
    }
    return trimmed.split(RegExp(r'\s+')).join(' ');
  }

  List<String> _sortedValues(Iterable<String> values) {
    final list = values.toSet().toList(growable: false);
    list.sort((String left, String right) {
      final lowerCompare = left.toLowerCase().compareTo(right.toLowerCase());
      if (lowerCompare != 0) {
        return lowerCompare;
      }
      return left.compareTo(right);
    });
    return list;
  }

  Map<String, String?> _defaultSelectionForManifest(WardrobeManifest manifest) {
    final defaults = <String, String?>{};

    if (_shouldHideDefaultPackContent(manifest)) {
      for (final category in manifest.orderedCategories) {
        defaults[category] = null;
      }
      return defaults;
    }

    for (final category in manifest.orderedCategories) {
      final items = manifest.itemsForCategory(category);
      final renderable = items.where((WardrobeItem item) => item.renderReady);
      if (category == 'top' || category == 'bottom') {
        defaults[category] = renderable.isNotEmpty
            ? renderable.first.id
            : (items.isEmpty ? null : items.first.id);
      } else {
        defaults[category] = null;
      }
    }
    return defaults;
  }

  Map<String, String?> _normalizeSelectionForManifest(
    WardrobeManifest manifest,
    Map<String, String?> selection,
  ) {
    final normalized = _defaultSelectionForManifest(manifest);

    for (final category in manifest.orderedCategories) {
      final selected = selection[category];
      if (selected == null) {
        if (category != 'top' && category != 'bottom') {
          normalized[category] = null;
        }
        continue;
      }

      final validItem = _visibleItemsForCategory(
        manifest: manifest,
        category: category,
      ).where((WardrobeItem item) => item.id == selected).firstOrNull;
      if (validItem != null && validItem.renderReady) {
        normalized[category] = selected;
      }
    }

    return normalized;
  }

  List<String?> _cycleValuesForCategory({
    required String category,
    required bool applyFilters,
  }) {
    final manifest = _manifest;
    if (manifest == null || category == uncategorizedIntakeCategory) {
      return const <String?>[];
    }

    final values = <String?>[];

    if (category != 'top' && category != 'bottom') {
      values.add(null);
    }

    final grouped = <String, List<WardrobeItem>>{};
    final labels = <String, String>{};
    for (final item in _visibleItemsForCategory(
      manifest: manifest,
      category: category,
    )) {
      if (!item.renderReady) {
        continue;
      }
      if (applyFilters && !_matchesFilters(item)) {
        continue;
      }

      final normalizedKey = _normalizeSubcategoryKey(item.subcategory);
      final bucketKey = normalizedKey ?? '';
      grouped.putIfAbsent(bucketKey, () => <WardrobeItem>[]).add(item);
      labels[bucketKey] = _displaySubcategoryLabel(item.subcategory);
    }

    final orderedGroupKeys = grouped.keys.toList(growable: true)
      ..sort((String left, String right) {
        if (left.isEmpty && right.isNotEmpty) {
          return -1;
        }
        if (right.isEmpty && left.isNotEmpty) {
          return 1;
        }
        return (labels[left] ?? left).compareTo(labels[right] ?? right);
      });

    for (final groupKey in orderedGroupKeys) {
      for (final item in grouped[groupKey] ?? const <WardrobeItem>[]) {
        values.add(item.id);
      }
    }

    return values;
  }

  OutfitComposition _compositionForSelection({
    required WardrobeManifest manifest,
    required Directory packRoot,
    required String poseId,
    required Map<String, String?> selection,
  }) {
    final pose = manifest.poses
        .where((WardrobePose candidate) => candidate.id == poseId)
        .firstOrNull;
    final topId = selection['top'];
    final bottomId = selection['bottom'];

    final render = manifest.findRender(
      poseId: poseId,
      topId: topId,
      bottomId: bottomId,
    );

    if (pose != null && !pose.renderReady) {
      final posePath = _firstNonEmpty(pose.path, pose.thumbPath);
      return OutfitComposition(
        baseImagePath: posePath == null || posePath.isEmpty
            ? null
            : _absolutePath(packRoot, posePath),
        overlays: const <String>[],
      );
    }

    final overlays = <String>[];
    for (final category in categories) {
      if (category == 'top' || category == 'bottom') {
        continue;
      }
      final selectedItemId = selection[category];
      final overlay = manifest.findOverlay(
        poseId: poseId,
        category: category,
        itemId: selectedItemId,
      );
      if (overlay != null) {
        overlays.add(_absolutePath(packRoot, overlay.path));
      }
    }

    return OutfitComposition(
      baseImagePath: render == null
          ? null
          : _absolutePath(packRoot, render.path),
      overlays: overlays,
    );
  }

  String? _absoluteThumbPath({
    required String category,
    required String itemId,
  }) {
    final manifest = _manifest;
    final packRoot = _packRoot;
    if (manifest == null || packRoot == null) {
      return null;
    }

    final relativePath = manifest.findThumbPath(
      category: category,
      itemId: itemId,
    );
    if (relativePath == null) {
      return null;
    }

    return _absolutePath(packRoot, relativePath);
  }

  String _absolutePath(Directory root, String relativePath) {
    final normalized = p.normalize(relativePath).replaceAll('\\', '/');
    final override = _assetPathOverrides[normalized];
    if (override != null) {
      return override;
    }
    return p.join(root.path, normalized);
  }

  WardrobePose? get _activePose {
    final manifest = _manifest;
    final poseId = _activePoseId;
    if (manifest == null || poseId == null) {
      return null;
    }
    return manifest.poses
        .where((WardrobePose pose) => pose.id == poseId)
        .firstOrNull;
  }

  bool _shouldHideDefaultPackContent(WardrobeManifest manifest) {
    if (manifest.intakeQueue.isNotEmpty) {
      return true;
    }
    if (manifest.poses.any((WardrobePose pose) => !pose.renderReady)) {
      return true;
    }
    for (final items in manifest.categories.values) {
      if (items.any((WardrobeItem item) => !item.renderReady)) {
        return true;
      }
    }
    return false;
  }

  List<WardrobePose> _visiblePosesForManifest(WardrobeManifest manifest) {
    if (!_shouldHideDefaultPackContent(manifest)) {
      return manifest.poses;
    }
    return manifest.poses
        .where((WardrobePose pose) => !pose.renderReady)
        .toList(growable: false);
  }

  List<WardrobeItem> _visibleItemsForCategory({
    required WardrobeManifest manifest,
    required String category,
  }) {
    final items = manifest.itemsForCategory(category);
    if (!_shouldHideDefaultPackContent(manifest)) {
      return items;
    }
    return items
        .where((WardrobeItem item) => !item.renderReady)
        .toList(growable: false);
  }

  List<WardrobePendingIntakeItem> _visibleIntakeQueueForManifest(
    WardrobeManifest manifest,
  ) {
    if (!_shouldHideDefaultPackContent(manifest)) {
      return const <WardrobePendingIntakeItem>[];
    }
    return _uncategorizedIntakeItemsForManifest(manifest);
  }

  List<WardrobePendingIntakeItem> _uncategorizedIntakeItemsForManifest(
    WardrobeManifest manifest,
  ) {
    if (manifest.intakeQueue.isEmpty) {
      return const <WardrobePendingIntakeItem>[];
    }

    final categorizedIds = <String>{
      for (final category in manifest.orderedCategories)
        ...manifest
            .itemsForCategory(category)
            .map((WardrobeItem item) => item.id),
    };

    return manifest.intakeQueue
        .where((WardrobePendingIntakeItem item) {
          return !categorizedIds.contains(item.id);
        })
        .toList(growable: false);
  }

  String? _absolutePendingThumbPath(WardrobePendingIntakeItem item) {
    final root = _packRoot;
    if (root == null || item.thumbPath.isEmpty) {
      return null;
    }
    return _absolutePath(root, item.thumbPath);
  }

  String _itemLabel({
    required WardrobeManifest manifest,
    required String category,
    required String? itemId,
  }) {
    if (itemId == null) {
      return 'None';
    }
    for (final item in manifest.itemsForCategory(category)) {
      if (item.id == itemId) {
        return _displayItemLabelForItem(item);
      }
    }
    return _displayItemLabel(itemId);
  }

  String _poseLabel(WardrobeManifest manifest, String poseId) {
    for (final pose in manifest.poses) {
      if (pose.id == poseId) {
        return pose.name;
      }
    }
    return poseId;
  }

  bool _selectionEquals({
    required Map<String, String?> left,
    required Map<String, String?> right,
    required List<String> categories,
  }) {
    for (final category in categories) {
      if (left[category] != right[category]) {
        return false;
      }
    }
    return true;
  }

  String _displayItemLabel(String rawId) {
    final normalized = rawId.trim();
    if (normalized.isEmpty) {
      return rawId;
    }
    final words = normalized
        .replaceAll('-', ' ')
        .split(' ')
        .where((String word) => word.isNotEmpty)
        .toList(growable: false);
    if (words.isEmpty) {
      return normalized;
    }
    return words
        .map((String word) {
          if (word.length <= 1) {
            return word.toUpperCase();
          }
          return '${word[0].toUpperCase()}${word.substring(1)}';
        })
        .join(' ');
  }

  String _displayItemLabelForItem(WardrobeItem item) {
    final explicitName = item.name.trim();
    if (explicitName.isNotEmpty) {
      return explicitName;
    }
    return _displayItemLabel(item.id);
  }
}
