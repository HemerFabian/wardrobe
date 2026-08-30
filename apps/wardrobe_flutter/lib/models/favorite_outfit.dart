class FavoriteOutfit {
  const FavoriteOutfit({
    required this.key,
    required this.selection,
    required this.createdAt,
  });

  factory FavoriteOutfit.fromJson(Map<String, dynamic> json) {
    final rawSelection =
        (json['selection'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final selection = <String, String?>{
      for (final entry in rawSelection.entries)
        entry.key: entry.value?.toString(),
    };

    final orderedCategories =
        (json['categories'] as List<dynamic>? ?? const <dynamic>[])
            .map((dynamic value) => value.toString())
            .toList(growable: false);
    final fallbackCategories = selection.keys.toList()..sort();

    final key = buildKey(
      selection: selection,
      categories: orderedCategories.isEmpty
          ? fallbackCategories
          : orderedCategories,
    );

    return FavoriteOutfit(
      key: key,
      selection: selection,
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now().toUtc(),
    );
  }

  final String key;
  final Map<String, String?> selection;
  final DateTime createdAt;

  static String buildKey({
    required Map<String, String?> selection,
    required Iterable<String> categories,
  }) {
    final buffer = StringBuffer('outfit');
    for (final category in categories) {
      final selected = selection[category];
      buffer
        ..write('|')
        ..write(Uri.encodeComponent(category))
        ..write('=')
        ..write(selected == null ? '~' : Uri.encodeComponent(selected));
    }
    return buffer.toString();
  }

  static Map<String, String?> normalizeSelection({
    required Map<String, String?> selection,
    required Iterable<String> categories,
  }) {
    return <String, String?>{
      for (final category in categories) category: selection[category],
    };
  }

  Map<String, dynamic> toJson({required List<String> orderedCategories}) {
    final normalizedSelection = normalizeSelection(
      selection: selection,
      categories: orderedCategories,
    );
    return <String, dynamic>{
      'key': key,
      'selection': <String, String?>{
        for (final category in orderedCategories)
          category: normalizedSelection[category],
      },
      'categories': orderedCategories,
      'created_at': createdAt.toUtc().toIso8601String(),
    };
  }

  FavoriteOutfit copyWith({
    String? key,
    Map<String, String?>? selection,
    DateTime? createdAt,
  }) {
    return FavoriteOutfit(
      key: key ?? this.key,
      selection: selection ?? this.selection,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
