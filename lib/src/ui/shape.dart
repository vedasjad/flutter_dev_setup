import 'package:flutter/material.dart';

/// Continuous corners cut about half as deep as circular ones at the same
/// radius, so radii here run larger than their rounded-rect equivalents — but
/// past half the element's own height the path self-intersects and grows tabs
/// out of the sides. Every call site sets its radius against what it wraps.
ContinuousRectangleBorder devShape(
  double radius, {
  BorderSide side = BorderSide.none,
}) => ContinuousRectangleBorder(
  borderRadius: BorderRadius.circular(radius),
  side: side,
);
