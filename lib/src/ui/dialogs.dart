import 'package:flutter/material.dart';

import '../controller.dart';
import '../discovery_config.dart';
import '../models.dart';
import 'location_strings.dart';
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

/// Returns the ports typed, or an empty list to go back to [defaults].
Future<List<int>?> showScanPortsDialog(
  BuildContext context, {
  required List<int> ports,
  required List<int> defaults,
  required DevSetupTheme theme,
  required DevSetupStrings strings,
}) => showDialog<List<int>>(
  context: context,
  builder: (_) => _ValueDialog<List<int>>(
    theme: theme,
    title: strings.scanPorts,
    subtitle: strings.scanPortsBody,
    initial: ports.join(', '),
    hint: strings.scanPortsHint,
    help: strings.scanPortsHelp(defaults),
    invalid: strings.scanPortsInvalid,
    save: strings.save,
    cancel: strings.cancel,
    parse: DiscoveryConfig.parsePorts,
  ),
);

sealed class PlaceNameResult {
  const PlaceNameResult();
}

final class NamePlace extends PlaceNameResult {
  const NamePlace(this.name);
  final String name;
}

final class ForgetPlace extends PlaceNameResult {
  const ForgetPlace();
}

/// Names a place, or forgets it when [canForget] offers that.
Future<PlaceNameResult?> showPlaceNameDialog(
  BuildContext context, {
  required String initial,
  required String subtitle,
  required bool canForget,
  required DevSetupTheme theme,
  required MockLocationStrings strings,
}) => showDialog<PlaceNameResult>(
  context: context,
  builder: (_) => _ValueDialog<PlaceNameResult>(
    theme: theme,
    title: strings.placeNameTitle,
    subtitle: subtitle,
    initial: initial,
    hint: strings.placeNameHint,
    help: strings.placeNameHelp,
    invalid: strings.placeNameHelp,
    save: strings.save,
    cancel: strings.cancel,
    capitalization: TextCapitalization.words,
    parse: (text) => text.trim().isEmpty ? null : NamePlace(text.trim()),
    leading: canForget
        ? (context) => _DialogAction(
            label: strings.forget,
            color: theme.error,
            onPressed: () => Navigator.of(context).pop(const ForgetPlace()),
          )
        : null,
  ),
);

/// Returns the pasted text once [accepts] takes it.
Future<String?> showPasteRouteDialog(
  BuildContext context, {
  required bool Function(String text) accepts,
  required DevSetupTheme theme,
  required MockLocationStrings strings,
}) => showDialog<String>(
  context: context,
  builder: (_) => _ValueDialog<String>(
    theme: theme,
    title: strings.pasteRoute,
    subtitle: strings.pasteRouteBody,
    initial: '',
    hint: strings.pasteRouteHint,
    help: strings.pasteRouteHelp,
    invalid: strings.pasteRouteInvalid,
    save: strings.save,
    cancel: strings.cancel,
    maxLines: 6,
    parse: (text) => accepts(text) ? text : null,
  ),
);

/// A speed in km/h above zero.
Future<double?> showSpeedDialog(
  BuildContext context, {
  required String initial,
  required DevSetupTheme theme,
  required MockLocationStrings strings,
}) => showDialog<double>(
  context: context,
  builder: (_) => _ValueDialog<double>(
    theme: theme,
    title: strings.speedTitle,
    subtitle: strings.speedBody,
    initial: initial,
    hint: strings.speedHint,
    help: strings.speedHelp,
    invalid: strings.speedInvalid,
    save: strings.save,
    cancel: strings.cancel,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    parse: (text) {
      final kmh = double.tryParse(text.trim().replaceAll(',', '.'));
      return kmh != null && kmh.isFinite && kmh > 0 && kmh <= 1000 ? kmh : null;
    },
  ),
);

class _ValueDialog<T> extends StatefulWidget {
  const _ValueDialog({
    required this.theme,
    required this.title,
    required this.subtitle,
    required this.initial,
    required this.hint,
    required this.help,
    required this.invalid,
    required this.save,
    required this.cancel,
    required this.parse,
    this.keyboardType,
    this.capitalization = TextCapitalization.none,
    this.maxLines = 1,
    this.leading,
  });

  final DevSetupTheme theme;
  final String title;
  final String subtitle;
  final String initial;
  final String hint;
  final String help;
  final String invalid;
  final String save;
  final String cancel;

  /// Null when the text cannot be saved.
  final T? Function(String text) parse;
  final TextInputType? keyboardType;
  final TextCapitalization capitalization;
  final int maxLines;
  final Widget Function(BuildContext context)? leading;

  @override
  State<_ValueDialog<T>> createState() => _ValueDialogState<T>();
}

class _ValueDialogState<T> extends State<_ValueDialog<T>> {
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
    final value = widget.parse(_controller.text);
    if (value == null) {
      _invalid.value = true;
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return ValueListenableBuilder<bool>(
      valueListenable: _invalid,
      builder: (context, invalid, _) => _DialogShell(
        theme: theme,
        title: widget.title,
        subtitle: widget.subtitle,
        field: _DialogField(
          controller: _controller,
          theme: theme,
          hint: widget.hint,
          keyboardType: widget.keyboardType,
          capitalization: widget.capitalization,
          maxLines: widget.maxLines,
          borderColor: invalid ? theme.error : null,
          onChanged: () => _invalid.value = false,
          onSubmitted: _save,
        ),
        help: Text(
          invalid ? widget.invalid : widget.help,
          style: TextStyle(
            fontSize: 11,
            color: invalid ? theme.error : theme.textTertiary,
          ),
        ),
        leading: widget.leading?.call(context),
        actions: [
          _DialogAction(
            label: widget.cancel,
            color: theme.textSecondary,
            onPressed: () => Navigator.of(context).pop(),
          ),
          _PrimaryAction(label: widget.save, theme: theme, onPressed: _save),
        ],
      ),
    );
  }
}

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
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final DevSetupTheme theme;
  final String hint;
  final VoidCallback onSubmitted;
  final TextCapitalization capitalization;
  final TextInputType? keyboardType;
  final Color? borderColor;
  final VoidCallback? onChanged;
  final int maxLines;

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
        keyboardType: maxLines > 1 ? TextInputType.multiline : keyboardType,
        maxLines: maxLines,
        minLines: 1,
        textInputAction: maxLines > 1
            ? TextInputAction.newline
            : TextInputAction.done,
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
