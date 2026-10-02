import 'package:flutter/material.dart';

/// Colours and text for the screen. Pass your app's tokens to blend it in.
class DevSetupTheme {
  const DevSetupTheme({
    this.primary = const Color(0xFF4F46E5),
    this.onPrimary = Colors.white,
    this.background = const Color(0xFFF8F8FB),
    this.surface = Colors.white,
    this.surfaceMuted = const Color(0xFFFAFAFA),
    this.border = const Color(0xFFE2E8F0),
    this.fieldBorder = const Color(0xFFE5E7EB),
    this.track = const Color(0xFFF3F4F6),
    this.textPrimary = const Color(0xFF111827),
    this.textSecondary = const Color(0xFF666666),
    this.textTertiary = const Color(0xFF6B7280),
    this.idle = const Color(0xFF868E96),
    this.success = const Color(0xFF1CA672),
    this.warning = const Color(0xFFFFC107),
    this.error = const Color(0xFFB6183A),
    this.fieldTextStyle,
  });

  final Color primary;
  final Color onPrimary;
  final Color background;
  final Color surface;
  final Color surfaceMuted;
  final Color border;
  final Color fieldBorder;
  final Color track;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color idle;
  final Color success;
  final Color warning;
  final Color error;

  /// Shared by the URL field and the scheme picker, both of which get it
  /// merged over the app's bodyLarge: a TextField does that merge itself but a
  /// DropdownButton uses its style as given, which rendered the two neighbours
  /// in two different fonts.
  final TextStyle? fieldTextStyle;

  Color get primaryTint => primary.withValues(alpha: 0.08);

  TextStyle get resolvedFieldTextStyle =>
      fieldTextStyle ??
      TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        height: 1.2,
        color: textPrimary,
      );
}
