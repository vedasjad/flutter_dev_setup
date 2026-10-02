import 'package:flutter/material.dart';

import '../controller.dart';
import '../models.dart';
import 'shape.dart';
import 'strings.dart';
import 'theme.dart';

sealed class NameDialogResult {
  const NameDialogResult();
}

/// An empty [label] clears the name.
final class RenameServer extends NameDialogResult {
  const RenameServer(this.label);
  final String label;
}

final class ForgetServer extends NameDialogResult {
  const ForgetServer();
}

Future<NameDialogResult?> showServerNameDialog(
  BuildContext context, {
  required DevServerEntry entry,
  required DevSetupTheme theme,
  required DevSetupStrings strings,
}) => showDialog<NameDialogResult>(
  context: context,
  builder: (_) =>
      _ServerNameDialog(entry: entry, theme: theme, strings: strings),
);

/// Returns what was typed, already checked for a scheme and a host.
Future<String?> showAddServerDialog(
  BuildContext context, {
  required String initial,
  required DevSetupTheme theme,
  required DevSetupStrings strings,
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      _AddServerDialog(initial: initial, theme: theme, strings: strings),
);

class _ServerNameDialog extends StatefulWidget {
  const _ServerNameDialog({
    required this.entry,
    required this.theme,
    required this.strings,
  });

  final DevServerEntry entry;
  final DevSetupTheme theme;
  final DevSetupStrings strings;

  @override
  State<_ServerNameDialog> createState() => _ServerNameDialogState();
}

class _ServerNameDialogState extends State<_ServerNameDialog> {
  // Owned here, not by the caller: popping completes the dialog's future while
  // the route is still animating out and the field is still listening, so
  // disposing on that future trips `_dependents.isEmpty`.
  late final TextEditingController _controller =
      TextEditingController(text: widget.entry.label ?? '')
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: (widget.entry.label ?? '').length,
        );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(RenameServer(_controller.text));

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final theme = widget.theme;
    final strings = widget.strings;
    final resolved = entry.server.hostname;
    final detail = entry.server.reachable
        ? '${entry.server.endpoint} · ${strings.latency(entry.server.latencyMs)}'
        : entry.server.endpoint;
    return _DialogShell(
      theme: theme,
      title: strings.nameServer,
      subtitle: detail,
      field: _DialogField(
        controller: _controller,
        theme: theme,
        hint: resolved == null ? strings.nameHint : prettyHostname(resolved),
        capitalization: TextCapitalization.words,
        onSubmitted: _save,
      ),
      help: Text(
        strings.nameHelp,
        style: TextStyle(fontSize: 11, color: theme.textTertiary),
      ),
      leading: entry.custom
          ? _DialogAction(
              label: strings.forget,
              color: theme.error,
              onPressed: () => Navigator.of(context).pop(const ForgetServer()),
            )
          : null,
      actions: [
        _DialogAction(
          label: strings.cancel,
          color: theme.textSecondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        _PrimaryAction(label: strings.save, theme: theme, onPressed: _save),
      ],
    );
  }
}

class _AddServerDialog extends StatefulWidget {
  const _AddServerDialog({
    required this.initial,
    required this.theme,
    required this.strings,
  });

  final String initial;
  final DevSetupTheme theme;
  final DevSetupStrings strings;

  @override
  State<_AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends State<_AddServerDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.initial.length,
        );
  final ValueNotifier<bool> _invalid = ValueNotifier(false);

  @override
  void dispose() {
    _controller.dispose();
    _invalid.dispose();
    super.dispose();
  }

  void _save() {
    final value = _controller.text.trim();
    if (!DevSetupController.isValidUrl(value)) {
      _invalid.value = true;
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final strings = widget.strings;
    return ValueListenableBuilder<bool>(
      valueListenable: _invalid,
      builder: (context, invalid, _) => _DialogShell(
        theme: theme,
        title: strings.addServerTitle,
        subtitle: strings.addServerBody,
        field: _DialogField(
          controller: _controller,
          theme: theme,
          hint: strings.addServerHint,
          keyboardType: TextInputType.url,
          borderColor: invalid ? theme.error : null,
          onChanged: () => _invalid.value = false,
          onSubmitted: _save,
        ),
        help: Text(
          invalid ? strings.addServerInvalid : strings.addServerHelp,
          style: TextStyle(
            fontSize: 11,
            color: invalid ? theme.error : theme.textTertiary,
          ),
        ),
        actions: [
          _DialogAction(
            label: strings.cancel,
            color: theme.textSecondary,
            onPressed: () => Navigator.of(context).pop(),
          ),
          _PrimaryAction(label: strings.save, theme: theme, onPressed: _save),
        ],
      ),
    );
  }
}

class _DialogShell extends StatelessWidget {
  const _DialogShell({
    required this.theme,
    required this.title,
    required this.subtitle,
    required this.field,
    required this.help,
    required this.actions,
    this.leading,
  });

  final DevSetupTheme theme;
  final String title;
  final String subtitle;
  final Widget field;
  final Widget help;
  final List<Widget> actions;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: theme.surface,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      shape: devShape(32),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: theme.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: theme.textSecondary),
            ),
            const SizedBox(height: 16),
            field,
            const SizedBox(height: 8),
            help,
            const SizedBox(height: 18),
            OverflowBar(
              alignment: leading == null
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.spaceBetween,
              overflowAlignment: OverflowBarAlignment.end,
              children: [
                ?leading,
                OverflowBar(
                  spacing: 8,
                  overflowAlignment: OverflowBarAlignment.end,
                  children: actions,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogField extends StatelessWidget {
  const _DialogField({
    required this.controller,
    required this.theme,
    required this.hint,
    required this.onSubmitted,
    this.capitalization = TextCapitalization.none,
    this.keyboardType,
    this.borderColor,
    this.onChanged,
  });

  final TextEditingController controller;
  final DevSetupTheme theme;
  final String hint;
  final VoidCallback onSubmitted;
  final TextCapitalization capitalization;
  final TextInputType? keyboardType;
  final Color? borderColor;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: ShapeDecoration(
        color: theme.surfaceMuted,
        shape: devShape(
          20,
          side: BorderSide(color: borderColor ?? theme.fieldBorder),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: TextField(
        controller: controller,
        autofocus: true,
        autocorrect: false,
        textCapitalization: capitalization,
        keyboardType: keyboardType,
        textInputAction: TextInputAction.done,
        cursorColor: theme.primary,
        style: theme.resolvedFieldTextStyle,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: theme.resolvedFieldTextStyle.copyWith(
            color: theme.textTertiary,
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
        onChanged: (_) => onChanged?.call(),
        onSubmitted: (_) => onSubmitted(),
      ),
    );
  }
}

class _DialogAction extends StatelessWidget {
  const _DialogAction({
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: devShape(14),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.label,
    required this.theme,
    required this.onPressed,
  });

  final String label;
  final DevSetupTheme theme;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: theme.primary,
        foregroundColor: theme.onPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        shape: devShape(16),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
    );
  }
}
