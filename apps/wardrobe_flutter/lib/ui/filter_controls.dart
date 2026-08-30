import 'package:flutter/material.dart';

import '../services/wardrobe_repository.dart';

Future<void> showWardrobeFilterPanel({
  required BuildContext context,
  required WardrobeRepository repository,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (BuildContext context) {
      return _FilterPanelContent(repository: repository);
    },
  );
}

class FilterIconButton extends StatelessWidget {
  const FilterIconButton({
    super.key,
    required this.onPressed,
    this.compact = false,
  });

  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Filter clothes',
      child: IconButton.filledTonal(
        onPressed: onPressed,
        icon: const Icon(Icons.filter_alt_outlined, size: 18),
        style: IconButton.styleFrom(
          visualDensity: compact
              ? const VisualDensity(horizontal: -2, vertical: -2)
              : const VisualDensity(horizontal: -1, vertical: -1),
          fixedSize: Size.square(compact ? 36 : 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(compact ? 11 : 12),
          ),
        ),
      ),
    );
  }
}

class FilterSummaryBar extends StatelessWidget {
  const FilterSummaryBar({
    super.key,
    required this.repository,
    required this.onOpenFilters,
    this.compact = false,
    this.showWhenInactive = true,
    this.showOpenButtonInActive = true,
    this.showClearAll = true,
  });

  final WardrobeRepository repository;
  final VoidCallback onOpenFilters;
  final bool compact;
  final bool showWhenInactive;
  final bool showOpenButtonInActive;
  final bool showClearAll;

  @override
  Widget build(BuildContext context) {
    final chips = repository.activeFilterChips();
    final hasActiveFilters = repository.filterState.activeValueCount > 0;
    final colorScheme = Theme.of(context).colorScheme;
    final openFiltersButton = FilterIconButton(
      onPressed: onOpenFilters,
      compact: compact,
    );

    if (!hasActiveFilters) {
      if (!showWhenInactive) {
        return const SizedBox.shrink();
      }
      return Align(alignment: Alignment.centerRight, child: openFiltersButton);
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: compact ? 0.9 : 0.93),
          borderRadius: BorderRadius.circular(compact ? 10 : 12),
          border: Border.all(
            color: colorScheme.primary.withValues(alpha: 0.22),
            width: compact ? 0.8 : 0.9,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 9,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 7 : 8,
            vertical: compact ? 5 : 6,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: SizedBox(
                  height: compact ? 32 : 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: chips.length,
                    separatorBuilder: (BuildContext context, int index) =>
                        const SizedBox(width: 6),
                    itemBuilder: (BuildContext context, int index) {
                      final chip = chips[index];
                      return InputChip(
                        label: Text('${chip.label}: ${chip.value}'),
                        onDeleted: () {
                          if (chip.isLocalType) {
                            final category = chip.category;
                            if (category == null) {
                              return;
                            }
                            repository.toggleLocalTypeFilter(
                              category,
                              chip.value,
                            );
                            return;
                          }
                          final field = chip.globalField;
                          if (field != null) {
                            repository.toggleGlobalFilterValue(
                              field,
                              chip.value,
                            );
                          }
                        },
                        visualDensity: compact
                            ? const VisualDensity(horizontal: -2, vertical: -2)
                            : null,
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 6),
              if (showClearAll)
                TextButton(
                  onPressed: repository.clearAllFilters,
                  style: TextButton.styleFrom(
                    visualDensity: compact
                        ? const VisualDensity(horizontal: -2, vertical: -2)
                        : null,
                  ),
                  child: const Text('Clear all'),
                ),
              if (showOpenButtonInActive) openFiltersButton,
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterPanelContent extends StatelessWidget {
  const _FilterPanelContent({required this.repository});

  final WardrobeRepository repository;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: repository,
      builder: (BuildContext context, Widget? child) {
        final facets = repository.filterFacets();
        final categories = repository.clothesMainCategories
            .where(
              (String category) =>
                  category != WardrobeRepository.uncategorizedIntakeCategory,
            )
            .toList(growable: false);

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Text(
                    'Filter Clothes',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  if (repository.hasActiveFilters)
                    TextButton(
                      onPressed: repository.clearAllFilters,
                      child: const Text('Clear all'),
                    ),
                ],
              ),
              Expanded(
                child: ListView(
                  children: <Widget>[
                    _GlobalFieldSection(
                      title: 'Color',
                      values: facets.colors,
                      isSelected: (String value) =>
                          repository.isGlobalFilterValueSelected(
                            WardrobeGlobalFilterField.color,
                            value,
                          ),
                      onToggle: (String value) =>
                          repository.toggleGlobalFilterValue(
                            WardrobeGlobalFilterField.color,
                            value,
                          ),
                      onClear: () => repository.clearFilterField(
                        WardrobeGlobalFilterField.color,
                      ),
                    ),
                    _GlobalFieldSection(
                      title: 'Material',
                      values: facets.materials,
                      isSelected: (String value) =>
                          repository.isGlobalFilterValueSelected(
                            WardrobeGlobalFilterField.material,
                            value,
                          ),
                      onToggle: (String value) =>
                          repository.toggleGlobalFilterValue(
                            WardrobeGlobalFilterField.material,
                            value,
                          ),
                      onClear: () => repository.clearFilterField(
                        WardrobeGlobalFilterField.material,
                      ),
                    ),
                    _GlobalFieldSection(
                      title: 'Tags',
                      values: facets.tags,
                      isSelected: (String value) =>
                          repository.isGlobalFilterValueSelected(
                            WardrobeGlobalFilterField.tags,
                            value,
                          ),
                      onToggle: (String value) =>
                          repository.toggleGlobalFilterValue(
                            WardrobeGlobalFilterField.tags,
                            value,
                          ),
                      onClear: () => repository.clearFilterField(
                        WardrobeGlobalFilterField.tags,
                      ),
                    ),
                    _GlobalFieldSection(
                      title: 'Style',
                      values: facets.styles,
                      isSelected: (String value) =>
                          repository.isGlobalFilterValueSelected(
                            WardrobeGlobalFilterField.style,
                            value,
                          ),
                      onToggle: (String value) =>
                          repository.toggleGlobalFilterValue(
                            WardrobeGlobalFilterField.style,
                            value,
                          ),
                      onClear: () => repository.clearFilterField(
                        WardrobeGlobalFilterField.style,
                      ),
                    ),
                    _GlobalFieldSection(
                      title: 'Pattern',
                      values: facets.patterns,
                      isSelected: (String value) =>
                          repository.isGlobalFilterValueSelected(
                            WardrobeGlobalFilterField.pattern,
                            value,
                          ),
                      onToggle: (String value) =>
                          repository.toggleGlobalFilterValue(
                            WardrobeGlobalFilterField.pattern,
                            value,
                          ),
                      onClear: () => repository.clearFilterField(
                        WardrobeGlobalFilterField.pattern,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Type Filters (Local per Category)',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final category in categories)
                      _LocalTypeSection(
                        category: category,
                        title: _prettyCategory(category),
                        values:
                            facets.localTypesByCategory[category] ??
                            const <String>[],
                        selectedCount:
                            repository
                                .filterState
                                .localTypeFilters[category]
                                ?.length ??
                            0,
                        isSelected: (String value) => repository
                            .isLocalTypeFilterSelected(category, value),
                        onToggle: (String value) =>
                            repository.toggleLocalTypeFilter(category, value),
                        onClear: () =>
                            repository.clearLocalTypeFilter(category),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _prettyCategory(String category) {
    if (category.isEmpty) {
      return category;
    }
    return '${category[0].toUpperCase()}${category.substring(1)}';
  }
}

class _GlobalFieldSection extends StatelessWidget {
  const _GlobalFieldSection({
    required this.title,
    required this.values,
    required this.isSelected,
    required this.onToggle,
    required this.onClear,
  });

  final String title;
  final List<String> values;
  final bool Function(String value) isSelected;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final selectedCount = values.where(isSelected).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _FieldCard(
        title: title,
        selectedCount: selectedCount,
        onClear: selectedCount > 0 ? onClear : null,
        child: values.isEmpty
            ? _emptyText('No values available')
            : Wrap(
                spacing: 8,
                runSpacing: 8,
                children: values
                    .map(
                      (String value) => FilterChip(
                        label: Text(value),
                        selected: isSelected(value),
                        onSelected: (_) => onToggle(value),
                      ),
                    )
                    .toList(growable: false),
              ),
      ),
    );
  }
}

class _LocalTypeSection extends StatelessWidget {
  const _LocalTypeSection({
    required this.category,
    required this.title,
    required this.values,
    required this.selectedCount,
    required this.isSelected,
    required this.onToggle,
    required this.onClear,
  });

  final String category;
  final String title;
  final List<String> values;
  final int selectedCount;
  final bool Function(String value) isSelected;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _FieldCard(
        title: '$title Type',
        selectedCount: selectedCount,
        onClear: selectedCount > 0 ? onClear : null,
        child: values.isEmpty
            ? _emptyText('No subcategories available for $category')
            : Wrap(
                spacing: 8,
                runSpacing: 8,
                children: values
                    .map(
                      (String value) => FilterChip(
                        label: Text(value),
                        selected: isSelected(value),
                        onSelected: (_) => onToggle(value),
                      ),
                    )
                    .toList(growable: false),
              ),
      ),
    );
  }
}

class _FieldCard extends StatelessWidget {
  const _FieldCard({
    required this.title,
    required this.selectedCount,
    required this.child,
    this.onClear,
  });

  final String title;
  final int selectedCount;
  final Widget child;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (selectedCount > 0)
                  Text(
                    '$selectedCount selected',
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                  ),
                if (onClear != null)
                  TextButton(onPressed: onClear, child: const Text('Clear')),
              ],
            ),
            const SizedBox(height: 6),
            child,
          ],
        ),
      ),
    );
  }
}

Widget _emptyText(String text) {
  return Text(
    text,
    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
  );
}
