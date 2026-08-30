import 'package:flutter/material.dart';

class PoseSelector extends StatelessWidget {
  const PoseSelector({
    super.key,
    required this.poseIds,
    required this.selectedPoseId,
    required this.onSelected,
    this.poseLabelsById = const <String, String>{},
    this.scrollable = false,
    this.compact = false,
  });

  final List<String> poseIds;
  final String selectedPoseId;
  final ValueChanged<String> onSelected;
  final Map<String, String> poseLabelsById;
  final bool scrollable;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final chips = poseIds
        .map((String poseId) {
          final selected = poseId == selectedPoseId;
          return ChoiceChip(
            label: Text(poseLabelsById[poseId] ?? poseId),
            selected: selected,
            showCheckmark: false,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: compact
                ? const VisualDensity(horizontal: -1, vertical: -2)
                : null,
            onSelected: (_) => onSelected(poseId),
          );
        })
        .toList(growable: false);

    if (scrollable) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            for (int index = 0; index < chips.length; index++) ...<Widget>[
              if (index > 0) const SizedBox(width: 8),
              chips[index],
            ],
          ],
        ),
      );
    }

    return Wrap(spacing: 8, runSpacing: 8, children: chips);
  }
}
