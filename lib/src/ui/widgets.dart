import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'shape.dart';
import 'theme.dart';

class DevPulseDot extends StatefulWidget {
  const DevPulseDot({super.key, required this.color, required this.animate});

  final Color color;
  final bool animate;

  @override
  State<DevPulseDot> createState() => _DevPulseDotState();
}

class _DevPulseDotState extends State<DevPulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(DevPulseDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate == oldWidget.animate) return;
    if (widget.animate) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.45 * _pulse.value),
              blurRadius: 8,
              spreadRadius: 3 * _pulse.value,
            ),
          ],
        ),
      ),
    );
  }
}

class DevSegment extends StatelessWidget {
  const DevSegment({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.theme,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final bool active;
  final bool busy;
  final DevSetupTheme theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? theme.onPrimary : theme.textSecondary;
    return Semantics(
      button: true,
      selected: active,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              else
                Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DevFieldLabel extends StatelessWidget {
  const DevFieldLabel({
    super.key,
    required this.icon,
    required this.text,
    required this.theme,
  });

  final IconData icon;
  final String text;
  final DevSetupTheme theme;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: theme.textTertiary),
        const SizedBox(width: 6),
        Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: theme.textTertiary,
          ),
        ),
      ],
    );
  }
}

class DevField extends StatelessWidget {
  const DevField({
    super.key,
    required this.controller,
    required this.hint,
    required this.theme,
    this.onChanged,
    this.onSubmitted,
    this.keyboardType,
    this.textInputAction,
    this.trailing,
  });

  final TextEditingController controller;
  final String hint;
  final DevSetupTheme theme;
  final VoidCallback? onChanged;
  final VoidCallback? onSubmitted;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final style = devFieldStyle(context, theme);
    return Container(
      decoration: ShapeDecoration(
        color: theme.surfaceMuted,
        shape: devShape(20, side: BorderSide(color: theme.fieldBorder)),
      ),
      padding: EdgeInsets.only(left: 14, right: trailing == null ? 14 : 2),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              autocorrect: false,
              keyboardType: keyboardType,
              textInputAction: textInputAction,
              cursorColor: theme.primary,
              style: style,
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: style.copyWith(color: theme.textTertiary),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onChanged: (_) => onChanged?.call(),
              onSubmitted: (_) => onSubmitted?.call(),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

TextStyle devFieldStyle(BuildContext context, DevSetupTheme theme) =>
    (Theme.of(context).textTheme.bodyLarge ?? const TextStyle()).merge(
      theme.resolvedFieldTextStyle,
    );

class DevChip extends StatelessWidget {
  const DevChip({
    super.key,
    required this.text,
    required this.color,
    required this.background,
    required this.ink,
  });

  final String text;
  final Color color;

  /// What the chip sits on, for working out a readable text colour.
  final Color background;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final tint = color.withValues(alpha: 0.12);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: ShapeDecoration(color: tint, shape: devShape(8)),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: legibleColor(color, Color.alphaBlend(tint, background), ink),
        ),
      ),
    );
  }
}

/// [tone] pulled toward [ink] just far enough for small text to reach WCAG
/// AA (4.5:1) on [background]; a status colour such as amber fails it alone.
Color legibleColor(Color tone, Color background, Color ink) {
  for (var step = 0; step < 10; step++) {
    final color = Color.lerp(tone, ink, step / 10)!;
    if (_contrast(color, background) >= 4.5) return color;
  }
  return ink;
}

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}
