import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../geo.dart';
import '../location_controller.dart';
import '../location_services.dart';
import '../mock_location.dart';
import 'dialogs.dart';
import 'location_strings.dart';
import 'shape.dart';
import 'theme.dart';
import 'widgets.dart';

/// Lets a developer choose what the app sees as the device's location: the
/// real one, a fixed point, or a route played back at a set speed. Changes
/// apply at once; the app picks them up through [MockLocation].
class MockLocationScreen extends StatefulWidget {
  const MockLocationScreen({
    super.key,
    this.config = const MockLocationConfig(),
    this.theme = const DevSetupTheme(),
    this.strings = const MockLocationStrings(),
    this.controller,
  });

  final MockLocationConfig config;
  final DevSetupTheme theme;
  final MockLocationStrings strings;

  /// Supply one to share it — the caller then owns `init`.
  final MockLocationController? controller;

  @override
  State<MockLocationScreen> createState() => _MockLocationScreenState();
}

class _MockLocationScreenState extends State<MockLocationScreen> {
  late MockLocationController _controller;
  late bool _ownsController;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    final external = widget.controller;
    _ownsController = external == null;
    _controller = external ?? MockLocationController(config: widget.config);
    if (_ownsController) unawaited(_controller.init());
  }

  @override
  void didUpdateWidget(MockLocationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller == oldWidget.controller) return;
    if (_ownsController) _controller.dispose();
    _attach();
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  DevSetupTheme get _theme => widget.theme;
  MockLocationStrings get _strings => widget.strings;

  Future<void> _copy(MockPoint point) async {
    final text = point.format();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(_strings.copied(text)),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _savePoint() async {
    final state = _controller.state;
    final point = state.point;
    if (point == null) return;
    final result = await showPlaceNameDialog(
      context,
      initial: state.pointName ?? '',
      subtitle: point.format(),
      canForget: false,
      theme: _theme,
      strings: _strings,
    );
    if (result case NamePlace(:final name)) {
      await _controller.savePlace(name);
    }
  }

  Future<void> _saveResult(PlaceResult place) async {
    final result = await showPlaceNameDialog(
      context,
      initial: place.name,
      subtitle: place.detail ?? place.point?.format() ?? '',
      canForget: false,
      theme: _theme,
      strings: _strings,
    );
    if (result case NamePlace(:final name)) {
      await _controller.saveResult(name, place);
    }
  }

  Future<void> _editPlace(MockPlace place) async {
    final result = await showPlaceNameDialog(
      context,
      initial: place.name,
      subtitle: place.point.format(),
      canForget: true,
      theme: _theme,
      strings: _strings,
    );
    switch (result) {
      case NamePlace(:final name):
        await _controller.renamePlace(place, name);
      case ForgetPlace():
        await _controller.forgetPlace(place);
      case null:
        break;
    }
  }

  Future<void> _openMaps(MapsApp app) async {
    if (!await _controller.openMaps(app)) _tell(_strings.mapsFailed);
  }

  Future<void> _pasteLink() async {
    if (!await _controller.pasteLink()) _tell(_strings.clipboardEmpty);
  }

  void _tell(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _pasteRoute() async {
    final text = await showPasteRouteDialog(
      context,
      accepts: (text) => routePoints(text).length >= 2,
      theme: _theme,
      strings: _strings,
    );
    if (text != null) await _controller.pasteRoute(text);
  }

  Future<void> _customSpeed() async {
    final speed = await showSpeedDialog(
      context,
      initial: _strings.speedValue(_controller.state.speedKmh).split(' ').first,
      theme: _theme,
      strings: _strings,
    );
    if (speed != null) await _controller.setSpeed(speed);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        final state = c.state;
        final mode = state.mode;
        return Scaffold(
          backgroundColor: _theme.background,
          appBar: AppBar(
            backgroundColor: _theme.background,
            foregroundColor: _theme.textPrimary,
            iconTheme: IconThemeData(color: _theme.textPrimary),
            surfaceTintColor: _theme.background,
            elevation: 0,
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
            padding: EdgeInsets.fromLTRB(
              24,
              4,
              24,
              MediaQuery.paddingOf(context).bottom + 24,
            ),
            children: [
              _LocationHero(
                controller: c,
                theme: _theme,
                strings: _strings,
                onCopy: _copy,
                onSave:
                    mode == MockMode.point &&
                        state.point != null &&
                        !c.isSaved(state.point!)
                    ? _savePoint
                    : null,
              ),
              const SizedBox(height: 12),
              _Segmented<MockMode>(
                value: mode,
                theme: _theme,
                onChanged: c.setMode,
                options: [
                  (MockMode.off, Icons.gps_fixed_rounded, _strings.modeOff),
                  (
                    MockMode.point,
                    Icons.location_on_rounded,
                    _strings.modePoint,
                  ),
                  (MockMode.route, Icons.route_rounded, _strings.modeRoute),
                ],
              ),
              if (mode == MockMode.route && state.route != null) ...[
                const SizedBox(height: 12),
                _PlaybackCard(
                  controller: c,
                  theme: _theme,
                  strings: _strings,
                  onCustomSpeed: _customSpeed,
                ),
              ],
              if (mode != MockMode.off) ...[
                const SizedBox(height: 12),
                _SearchCard(
                  controller: c,
                  theme: _theme,
                  strings: _strings,
                  onSave: _saveResult,
                  onOpenMaps: _openMaps,
                  onPaste: _pasteLink,
                ),
              ],
              if (mode == MockMode.route) ...[
                const SizedBox(height: 12),
                _StopsCard(
                  controller: c,
                  theme: _theme,
                  strings: _strings,
                  onPaste: _pasteRoute,
                ),
              ],
              if (mode != MockMode.off) ...[
                const SizedBox(height: 16),
                _SectionTitle(text: _strings.placesTitle, theme: _theme),
                const SizedBox(height: 8),
                if (c.places.isEmpty)
                  Text(
                    _strings.placesEmpty,
                    style: TextStyle(fontSize: 12, color: _theme.textTertiary),
                  ),
                for (final place in c.places)
                  _PlaceTile(
                    name: place.name,
                    detail: place.detail ?? place.point.format(),
                    selected:
                        mode == MockMode.point && state.point == place.point,
                    preset: c.isPreset(place),
                    adds: mode == MockMode.route,
                    theme: _theme,
                    strings: _strings,
                    onTap: () => c.choose(place),
                    action: c.isPreset(place)
                        ? null
                        : (
                            Icons.drive_file_rename_outline_rounded,
                            _strings.editPlace,
                            () => _editPlace(place),
                          ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _LocationHero extends StatelessWidget {
  const _LocationHero({
    required this.controller,
    required this.theme,
    required this.strings,
    required this.onCopy,
    required this.onSave,
  });

  final MockLocationController controller;
  final DevSetupTheme theme;
  final MockLocationStrings strings;
  final ValueChanged<MockPoint> onCopy;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final position = controller.position;
    final progress = controller.progress;
    final finished = progress?.finished ?? false;
    final playing = state.playing && !finished;
    final (headline, caption) = switch (state.mode) {
      MockMode.off => (strings.headlineOff, strings.captionOff),
      MockMode.point when state.point == null => (
        strings.headlineNoPoint,
        strings.captionNoPoint,
      ),
      MockMode.point => (strings.headlinePoint, strings.captionPoint),
      MockMode.route when state.route == null => (
        strings.headlineNoRoute,
        strings.captionNoRoute,
      ),
      MockMode.route => (
        finished
            ? strings.headlineFinished
            : playing
            ? strings.headlinePlaying
            : strings.headlinePaused,
        strings.captionRoute,
      ),
    };
    final accent = !state.isActive
        ? theme.idle
        : state.mode == MockMode.route && !playing
        ? theme.warning
        : theme.primary;
    final name = state.mode == MockMode.point ? state.pointName : null;
    final point = position?.point;
    final shape = devShape(
      36,
      side: BorderSide(color: accent.withValues(alpha: 0.28)),
    );
    final surface = Color.alphaBlend(
      accent.withValues(alpha: 0.07),
      theme.background,
    );
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: point == null ? null : () => onCopy(point),
        customBorder: shape,
        child: Ink(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          decoration: ShapeDecoration(
            color: accent.withValues(alpha: 0.07),
            shape: shape,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        DevPulseDot(color: accent, animate: playing),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            headline,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: legibleColor(
                                accent,
                                surface,
                                theme.textPrimary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (name != null || point != null) ...[
                      const SizedBox(height: 6),
                      if (name != null)
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: theme.textPrimary,
                          ),
                        ),
                      if (point != null)
                        Text(
                          point.format(),
                          style: TextStyle(
                            fontSize: name == null ? 14 : 12,
                            fontWeight: name == null
                                ? FontWeight.w600
                                : FontWeight.w400,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: name == null
                                ? theme.textPrimary
                                : theme.textSecondary,
                          ),
                        ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      caption,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (onSave != null)
                IconButton(
                  onPressed: onSave,
                  tooltip: strings.savePlace,
                  icon: Icon(
                    Icons.bookmark_add_outlined,
                    size: 20,
                    color: theme.primary,
                  ),
                )
              else if (point != null)
                Tooltip(
                  message: strings.copyCoordinates,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(
                      Icons.copy_rounded,
                      size: 16,
                      color: theme.textTertiary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row of choices with a sliding thumb under the selected one.
class _Segmented<T> extends StatelessWidget {
  const _Segmented({
    required this.value,
    required this.options,
    required this.theme,
    required this.onChanged,
    this.height = 56,
  });

  final T value;
  final List<(T, IconData, String)> options;
  final DevSetupTheme theme;
  final ValueChanged<T> onChanged;
  final double height;

  @override
  Widget build(BuildContext context) {
    final index = options.indexWhere((option) => option.$1 == value);
    final x = options.length < 2 ? 0.0 : -1 + 2 * index / (options.length - 1);
    return Container(
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: ShapeDecoration(
        color: theme.track,
        shape: devShape(height * 0.4, side: BorderSide(color: theme.border)),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment(x, 0),
            child: FractionallySizedBox(
              widthFactor: 1 / options.length,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: theme.primary,
                  shape: devShape(height * 0.33),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (final (option, icon, label) in options)
                Expanded(
                  child: DevSegment(
                    icon: icon,
                    label: label,
                    active: option == value,
                    theme: theme,
                    onTap: () => onChanged(option),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.theme, required this.children});

  final DevSetupTheme theme;
  final List<Widget> children;

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
        children: children,
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text, required this.theme, this.trailing});

  final String text;
  final DevSetupTheme theme;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: theme.textPrimary,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _SearchCard extends StatelessWidget {
  const _SearchCard({
    required this.controller,
    required this.theme,
    required this.strings,
    required this.onSave,
    required this.onOpenMaps,
    required this.onPaste,
  });

  final MockLocationController controller;
  final DevSetupTheme theme;
  final MockLocationStrings strings;
  final ValueChanged<PlaceResult> onSave;
  final ValueChanged<MapsApp> onOpenMaps;
  final VoidCallback onPaste;

  String _appName(MapsApp app) => switch (app) {
    MapsApp.google => strings.googleMaps,
    MapsApp.apple => strings.appleMaps,
  };

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final route = c.state.mode == MockMode.route;
    final apps = c.mapsApps;
    final openMaps = _Pill(
      label: strings.openMaps,
      icon: Icons.map_outlined,
      selected: false,
      theme: theme,
      onTap: apps.length == 1 ? () => onOpenMaps(apps.single) : null,
    );
    final working = c.lookupPhase == LookupPhase.working;
    final status = switch (c.lookupPhase) {
      LookupPhase.idle || LookupPhase.results => null,
      LookupPhase.working => strings.searching,
      LookupPhase.nothingFound => strings.nothingFound,
      LookupPhase.linkNotFound => strings.linkNotFound,
      LookupPhase.noPoints => strings.noPoints,
      LookupPhase.failed => strings.lookupFailed(c.lookupError ?? ''),
    };
    final failed = switch (c.lookupPhase) {
      LookupPhase.failed ||
      LookupPhase.noPoints ||
      LookupPhase.linkNotFound => true,
      _ => false,
    };
    return _Card(
      theme: theme,
      children: [
        DevFieldLabel(
          icon: route ? Icons.add_location_alt_outlined : Icons.search_rounded,
          text: route ? strings.addStop : strings.findPlace,
          theme: theme,
        ),
        const SizedBox(height: 8),
        DevField(
          controller: c.queryController,
          hint: strings.searchHint,
          theme: theme,
          textInputAction: TextInputAction.search,
          onSubmitted: c.submitQuery,
          trailing: working
              ? Padding(
                  padding: const EdgeInsets.all(14),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.primary,
                    ),
                  ),
                )
              : ValueListenableBuilder<TextEditingValue>(
                  valueListenable: c.queryController,
                  builder: (context, value, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (value.text.isNotEmpty)
                        IconButton(
                          onPressed: c.clearResults,
                          tooltip: strings.clear,
                          icon: Icon(
                            Icons.close_rounded,
                            size: 20,
                            color: theme.textTertiary,
                          ),
                        ),
                      IconButton(
                        onPressed: c.submitQuery,
                        tooltip: strings.search,
                        icon: Icon(
                          Icons.arrow_forward_rounded,
                          color: theme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (c.canOpenMaps && apps.length == 1)
              openMaps
            else if (c.canOpenMaps)
              PopupMenuButton<MapsApp>(
                tooltip: strings.openMaps,
                color: theme.surface,
                shape: devShape(16),
                onSelected: onOpenMaps,
                itemBuilder: (context) => [
                  for (final app in apps)
                    PopupMenuItem(value: app, child: Text(_appName(app))),
                ],
                child: IgnorePointer(child: openMaps),
              ),
            _Pill(
              label: strings.pasteLink,
              icon: Icons.content_paste_rounded,
              selected: false,
              theme: theme,
              onTap: onPaste,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          status ?? strings.mapsHelp,
          style: TextStyle(
            fontSize: 12,
            color: failed
                ? theme.error
                : status == null
                ? theme.textTertiary
                : theme.textSecondary,
          ),
        ),
        if (c.results.isNotEmpty) ...[
          const SizedBox(height: 12),
          _SectionTitle(
            text: strings.results,
            theme: theme,
            trailing: TextButton(
              onPressed: c.clearResults,
              style: TextButton.styleFrom(
                foregroundColor: theme.primary,
                shape: devShape(14),
              ),
              child: Text(strings.clear),
            ),
          ),
          for (final place in c.results)
            _PlaceTile(
              name: place.name,
              detail: place.detail ?? place.point?.format(),
              selected: false,
              preset: false,
              adds: route,
              theme: theme,
              strings: strings,
              onTap: () => c.chooseResult(place),
              action: c.isSaved(place.point)
                  ? null
                  : (
                      Icons.bookmark_add_outlined,
                      strings.savePlace,
                      () => onSave(place),
                    ),
            ),
        ],
      ],
    );
  }
}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile({
    required this.name,
    required this.detail,
    required this.selected,
    required this.preset,
    required this.adds,
    required this.theme,
    required this.strings,
    required this.onTap,
    required this.action,
  });

  final String name;
  final String? detail;
  final bool selected;
  final bool preset;

  /// Tapping adds a stop rather than choosing the point.
  final bool adds;
  final DevSetupTheme theme;
  final MockLocationStrings strings;
  final VoidCallback onTap;
  final (IconData, String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final shape = devShape(
      24,
      side: BorderSide(color: selected ? theme.primary : theme.border),
    );
    final background = selected
        ? Color.alphaBlend(theme.primaryTint, theme.background)
        : theme.surface;
    final action = this.action;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
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
              padding: EdgeInsets.fromLTRB(12, 8, action == null ? 12 : 4, 8),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: ShapeDecoration(
                      color: selected ? theme.primary : theme.track,
                      shape: devShape(14),
                    ),
                    child: Icon(
                      selected
                          ? Icons.check_rounded
                          : adds
                          ? Icons.add_rounded
                          : Icons.place_outlined,
                      size: 20,
                      color: selected ? theme.onPrimary : theme.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: theme.textPrimary,
                                ),
                              ),
                            ),
                            if (preset) ...[
                              const SizedBox(width: 6),
                              DevChip(
                                text: strings.fromApp,
                                color: theme.idle,
                                background: background,
                                ink: theme.textPrimary,
                              ),
                            ],
                          ],
                        ),
                        if (detail case final detail?) ...[
                          const SizedBox(height: 2),
                          Text(
                            detail,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (action != null)
                    IconButton(
                      onPressed: action.$3,
                      tooltip: action.$2,
                      icon: Icon(
                        action.$1,
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
}

class _StopsCard extends StatelessWidget {
  const _StopsCard({
    required this.controller,
    required this.theme,
    required this.strings,
    required this.onPaste,
  });

  final MockLocationController controller;
  final DevSetupTheme theme;
  final MockLocationStrings strings;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final stops = c.state.stops;
    final error = c.routeError;
    return _Card(
      theme: theme,
      children: [
        Row(
          children: [
            Expanded(
              child: DevFieldLabel(
                icon: Icons.flag_outlined,
                text: strings.stopsTitle,
                theme: theme,
              ),
            ),
            if (stops.isNotEmpty)
              _SmallAction(
                label: strings.clearStops,
                color: theme.textSecondary,
                onPressed: c.clearStops,
              ),
            _SmallAction(
              label: strings.pasteRoute,
              color: theme.primary,
              onPressed: onPaste,
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (stops.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              strings.stopsEmpty,
              style: TextStyle(fontSize: 12, color: theme.textTertiary),
            ),
          ),
        for (var i = 0; i < stops.length; i++)
          _StopRow(
            index: i,
            stop: stops[i],
            last: i == stops.length - 1,
            theme: theme,
            strings: strings,
            onRemove: () => c.removeStop(i),
          ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(
            strings.routeFailed(error),
            style: TextStyle(fontSize: 12, color: theme.error),
          ),
        ],
        if (c.routing) ...[
          const SizedBox(height: 8),
          Text(
            strings.buildingRoute,
            style: TextStyle(fontSize: 12, color: theme.textSecondary),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            if (error != null) ...[
              Expanded(
                child: _Button(
                  label: strings.straightLines,
                  theme: theme,
                  filled: false,
                  onPressed: c.canBuildRoute
                      ? () => c.buildRoute(straight: true)
                      : null,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: _Button(
                label: strings.buildRoute,
                theme: theme,
                busy: c.routing,
                onPressed: c.canBuildRoute ? c.buildRoute : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StopRow extends StatelessWidget {
  const _StopRow({
    required this.index,
    required this.stop,
    required this.last,
    required this.theme,
    required this.strings,
    required this.onRemove,
  });

  final int index;
  final MockPlace stop;
  final bool last;
  final DevSetupTheme theme;
  final MockLocationStrings strings;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final letter = index < 26
        ? String.fromCharCode(65 + index)
        : '${index + 1}';
    return Row(
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: ShapeDecoration(
            color: index == 0 || last ? theme.primary : theme.track,
            shape: devShape(10),
          ),
          child: Text(
            letter,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: index == 0 || last ? theme.onPrimary : theme.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                stop.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.textPrimary,
                ),
              ),
              if (stop.name != stop.point.format())
                Text(
                  stop.point.format(digits: 5),
                  style: TextStyle(fontSize: 11, color: theme.textTertiary),
                ),
            ],
          ),
        ),
        IconButton(
          onPressed: onRemove,
          tooltip: strings.removeStop,
          icon: Icon(Icons.close_rounded, size: 18, color: theme.textTertiary),
        ),
      ],
    );
  }
}

class _PlaybackCard extends StatelessWidget {
  const _PlaybackCard({
    required this.controller,
    required this.theme,
    required this.strings,
    required this.onCustomSpeed,
  });

  final MockLocationController controller;
  final DevSetupTheme theme;
  final MockLocationStrings strings;
  final VoidCallback onCustomSpeed;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final state = c.state;
    final route = state.route!;
    final progress = c.progress;
    final length = route.lengthMeters;
    final along = progress?.along ?? 0;
    final finished = progress?.finished ?? false;
    final playing = state.playing && !finished;
    final presets = c.config.speedPresets;
    final custom = !presets.contains(state.speedKmh);
    return _Card(
      theme: theme,
      children: [
        DevFieldLabel(
          icon: Icons.play_circle_outline_rounded,
          text: strings.playback,
          theme: theme,
        ),
        const SizedBox(height: 10),
        ClipPath(
          clipper: ShapeBorderClipper(shape: devShape(2)),
          child: LinearProgressIndicator(
            value: length <= 0 ? 0 : (along / length).clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: theme.track,
            valueColor: AlwaysStoppedAnimation(
              playing ? theme.primary : theme.warning,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                strings.progress(along / 1000, length / 1000),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: theme.textPrimary,
                ),
              ),
            ),
            Text(
              strings.routeSummary(route.points.length, length / 1000),
              style: TextStyle(fontSize: 11, color: theme.textTertiary),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: _Button(
                label: playing ? strings.pause : strings.play,
                icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                theme: theme,
                onPressed: playing ? c.pause : c.play,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _Button(
                label: strings.restart,
                icon: Icons.replay_rounded,
                theme: theme,
                filled: false,
                onPressed: c.restart,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        DevFieldLabel(
          icon: Icons.speed_rounded,
          text: strings.speed,
          theme: theme,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final kmh in presets)
              _Pill(
                label: strings.speedValue(kmh),
                selected: state.speedKmh == kmh,
                theme: theme,
                onTap: () => c.setSpeed(kmh),
              ),
            _Pill(
              label: custom
                  ? strings.speedValue(state.speedKmh)
                  : strings.customSpeed,
              selected: custom,
              theme: theme,
              onTap: onCustomSpeed,
            ),
          ],
        ),
        const SizedBox(height: 14),
        DevFieldLabel(
          icon: Icons.u_turn_left_rounded,
          text: strings.atTheEnd,
          theme: theme,
        ),
        const SizedBox(height: 8),
        _Segmented<MockRouteEnd>(
          value: state.routeEnd,
          theme: theme,
          height: 44,
          onChanged: c.setRouteEnd,
          options: [
            (MockRouteEnd.stop, Icons.stop_rounded, strings.endStop),
            (MockRouteEnd.loop, Icons.loop_rounded, strings.endLoop),
            (
              MockRouteEnd.reverse,
              Icons.swap_horiz_rounded,
              strings.endReverse,
            ),
          ],
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.theme,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final DevSetupTheme theme;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final foreground = selected
        ? theme.onPrimary
        : icon != null
        ? theme.primary
        : theme.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? theme.primary : theme.track,
        shape: devShape(
          14,
          side: BorderSide(color: selected ? theme.primary : theme.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: foreground),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({
    required this.label,
    required this.theme,
    required this.onPressed,
    this.icon,
    this.filled = true,
    this.busy = false,
  });

  final String label;
  final DevSetupTheme theme;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool filled;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final foreground = filled ? theme.onPrimary : theme.primary;
    return TextButton(
      onPressed: enabled ? onPressed : null,
      style: TextButton.styleFrom(
        minimumSize: const Size.fromHeight(46),
        backgroundColor: filled
            ? (enabled ? theme.primary : theme.border)
            : theme.surface,
        foregroundColor: foreground,
        disabledForegroundColor: theme.textTertiary,
        shape: devShape(
          18,
          side: filled ? BorderSide.none : BorderSide(color: theme.primary),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.textTertiary,
              ),
            )
          else if (icon != null)
            Icon(icon, size: 18),
          if (busy || icon != null) const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallAction extends StatelessWidget {
  const _SmallAction({
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
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 36),
        shape: devShape(12),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// A summary of the mocked location that opens [MockLocationScreen]. The
/// setup screen shows one when given a [MockLocationConfig]; put one in your
/// own debug menu the same way.
class MockLocationCard extends StatelessWidget {
  const MockLocationCard({
    super.key,
    required this.controller,
    required this.onTap,
    this.theme = const DevSetupTheme(),
    this.strings = const MockLocationStrings(),
  });

  final MockLocationController controller;
  final VoidCallback onTap;
  final DevSetupTheme theme;
  final MockLocationStrings strings;

  String _summary() {
    final c = controller;
    final state = c.state;
    switch (state.mode) {
      case MockMode.off:
        return strings.cardOff;
      case MockMode.point:
        final point = state.point;
        if (point == null) return strings.cardNoPoint;
        return state.pointName ?? point.format(digits: 5);
      case MockMode.route:
        final route = state.route;
        final progress = c.progress;
        if (route == null || progress == null) return strings.cardNoRoute;
        if (progress.finished) return strings.cardRouteFinished;
        final length = route.lengthMeters;
        final percent = length <= 0
            ? 0
            : (progress.along / length * 100).round();
        return state.playing
            ? strings.cardRoute(percent, strings.speedValue(state.speedKmh))
            : strings.cardRoutePaused(percent);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final active = controller.state.isActive;
        return Semantics(
          button: true,
          child: Material(
            color: active ? theme.primaryTint : theme.surface,
            shape: devShape(
              24,
              side: BorderSide(color: active ? theme.primary : theme.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: ShapeDecoration(
                        color: active ? theme.primary : theme.track,
                        shape: devShape(14),
                      ),
                      child: Icon(
                        active
                            ? Icons.location_on_rounded
                            : Icons.location_off_outlined,
                        size: 20,
                        color: active ? theme.onPrimary : theme.textTertiary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            strings.title,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: theme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _summary(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: theme.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
