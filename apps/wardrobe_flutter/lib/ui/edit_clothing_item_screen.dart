import 'dart:io';

import 'package:flutter/material.dart';

import '../services/intake_workspace_service.dart';

class EditClothingItemScreen extends StatefulWidget {
  const EditClothingItemScreen({
    super.key,
    required this.workspaceService,
    required this.category,
    required this.itemId,
  });

  final IntakeWorkspaceService workspaceService;
  final String category;
  final String itemId;

  @override
  State<EditClothingItemScreen> createState() => _EditClothingItemScreenState();
}

class _EditClothingItemScreenState extends State<EditClothingItemScreen> {
  static const List<String> _categories = <String>[
    'headwear',
    'top',
    'bottom',
    'shoes',
  ];
  static const Key _previewSectionKey = Key('edit-item-preview');
  static const Key _previewDialogKey = Key('edit-item-preview-dialog');
  static const Key _previewCloseButtonKey = Key('edit-item-preview-close');

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _subcategoryController = TextEditingController();
  final TextEditingController _colorController = TextEditingController();
  final TextEditingController _materialController = TextEditingController();
  final TextEditingController _styleController = TextEditingController();
  final TextEditingController _patternController = TextEditingController();
  final TextEditingController _tagInputController = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _error;
  String _selectedCategory = 'top';
  List<String> _tags = <String>[];
  IntakeTagSuggestions _suggestions = const IntakeTagSuggestions();
  String? _previewImagePath;

  @override
  void initState() {
    super.initState();
    _selectedCategory = widget.category;
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _subcategoryController.dispose();
    _colorController.dispose();
    _materialController.dispose();
    _styleController.dispose();
    _patternController.dispose();
    _tagInputController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final metadata = await widget.workspaceService.loadEditableItemMetadata(
        category: widget.category,
        itemId: widget.itemId,
      );
      final suggestions = await widget.workspaceService.loadTagSuggestions();
      if (!mounted) {
        return;
      }

      setState(() {
        _selectedCategory = metadata.category;
        _nameController.text = metadata.name;
        _subcategoryController.text = metadata.subcategory;
        _colorController.text = metadata.colorPrimary;
        _materialController.text = metadata.material;
        _styleController.text = metadata.styleOccasion;
        _patternController.text = metadata.patternDesign;
        _tags = List<String>.from(metadata.tags);
        _suggestions = suggestions;
        _previewImagePath = metadata.previewImagePath;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    setState(() {
      _saving = true;
    });

    final request = UpdateWardrobeItemRequest(
      currentCategory: widget.category,
      itemId: widget.itemId,
      metadata: EditableWardrobeItemMetadata(
        name: _nameController.text,
        category: _selectedCategory,
        subcategory: _subcategoryController.text,
        colorPrimary: _colorController.text,
        material: _materialController.text,
        styleOccasion: _styleController.text,
        patternDesign: _patternController.text,
        tags: _tags,
      ),
    );

    try {
      final result = await widget.workspaceService
          .updateClothingItemMetadataWithResult(request);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save item: $error'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  void _addTagFromInput() {
    final raw = _tagInputController.text.trim();
    if (raw.isEmpty) {
      return;
    }
    final normalizedExisting = _tags
        .map((String value) => value.toLowerCase())
        .toSet();
    if (normalizedExisting.contains(raw.toLowerCase())) {
      _tagInputController.clear();
      return;
    }
    setState(() {
      _tags = <String>[..._tags, raw]
        ..sort(
          (String left, String right) =>
              left.toLowerCase().compareTo(right.toLowerCase()),
        );
      _tagInputController.clear();
    });
  }

  void _toggleSuggestedTag(String value) {
    final key = value.toLowerCase();
    final current = <String, String>{
      for (final tag in _tags) tag.toLowerCase(): tag,
    };
    if (current.containsKey(key)) {
      current.remove(key);
    } else {
      current[key] = value;
    }
    setState(() {
      _tags = current.values.toList(growable: false)
        ..sort((String left, String right) {
          final cmp = left.toLowerCase().compareTo(right.toLowerCase());
          if (cmp != 0) {
            return cmp;
          }
          return left.compareTo(right);
        });
    });
  }

  List<String> _sortedDisplayTags() {
    final selectedByKey = <String, String>{
      for (final tag in _tags) tag.toLowerCase(): tag,
    };
    final mergedByKey = <String, String>{
      for (final tag in _suggestions.tags) tag.toLowerCase(): tag,
      ...selectedByKey,
    };
    final ordered = mergedByKey.values.toList(growable: false);
    ordered.sort((String left, String right) {
      final leftSelected = selectedByKey.containsKey(left.toLowerCase());
      final rightSelected = selectedByKey.containsKey(right.toLowerCase());
      if (leftSelected != rightSelected) {
        return leftSelected ? -1 : 1;
      }
      final cmp = left.toLowerCase().compareTo(right.toLowerCase());
      if (cmp != 0) {
        return cmp;
      }
      return left.compareTo(right);
    });
    return ordered;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Item'),
        actions: <Widget>[
          TextButton(
            onPressed: _loading || _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _buildErrorState()
          : _buildForm(),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 10),
            Text(_error ?? 'Unknown error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    final displayTags = _sortedDisplayTags();
    final defaultChipColor = Theme.of(context).scaffoldBackgroundColor;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildPreviewSection(),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _selectedCategory,
            decoration: const InputDecoration(labelText: 'Category'),
            items: _categories
                .map(
                  (String category) => DropdownMenuItem<String>(
                    value: category,
                    child: Text(_prettyCategory(category)),
                  ),
                )
                .toList(growable: false),
            onChanged: _saving
                ? null
                : (String? value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _selectedCategory = value;
                    });
                  },
          ),
          const SizedBox(height: 12),
          _fieldWithSuggestions(
            controller: _subcategoryController,
            label: 'Type/Subcategory',
            suggestions: _suggestions.subcategoriesForCategory(
              _selectedCategory,
            ),
          ),
          const SizedBox(height: 12),
          _fieldWithSuggestions(
            controller: _colorController,
            label: 'Color',
            suggestions: _suggestions.colors,
          ),
          const SizedBox(height: 12),
          _fieldWithSuggestions(
            controller: _materialController,
            label: 'Material',
            suggestions: _suggestions.materials,
          ),
          const SizedBox(height: 12),
          _fieldWithSuggestions(
            controller: _styleController,
            label: 'Style',
            suggestions: _suggestions.styles,
          ),
          const SizedBox(height: 12),
          _fieldWithSuggestions(
            controller: _patternController,
            label: 'Pattern',
            suggestions: _suggestions.patterns,
          ),
          const SizedBox(height: 16),
          const Text('Tags', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _tagInputController,
                  decoration: const InputDecoration(
                    hintText: 'Add tag',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _addTagFromInput(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: _addTagFromInput,
                child: const Text('Add'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (displayTags.isEmpty)
            Text(
              'No tags available yet',
              style: TextStyle(color: Colors.grey.shade700),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: displayTags
                  .map((String tag) {
                    final selected = _tags.any(
                      (String current) =>
                          current.toLowerCase() == tag.toLowerCase(),
                    );
                    return FilterChip(
                      label: Text(tag),
                      selected: selected,
                      showCheckmark: false,
                      selectedColor: Colors.blue.shade600,
                      backgroundColor: defaultChipColor,
                      side: BorderSide(
                        color: selected
                            ? Colors.blue.shade600
                            : Colors.grey.shade400,
                      ),
                      labelStyle: TextStyle(
                        color: selected ? Colors.white : Colors.black87,
                      ),
                      onSelected: (_) => _toggleSuggestedTag(tag),
                    );
                  })
                  .toList(growable: false),
            ),
        ],
      ),
    );
  }

  Widget _buildPreviewSection() {
    final previewHeight = _previewHeight(context);
    final hasPreview = _hasAvailablePreviewImage();

    final preview = Material(
      color: Colors.grey.shade100,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        key: _previewSectionKey,
        width: double.infinity,
        height: previewHeight,
        child: hasPreview ? _buildPreviewImage() : _buildPreviewPlaceholder(),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: hasPreview
          ? InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _openPreviewDialog,
              child: preview,
            )
          : preview,
    );
  }

  Widget _buildPreviewImage() {
    final previewPath = _previewImagePath!;
    return Image.file(
      File(previewPath),
      fit: BoxFit.contain,
      errorBuilder:
          (BuildContext context, Object error, StackTrace? stackTrace) =>
              _buildPreviewPlaceholder(),
    );
  }

  Widget _buildPreviewPlaceholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.image_not_supported,
            color: Colors.grey.shade600,
            size: 32,
          ),
          const SizedBox(height: 8),
          Text(
            'No preview available',
            style: TextStyle(color: Colors.grey.shade700),
          ),
        ],
      ),
    );
  }

  bool _hasAvailablePreviewImage() {
    final previewPath = _previewImagePath;
    if (previewPath == null || previewPath.isEmpty) {
      return false;
    }
    return File(previewPath).existsSync();
  }

  double _previewHeight(BuildContext context) {
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final cappedHeight = viewportHeight * 0.28;
    return cappedHeight < 220 ? cappedHeight : 220;
  }

  Future<void> _openPreviewDialog() async {
    if (!_hasAvailablePreviewImage()) {
      return;
    }

    final previewPath = _previewImagePath!;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (BuildContext context) {
        final size = MediaQuery.sizeOf(context);
        final maxWidth = size.width * 0.9;
        final maxHeight = size.height * 0.8;

        return Dialog(
          key: _previewDialogKey,
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight,
            ),
            child: Stack(
              children: <Widget>[
                Container(
                  width: double.infinity,
                  height: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InteractiveViewer(
                    minScale: 1,
                    maxScale: 4,
                    child: Image.file(
                      File(previewPath),
                      fit: BoxFit.contain,
                      errorBuilder:
                          (
                            BuildContext context,
                            Object error,
                            StackTrace? stackTrace,
                          ) => _buildDialogPlaceholder(),
                    ),
                  ),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: IconButton.filledTonal(
                    key: _previewCloseButtonKey,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    color: Colors.white,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black54,
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

  Widget _buildDialogPlaceholder() {
    return Container(
      color: Colors.grey.shade900,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.image_not_supported,
            color: Colors.white70,
            size: 40,
          ),
          const SizedBox(height: 10),
          Text(
            'Preview unavailable',
            style: TextStyle(color: Colors.grey.shade300),
          ),
        ],
      ),
    );
  }

  Widget _fieldWithSuggestions({
    required TextEditingController controller,
    required String label,
    required List<String> suggestions,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(
          controller: controller,
          decoration: InputDecoration(labelText: label),
        ),
        if (suggestions.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: suggestions
                .map(
                  (String value) => ActionChip(
                    label: Text(value),
                    onPressed: () {
                      controller.text = value;
                    },
                  ),
                )
                .toList(growable: false),
          ),
        ],
      ],
    );
  }

  String _prettyCategory(String category) {
    if (category.isEmpty) {
      return category;
    }
    return '${category[0].toUpperCase()}${category.substring(1)}';
  }
}
