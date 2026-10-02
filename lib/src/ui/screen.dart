import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller.dart';
import '../discovery_config.dart';
import '../models.dart';
import '../store.dart';
import 'dialogs.dart';
import 'shape.dart';
import 'strings.dart';
import 'theme.dart';

/// Lets a developer pick which server the app talks to: the default, one found
/// on the local network, or one saved by hand.
class DevSetupScreen extends StatefulWidget {
  const DevSetupScreen({
    super.key,
    required this.defaultBaseUrl,
    required this.onBaseUrlChanged,
    required this.onProceed,
    this.defaultSuffix = '/api/v1/',
    this.discovery = const DiscoveryConfig(),
    this.theme = const DevSetupTheme(),
    this.strings = const DevSetupStrings(),
    this.store,
    this.enableDiscovery = true,
    this.controller,
  });

  /// Full URL, suffix included — what Default and Reset return to.
  final String defaultBaseUrl;
  final String defaultSuffix;

  /// Called with the full URL whenever a choice is committed.
  final void Function(String url) onBaseUrlChanged;

  /// Called after Proceed commits the current URL. Navigate onward from here.
  final void Function(BuildContext context) onProceed;
  final DiscoveryConfig discovery;
  final DevSetupTheme theme;
  final DevSetupStrings strings;
  final DevSetupStore? store;

  /// When false the screen never scans; saved servers still work.
  final bool enableDiscovery;

  /// Supply one to drive the screen yourself — the caller then owns `init`.
  final DevSetupController? controller;

  @override
  State<DevSetupScreen> createState() => _DevSetupScreenState();
}

class _DevSetupScreenState extends State<DevSetupScreen>
    with WidgetsBindingObserver {
  late DevSetupController _controller;
  late bool _ownsController;
  bool _proceeding = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attach();
  }

  void _attach() {
    final external = widget.controller;
    _ownsController = external == null;
    _controller =
        external ??
        DevSetupController(
          defaultBaseUrl: widget.defaultBaseUrl,
          defaultSuffix: widget.defaultSuffix,
          onBaseUrlChanged: (url) => widget.onBaseUrlChanged(url),
          config: widget.discovery,
          store: widget.store,
          enableDiscovery: widget.enableDiscovery,
        );
    if (_ownsController) unawaited(_controller.init());
  }

  @override
  void didUpdateWidget(DevSetupScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller == oldWidget.controller) return;
    if (_ownsController) _controller.dispose();
    _attach();
    _syncPinging();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPinging();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _syncPinging();

  /// Health checks only run while the screen can be seen: not under another
  /// route, and not with the app in the background.
  void _syncPinging() {
    final covered = !(ModalRoute.isCurrentOf(context) ?? true);
    final hidden = switch (WidgetsBinding.instance.lifecycleState) {
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => true,
      _ => false,
    };
    if (covered || hidden) {
      _controller.pausePinging();
    } else {
      _controller.resumePinging();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  DevSetupTheme get _theme => widget.theme;
  DevSetupStrings get _strings => widget.strings;

  Future<void> _proceed() async {
    if (_proceeding) return;
    _proceeding = true;
    try {
      await _proceedOnce();
    } finally {
      _proceeding = false;
    }
  }

  Future<void> _proceedOnce() async {
    if (!_controller.isValid) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_strings.invalidUrlTitle),
          content: Text(_strings.invalidUrlBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(_strings.ok),
            ),
          ],
        ),
      );
      return;
    }
    await _controller.commit();
    if (mounted) widget.onProceed(context);
  }

  Future<void> _copy() async {
    final url = _controller.fullUrl;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(_strings.copied(url)),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _rename(DevServerEntry entry) async {
    final result = await showServerNameDialog(
      context,
      entry: entry,
      theme: _theme,
      strings: _strings,
    );
    switch (result) {
      case RenameServer(:final label):
        await _controller.rename(entry, label);
      case ForgetServer():
        await _controller.forget(entry);
      case null:
        break;
    }
  }

  Future<void> _add() async {
    final origin = await showAddServerDialog(
      context,
      initial: _controller.baseOrigin,
      theme: _theme,
      strings: _strings,
    );
    if (origin != null) await _controller.addCustom(origin);
  }

  String? _scanStatus() {
    final c = _controller;
    return switch (c.scanPhase) {
      ScanPhase.idle => null,
      ScanPhase.running =>
        c.scanTotal == 0
            ? _strings.lookingForServer
            : _strings.scanning(c.scanLabel, c.scanProbed, c.scanTotal),
      ScanPhase.found => _strings.foundServers(c.foundCount, c.scanLabel),
      ScanPhase.nothingFound => _strings.nothingFound(c.scanLabel),
      ScanPhase.noNetwork => _strings.noNetwork,
      ScanPhase.cancelled => _strings.scanCancelled,
      ScanPhase.failed => _strings.scanFailed,
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        final status = _scanStatus();
        return Scaffold(
          backgroundColor: _theme.background,
          appBar: AppBar(
            backgroundColor: _theme.background,
            foregroundColor: _theme.textPrimary,
            surfaceTintColor: _theme.background,
            elevation: 0,
            titleSpacing: 24,
            title: Text(
              _strings.title,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: _theme.textPrimary,
              ),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
            children: [
              _StatusHero(
                settled: c.settledStatus,
                checking: c.pingStatus == PingStatus.checking,
                url: c.fullUrl,
                theme: _theme,
                strings: _strings,
                onCopy: _copy,
              ),
              const SizedBox(height: 12),
              _SourceSwitch(
                urlMode: c.urlMode,
                scanning: c.isManualScan,
                showLocal: c.enableDiscovery,
                theme: _theme,
                strings: _strings,
                onLocal: c.toggleScan,
                onDefault: c.resetToDefault,
              ),
              const SizedBox(height: 12),
              _EndpointCard(
                controller: c,
                theme: _theme,
                strings: _strings,
                onSubmitted: c.canProceed ? _proceed : null,
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _strings.serversTitle,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: _theme.textPrimary,
                      ),
                    ),
                  ),
                  if (c.enableDiscovery && !c.isScanning)
                    IconButton(
                      onPressed: () => c.scan(),
                      tooltip: _strings.scanAgain,
                      icon: Icon(Icons.refresh_rounded, color: _theme.primary),
                    ),
                  IconButton(
                    onPressed: _add,
                    tooltip: _strings.addAddress,
                    icon: Icon(Icons.add_rounded, color: _theme.primary),
                  ),
                ],
              ),
              if (c.isScanning) ...[
                const SizedBox(height: 4),
                ClipPath(
                  clipper: ShapeBorderClipper(shape: devShape(2)),
                  child: LinearProgressIndicator(
                    value: c.scanProgress,
                    minHeight: 4,
                    backgroundColor: _theme.track,
                    valueColor: AlwaysStoppedAnimation(_theme.primary),
                  ),
                ),
              ],
              if (status != null) ...[
                const SizedBox(height: 6),
                Text(
                  status,
                  style: TextStyle(fontSize: 12, color: _theme.textSecondary),
                ),
              ],
              const SizedBox(height: 10),
              if (c.hasServers)
                for (final entry in c.servers)
                  _ServerTile(
                    entry: entry,
                    selected: c.isSelected(entry),
                    theme: _theme,
                    strings: _strings,
                    onTap: () => c.select(entry),
                    onPin: () => c.togglePin(entry),
                    onRename: () => _rename(entry),
                  )
              else if (c.scanPhase == ScanPhase.nothingFound)
                _EmptyServers(
                  theme: _theme,
                  strings: _strings,
                  onRetry: () => c.scan(),
                )
              else if (c.enableDiscovery && !c.isScanning)
                Text(
                  _strings.scanHint,
                  style: TextStyle(fontSize: 12, color: _theme.textTertiary),
                ),
            ],
          ),
          bottomNavigationBar: _BottomBar(
            theme: _theme,
            strings: _strings,
            canProceed: c.canProceed,
            onReset: c.resetToDefault,
            onProceed: _proceed,
          ),
        );
      },
    );
  }
}

class _StatusHero extends StatelessWidget {
  const _StatusHero({
    required this.settled,
    required this.checking,
    required this.url,
    required this.theme,
    required this.strings,
    required this.onCopy,
  });

  /// Drives the surface and the words — deliberately not the live status, so
  /// a routine re-check only changes the dot.
  final PingStatus settled;
  final bool checking;
  final String url;
  final DevSetupTheme theme;
  final DevSetupStrings strings;
  final VoidCallback onCopy;

  Color get _accent => switch (settled) {
    PingStatus.online => theme.success,
    PingStatus.offline => theme.error,
    _ => theme.idle,
  };

  String get _headline => switch (settled) {
    PingStatus.online => strings.headlineOnline,
    PingStatus.offline => strings.headlineOffline,
    _ => checking ? strings.headlineChecking : strings.headlineIdle,
  };

  String get _caption => switch (settled) {
    PingStatus.online => strings.captionOnline,
    PingStatus.offline => strings.captionOffline,
    _ => checking ? strings.captionChecking : strings.captionIdle,
  };

  @override
  Widget build(BuildContext context) {
    final shape = devShape(
      36,
      side: BorderSide(color: _accent.withValues(alpha: 0.28)),
    );
    return Tooltip(
      message: strings.copyUrl,
      child: Semantics(
        button: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onCopy,
            customBorder: shape,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: ShapeDecoration(
                color: _accent.withValues(alpha: 0.07),
                shape: shape,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _PulseDot(
                        color: checking ? theme.warning : _accent,
                        animate: checking,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _headline,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: _legible(
                              _accent,
                              Color.alphaBlend(
                                _accent.withValues(alpha: 0.07),
                                theme.background,
                              ),
                              theme.textPrimary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.copy_rounded,
                        size: 16,
                        color: theme.textTertiary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    url,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      color: theme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _caption,
                    style: TextStyle(fontSize: 12, color: theme.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.color, required this.animate});

  final Color color;
  final bool animate;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
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
  void didUpdateWidget(_PulseDot oldWidget) {
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

class _SourceSwitch extends StatelessWidget {
  const _SourceSwitch({
    required this.urlMode,
    required this.scanning,
    required this.showLocal,
    required this.theme,
    required this.strings,
    required this.onLocal,
    required this.onDefault,
  });

  final bool? urlMode;
  final bool scanning;
  final bool showLocal;
  final DevSetupTheme theme;
  final DevSetupStrings strings;
  final VoidCallback onLocal;
  final VoidCallback onDefault;

  @override
  Widget build(BuildContext context) {
    final localSelected = urlMode == true;
    final segments = [
      if (showLocal)
        _Segment(
          icon: Icons.wifi_rounded,
          label: scanning ? strings.cancel : strings.localIp,
          busy: scanning,
          active: localSelected,
          theme: theme,
          onTap: onLocal,
        ),
      _Segment(
        icon: Icons.restore_rounded,
        label: strings.useDefault,
        active: urlMode == false,
        theme: theme,
        onTap: onDefault,
      ),
    ];
    final thumbVisible = showLocal ? urlMode != null : urlMode == false;
    return Container(
      height: 56,
      padding: const EdgeInsets.all(3),
      decoration: ShapeDecoration(
        color: theme.track,
        shape: devShape(22, side: BorderSide(color: theme.border)),
      ),
      child: Stack(
        children: [
          AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: thumbVisible ? 1 : 0,
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: localSelected && showLocal
                  ? AlignmentDirectional.centerStart
                  : AlignmentDirectional.centerEnd,
              child: FractionallySizedBox(
                widthFactor: 1 / segments.length,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: theme.primary,
                    shape: devShape(18),
                  ),
                ),
              ),
            ),
          ),
          Row(children: [for (final s in segments) Expanded(child: s)]),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
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

class _EndpointCard extends StatelessWidget {
  const _EndpointCard({
    required this.controller,
    required this.theme,
    required this.strings,
    required this.onSubmitted,
  });

  final DevSetupController controller;
  final DevSetupTheme theme;
  final DevSetupStrings strings;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: theme.surface,
        shape: devShape(52, side: BorderSide(color: theme.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FieldLabel(
            icon: Icons.dns_outlined,
            text: strings.baseUrl,
            theme: theme,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _SchemePicker(
                value: controller.scheme,
                theme: theme,
                onChanged: controller.setScheme,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Field(
                  controller: controller.urlController,
                  hint: strings.baseUrlHint,
                  theme: theme,
                  keyboardType: TextInputType.url,
                  onChanged: controller.onUrlEdited,
                  onSubmitted: onSubmitted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _FieldLabel(
            icon: Icons.alt_route_rounded,
            text: strings.apiSuffix,
            theme: theme,
          ),
          const SizedBox(height: 8),
          _Field(
            controller: controller.suffixController,
            hint: strings.suffixHint,
            theme: theme,
            onChanged: controller.onUrlEdited,
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({
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

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    required this.theme,
    required this.onChanged,
    this.onSubmitted,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String hint;
  final DevSetupTheme theme;
  final VoidCallback onChanged;
  final VoidCallback? onSubmitted;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final style = _fieldStyle(context, theme);
    return Container(
      decoration: ShapeDecoration(
        color: theme.surfaceMuted,
        shape: devShape(20, side: BorderSide(color: theme.fieldBorder)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: TextField(
        controller: controller,
        autocorrect: false,
        keyboardType: keyboardType,
        cursorColor: theme.primary,
        style: style,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: style.copyWith(color: theme.textTertiary),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
        onChanged: (_) => onChanged(),
        onSubmitted: (_) => onSubmitted?.call(),
      ),
    );
  }
}

TextStyle _fieldStyle(BuildContext context, DevSetupTheme theme) =>
    (Theme.of(context).textTheme.bodyLarge ?? const TextStyle()).merge(
      theme.resolvedFieldTextStyle,
    );

class _SchemePicker extends StatelessWidget {
  const _SchemePicker({
    required this.value,
    required this.theme,
    required this.onChanged,
  });

  final String value;
  final DevSetupTheme theme;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final style = _fieldStyle(context, theme);
    return Container(
      // A 48dp tap target inside the 1px border.
      height: kMinInteractiveDimension + 2,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: ShapeDecoration(
        color: theme.surfaceMuted,
        shape: devShape(20, side: BorderSide(color: theme.fieldBorder)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          onChanged: onChanged,
          isDense: true,
          borderRadius: BorderRadius.circular(14),
          dropdownColor: theme.surface,
          icon: Icon(
            Icons.expand_more_rounded,
            size: 18,
            color: theme.textTertiary,
          ),
          style: style,
          selectedItemBuilder: (context) => [
            for (final option in DevSetupController.schemes)
              Align(
                alignment: Alignment.centerLeft,
                child: Text('$option://', style: style),
              ),
          ],
          items: [
            for (final option in DevSetupController.schemes)
              DropdownMenuItem(
                value: option,
                child: Text('$option://', style: style),
              ),
          ],
        ),
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.entry,
    required this.selected,
    required this.theme,
    required this.strings,
    required this.onTap,
    required this.onPin,
    required this.onRename,
  });

  final DevServerEntry entry;
  final bool selected;
  final DevSetupTheme theme;
  final DevSetupStrings strings;
  final VoidCallback onTap;
  final VoidCallback onPin;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final named = entry.isNamed;
    final server = entry.server;
    final shape = devShape(
      24,
      side: BorderSide(color: selected ? theme.primary : theme.border),
    );
    final background = selected
        ? Color.alphaBlend(theme.primaryTint, theme.background)
        : theme.surface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? theme.primaryTint : theme.surface,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              child: Row(
                children: [
                  _ServerAvatar(entry: entry, selected: selected, theme: theme),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                named ? entry.displayName : server.endpoint,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: theme.textPrimary,
                                ),
                              ),
                            ),
                            if (entry.pinned) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.push_pin_rounded,
                                size: 13,
                                color: theme.primary,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            if (named) ...[
                              Flexible(
                                child: Text(
                                  server.endpoint,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: theme.textSecondary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            if (server.reachable)
                              _Chip(
                                text: strings.latency(server.latencyMs),
                                color: _latencyTone(server.latencyMs),
                                background: background,
                                ink: theme.textPrimary,
                              )
                            else
                              _Chip(
                                text: strings.saved,
                                color: theme.idle,
                                background: background,
                                ink: theme.textPrimary,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: onPin,
                    tooltip: entry.pinned ? strings.unpin : strings.pin,
                    icon: Icon(
                      entry.pinned
                          ? Icons.push_pin_rounded
                          : Icons.push_pin_outlined,
                      size: 18,
                      color: entry.pinned ? theme.primary : theme.textTertiary,
                    ),
                  ),
                  IconButton(
                    onPressed: onRename,
                    tooltip: strings.nameServer,
                    icon: Icon(
                      Icons.drive_file_rename_outline_rounded,
                      size: 18,
                      color: theme.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _latencyTone(int ms) {
    if (ms <= 60) return theme.success;
    if (ms <= 250) return theme.warning;
    return theme.idle;
  }
}

class _ServerAvatar extends StatelessWidget {
  const _ServerAvatar({
    required this.entry,
    required this.selected,
    required this.theme,
  });

  final DevServerEntry entry;
  final bool selected;
  final DevSetupTheme theme;

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (selected) {
      child = Icon(Icons.check_rounded, size: 20, color: theme.onPrimary);
    } else if (entry.isNamed) {
      child = Text(
        entry.displayName.characters.first.toUpperCase(),
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: theme.textSecondary,
        ),
      );
    } else {
      child = Icon(Icons.dns_rounded, size: 18, color: theme.textTertiary);
    }
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: selected ? theme.primary : theme.track,
        shape: devShape(14),
      ),
      child: child,
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
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
          color: _legible(color, Color.alphaBlend(tint, background), ink),
        ),
      ),
    );
  }
}

/// [tone] pulled toward [ink] just far enough for small text to reach WCAG
/// AA (4.5:1) on [background]; a status colour such as amber fails it alone.
Color _legible(Color tone, Color background, Color ink) {
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

class _EmptyServers extends StatelessWidget {
  const _EmptyServers({
    required this.theme,
    required this.strings,
    required this.onRetry,
  });

  final DevSetupTheme theme;
  final DevSetupStrings strings;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: ShapeDecoration(
        color: theme.surface,
        shape: devShape(48, side: BorderSide(color: theme.border)),
      ),
      child: Column(
        children: [
          Icon(Icons.wifi_find_rounded, size: 32, color: theme.textTertiary),
          const SizedBox(height: 10),
          Text(
            strings.emptyTitle,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: theme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            strings.emptyBody,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: theme.textSecondary),
          ),
          const SizedBox(height: 14),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              backgroundColor: theme.primaryTint,
              foregroundColor: theme.primary,
              shape: devShape(14),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            ),
            child: Text(
              strings.scanAgain,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.theme,
    required this.strings,
    required this.canProceed,
    required this.onReset,
    required this.onProceed,
  });

  final DevSetupTheme theme;
  final DevSetupStrings strings;
  final bool canProceed;
  final VoidCallback onReset;
  final VoidCallback onProceed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        24,
        12,
        24,
        MediaQuery.paddingOf(context).bottom + 16,
      ),
      decoration: BoxDecoration(
        color: theme.background,
        border: Border(top: BorderSide(color: theme.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: onReset,
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: theme.surface,
                foregroundColor: theme.primary,
                shape: devShape(20, side: BorderSide(color: theme.primary)),
              ),
              child: Text(strings.reset, style: const TextStyle(fontSize: 15)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: TextButton(
              onPressed: canProceed ? onProceed : null,
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: canProceed ? theme.primary : theme.border,
                foregroundColor: theme.onPrimary,
                disabledForegroundColor: theme.textTertiary,
                shape: devShape(20),
              ),
              child: Text(
                strings.proceed,
                style: const TextStyle(fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
