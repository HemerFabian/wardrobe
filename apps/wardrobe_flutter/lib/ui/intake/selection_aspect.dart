double normalizedSelectionAspectRatio({
  required double viewportAspectRatio,
  required double imageAspectRatio,
}) {
  final safeViewportAspectRatio = viewportAspectRatio > 0
      ? viewportAspectRatio
      : 1.0;
  final safeImageAspectRatio = imageAspectRatio > 0 ? imageAspectRatio : 1.0;
  return (safeViewportAspectRatio / safeImageAspectRatio)
      .clamp(0.02, 50.0)
      .toDouble();
}
