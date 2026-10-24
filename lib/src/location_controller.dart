import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'geo.dart';
import 'location_services.dart';
import 'mock_location.dart';
import 'mock_location_store.dart';

/// What the location screen offers and where it keeps things.
class MockLocationConfig {
  const MockLocationConfig({
    this.store = const MockLocationStore(),
    this.places = const [],
    this.placeSearch = defaultPlaceSearch,
    this.routeFinder = const OsrmRouteFinder(),
    this.speedPresets = const [5, 25, 40, 60],
    this.searchCenter,
    this.openUrl,
  });

  /// Pass the same store to [MockLocation.current] and [MockLocation.overlay].
  final MockLocationStore store;

  /// Places the app supplies — an office, a service area — listed ahead of
  /// the developer's own. They can be used but not renamed or forgotten.
  final List<MockPlace> places;

  /// Null turns searching off; coordinates and map links still work.
  final PlaceSearch? placeSearch;

  /// Null builds every route from straight lines between the stops.
  final RouteFinder? routeFinder;

  /// In km/h.
  final List<double> speedPresets;

  /// Where searches look first while no point or stop is set, such as the
  /// device's last known location. Without it, the first of [places].
  final MockPoint? searchCenter;

  /// Opens a maps app for the developer to find a place and copy its link,
  /// such as url_launcher's `launchUrl` in external-application mode. Without
  /// it the Open Maps button is hidden, and the package needs no plugin to
  /// launch apps.
  final Future<bool> Function(Uri uri)? openUrl;
}

enum LookupPhase {
  idle,
  working,
  results,
  nothingFound,

  /// A map link named a place without its coordinates, and the search found
  /// nothing by that name.
  linkNotFound,
  noPoints,
  failed,
}

enum MapsApp { google, apple }

/// State and behaviour behind [MockLocationScreen], free of widgets so it can
/// be driven directly in tests.
class MockLocationController extends ChangeNotifier {
  MockLocationController({
    this.config = const MockLocationConfig(),
    this.refreshInterval = const Duration(seconds: 1),
    DateTime Function()? clock,
    @visibleForTesting Future<String?> Function()? readClipboard,
  }) : _clock = clock ?? DateTime.now,
       _readClipboard = readClipboard ?? _clipboardText;

  final MockLocationConfig config;

  /// How often a playing route repaints.
  final Duration refreshInterval;
  final DateTime Function() _clock;
  final Future<String?> Function() _readClipboard;

  MockLocationStore get store => config.store;

  final TextEditingController queryController = TextEditingController();

  MockLocationState get state => _state;
  MockLocationState _state = const MockLocationState();

  bool get loaded => _loaded;
  bool _loaded = false;

  List<MockPlace> get savedPlaces => List.unmodifiable(_saved);
  List<MockPlace> _saved = [];

  /// The app's places, then the developer's.
  List<MockPlace> get places => [...config.places, ..._saved];

  bool isPreset(MockPlace place) => config.places.contains(place);

  LookupPhase get lookupPhase => _lookupPhase;
  LookupPhase _lookupPhase = LookupPhase.idle;
  List<PlaceResult> get results => _results;
  List<PlaceResult> _results = const [];

  /// The service's own words when a search failed.
  String? get lookupError => _lookupError;
  String? _lookupError;
  int _lookups = 0;

  bool get routing => _routing;
  bool _routing = false;

  /// The service's own words when routing failed; straight lines still work.
  String? get routeError => _routeError;
  String? _routeError;

  Timer? _ticker;
  bool _disposed = false;

  DateTime get now => _clock();
  MockPosition? get position => _state.positionAt(now);
  RouteProgress? get progress => _state.progressAt(now);

  bool get canBuildRoute => _state.stops.length >= 2 && !_routing;

  /// Where searches are ranked around.
  MockPoint? get near =>
      _state.point ??
      (_state.stops.isEmpty ? null : _state.stops.last.point) ??
      config.searchCenter ??
      (config.places.isEmpty ? null : config.places.first.point);

  Future<void> init() async {
    final state = await store.state();
    final saved = await store.places();
    if (_disposed) return;
    _state = state;
    _saved = saved;
    _loaded = true;
    _syncTicker();
    _notify();
  }

  // -- mode ------------------------------------------------------------------

  Future<void> setMode(MockMode mode) async {
    if (mode == _state.mode) return;
    _clearLookup();
    await _save(_state.withMode(mode, now));
  }

  // -- finding places ----------------------------------------------------------

  /// What the search field does: coordinates and map links are read on the
  /// device; anything else goes to [MockLocationConfig.placeSearch]. In
  /// point mode a single point is used at once; in route mode every point
  /// becomes a stop. A directions link replaces the stops with its own, in
  /// either mode, and builds the route.
  Future<void> submitQuery() async {
    final text = queryController.text.trim();
    if (text.isEmpty) return;
    final lookup = ++_lookups;
    _lookupPhase = LookupPhase.working;
    _results = const [];
    _lookupError = null;
    _notify();

    var link = text;
    if (MapsLinks.isShort(text)) {
      final resolved = await MapsLinks.resolve(text);
      if (lookup != _lookups || _disposed) return;
      if (resolved == null) return _lookupFailed(LookupPhase.noPoints);
      link = resolved;
    }
    final linkStops = stopsInLink(link);
    if (linkStops.length >= 2) {
      queryController.clear();
      _clearLookup();
      return _useLinkStops(linkStops);
    }
    final points = parsePoints(link);
    final isLink = link.contains('://') || link.startsWith('geo:');
    final linkText = isLink ? searchTextInLink(link) : null;
    final named = linkText == null || parsePoints(linkText).isNotEmpty
        ? null
        : linkText;

    if (points.isNotEmpty) {
      final found = [
        for (final point in points)
          MockPlace(
            points.length == 1 && named != null ? named : point.format(),
            point,
          ),
      ];
      queryController.clear();
      _clearLookup();
      if (_state.mode == MockMode.route) {
        await _save(_state.withStops([..._state.stops, ...found]));
      } else if (found.length == 1) {
        await choose(found.single);
      } else {
        _results = [
          for (final place in found)
            PlaceResult(place.name, point: place.point),
        ];
        _lookupPhase = LookupPhase.results;
        _notify();
      }
      return;
    }

    final query = isLink ? named : text;
    final search = config.placeSearch;
    if (query == null || search == null) {
      return _lookupFailed(LookupPhase.noPoints);
    }
    try {
      final around = isLink ? approximatePointInLink(link) ?? near : near;
      final found = await search.search(query, near: around);
      if (lookup != _lookups || _disposed) return;
      _results = found;
      _lookupPhase = found.isNotEmpty
          ? LookupPhase.results
          : isLink
          ? LookupPhase.linkNotFound
          : LookupPhase.nothingFound;
      _notify();
    } catch (error) {
      if (lookup != _lookups || _disposed) return;
      _lookupError = '$error';
      _lookupFailed(LookupPhase.failed);
    }
  }

  void _lookupFailed(LookupPhase phase) {
    _lookupPhase = phase;
    _results = const [];
    _notify();
  }

  /// Empties the field and drops the results.
  void clearResults() {
    _lookups++;
    queryController.clear();
    _clearLookup();
    _notify();
  }

  void _clearLookup() {
    _lookupPhase = LookupPhase.idle;
    _results = const [];
    _lookupError = null;
  }

  /// A search result tapped: looked up first when it came without a point,
  /// then used like [choose].
  Future<void> chooseResult(PlaceResult result) async {
    final place = await _located(result);
    if (place != null) await choose(place);
  }

  /// [result] as a place, once its point is known. Shows the lookup while
  /// [PlaceResult.locate] runs, and a failure when it finds nothing.
  Future<MockPlace?> _located(PlaceResult result) async {
    final known = result.point;
    if (known != null) {
      return MockPlace(result.name, known, detail: result.detail);
    }
    final lookup = ++_lookups;
    _lookupPhase = LookupPhase.working;
    _lookupError = null;
    _notify();
    try {
      final point = await result.resolve();
      if (lookup != _lookups || _disposed) return null;
      if (point == null) {
        _lookupPhase = LookupPhase.noPoints;
        _notify();
        return null;
      }
      _lookupPhase = LookupPhase.results;
      _notify();
      return MockPlace(result.name, point, detail: result.detail);
    } catch (error) {
      if (lookup != _lookups || _disposed) return null;
      _lookupError = '$error';
      _lookupPhase = LookupPhase.failed;
      _notify();
      return null;
    }
  }

  /// A place tapped in a list: the point to use in point mode, the next stop
  /// in route mode.
  Future<void> choose(MockPlace place) async {
    if (_state.mode == MockMode.route) return addStop(place);
    _lookups++;
    _clearLookup();
    queryController.clear();
    final named = place.name != place.point.format();
    await _save(_state.withPoint(place.point, name: named ? place.name : null));
  }

  // -- maps apps -------------------------------------------------------------

  /// Apple Maps is offered on Apple platforms only.
  List<MapsApp> get mapsApps => switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => MapsApp.values,
    _ => const [MapsApp.google],
  };

  /// Searches for what is typed, or else opens the map where the developer
  /// is working.
  Uri mapsUri(MapsApp app) {
    final text = queryController.text.trim();
    final query = text.contains('://') ? '' : text;
    final centre = near;
    final at = centre == null ? null : '${centre.latitude},${centre.longitude}';
    return switch (app) {
      MapsApp.google when query.isNotEmpty => Uri.https(
        'www.google.com',
        '/maps/search/',
        {'api': '1', 'query': query},
      ),
      MapsApp.google when at != null => Uri.https('www.google.com', '/maps/@', {
        'api': '1',
        'map_action': 'map',
        'center': at,
        'zoom': '15',
      }),
      MapsApp.google => Uri.https('www.google.com', '/maps/'),
      MapsApp.apple => Uri.https('maps.apple.com', '/', {
        if (query.isNotEmpty) 'q': query,
        query.isNotEmpty ? 'sll' : 'll': ?at,
        'z': '15',
      }),
    };
  }

  bool get canOpenMaps => config.openUrl != null;

  /// False when no app could open it, or the app gave no way to open one.
  Future<bool> openMaps(MapsApp app) async {
    final open = config.openUrl;
    if (open == null) return false;
    try {
      return await open(mapsUri(app));
    } catch (_) {
      return false;
    }
  }

  /// Puts the copied text in the field and looks it up. False when there was
  /// nothing to paste.
  Future<bool> pasteLink() async {
    final text = (await _readClipboard())?.trim();
    if (text == null || text.isEmpty || _disposed) return false;
    queryController.text = text;
    await submitQuery();
    return true;
  }

  static Future<String?> _clipboardText() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  // -- saved places ------------------------------------------------------------

  /// Saves [place], or the point in use when none is given. A place already
  /// saved at the same point is renamed instead.
  Future<void> savePlace(String name, {MockPlace? place}) async {
    final trimmed = name.trim();
    final point = place?.point ?? _state.point;
    if (trimmed.isEmpty || point == null) return;
    final index = _saved.indexWhere((saved) => saved.point == point);
    _saved = [..._saved];
    if (index < 0) {
      _saved.add(MockPlace(trimmed, point, detail: place?.detail));
    } else {
      _saved[index] = _saved[index].copyWith(name: trimmed);
    }
    if (_state.mode == MockMode.point && _state.point == point) {
      _state = _state.withPoint(point, name: trimmed);
      await store.setState(_state);
    }
    _notify();
    await store.setPlaces(_saved);
  }

  /// Saves a search result under [name], looking up its point first when it
  /// came without one. The results stay listed.
  Future<void> saveResult(String name, PlaceResult result) async {
    final results = _results;
    final place = await _located(result);
    if (place == null) return;
    _results = results;
    _lookupPhase = LookupPhase.results;
    await savePlace(name, place: place);
  }

  bool isSaved(MockPoint? point) =>
      point != null && places.any((place) => place.point == point);

  /// An empty [name] keeps the old one.
  Future<void> renamePlace(MockPlace place, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || isPreset(place)) return;
    _saved = [
      for (final saved in _saved)
        saved == place ? saved.copyWith(name: trimmed) : saved,
    ];
    _notify();
    await store.setPlaces(_saved);
  }

  Future<void> forgetPlace(MockPlace place) async {
    if (isPreset(place)) return;
    _saved = [
      for (final saved in _saved)
        if (saved != place) saved,
    ];
    _notify();
    await store.setPlaces(_saved);
  }

  // -- route -----------------------------------------------------------------

  Future<void> addStop(MockPlace place) async {
    _lookups++;
    _clearLookup();
    queryController.clear();
    await _save(_state.withStops([..._state.stops, place]));
  }

  Future<void> removeStop(int index) async {
    if (index < 0 || index >= _state.stops.length) return;
    await _save(_state.withStops([..._state.stops]..removeAt(index)));
  }

  Future<void> reorderStop(int from, int to) async {
    final stops = [..._state.stops];
    if (from < 0 || from >= stops.length) return;
    final stop = stops.removeAt(from);
    stops.insert(to.clamp(0, stops.length), stop);
    await _save(_state.withStops(stops));
  }

  Future<void> clearStops() => _save(_state.withStops(const []));

  /// Builds the route through the stops along roads, or along straight lines
  /// when [straight] is set or there is no [MockLocationConfig.routeFinder].
  /// A failure keeps the route already in use and sets [routeError].
  Future<void> buildRoute({bool straight = false}) async {
    if (!canBuildRoute) return;
    final stops = [for (final stop in _state.stops) stop.point];
    final finder = straight ? null : config.routeFinder;
    _routeError = null;
    if (finder == null) {
      return _save(_state.withRoute(MockRoute(stops), now: now));
    }
    _routing = true;
    _notify();
    try {
      final points = await finder.route(stops);
      if (_disposed) return;
      if (points.length < 2) {
        throw const LocationLookupException('No route found');
      }
      _routing = false;
      await _save(_state.withRoute(MockRoute(points), now: now));
    } catch (error) {
      if (_disposed) return;
      _routing = false;
      _routeError = '$error';
      _notify();
    }
  }

  /// Uses pasted points — one per line, a directions link, or an encoded
  /// polyline — as the route itself. Returns false when nothing in [text]
  /// reads as two or more points.
  Future<bool> pasteRoute(String text) async {
    final linkStops = stopsInLink(text);
    if (linkStops.length >= 2) {
      await _useLinkStops(linkStops);
      return true;
    }
    final points = routePoints(text);
    if (points.length < 2) return false;
    _routeError = null;
    await _save(
      _state.withStops(const []).withRoute(MockRoute(points), now: now),
    );
    return true;
  }

  Future<void> _useLinkStops(List<LinkStop> stops) async {
    await _save(
      _state.withMode(MockMode.route, now).withStops([
        for (final stop in stops)
          MockPlace(stop.name ?? stop.point.format(), stop.point),
      ]),
    );
    await buildRoute();
  }

  Future<void> play() => _save(_state.play(now));
  Future<void> pause() => _save(_state.pause(now));
  Future<void> restart() => _save(_state.restart(now));

  /// Ignores a speed that is not a positive number.
  Future<void> setSpeed(double kmh) async {
    if (!kmh.isFinite || kmh <= 0 || kmh == _state.speedKmh) return;
    await _save(_state.withSpeed(kmh, now));
  }

  Future<void> setRouteEnd(MockRouteEnd end) async {
    if (end == _state.routeEnd) return;
    await _save(_state.withRouteEnd(end, now));
  }

  // -- helpers ---------------------------------------------------------------

  Future<void> _save(MockLocationState state) async {
    _state = state;
    _syncTicker();
    _notify();
    await store.setState(state);
  }

  void _syncTicker() {
    final moving = _state.mode == MockMode.route && _state.playing;
    if (!moving || _disposed) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(refreshInterval, (_) => _notify());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    queryController.dispose();
    super.dispose();
  }
}
