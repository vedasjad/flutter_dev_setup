/// Every piece of text the location screen and its card show, overridable
/// for localisation.
class MockLocationStrings {
  const MockLocationStrings({
    this.title = 'Mock location',
    this.cardOff = 'Off: the app reads the GPS',
    this.cardNoPoint = 'Point: none chosen',
    this.cardNoRoute = 'Route: not built yet',
    this.cardRoute = _cardRoute,
    this.cardRoutePaused = _cardRoutePaused,
    this.cardRouteFinished = 'Route finished',
    this.modeOff = 'Off',
    this.modePoint = 'Point',
    this.modeRoute = 'Route',
    this.headlineOff = 'Real location',
    this.headlinePoint = 'Fixed point',
    this.headlineNoPoint = 'No point chosen',
    this.headlinePlaying = 'Moving along a route',
    this.headlinePaused = 'Route paused',
    this.headlineFinished = 'Route finished',
    this.headlineNoRoute = 'No route yet',
    this.captionOff = 'The app reads the device GPS.',
    this.captionPoint = 'The app sees this point instead of the GPS.',
    this.captionNoPoint =
        'Search for a place, or paste coordinates or a Maps link.',
    this.captionRoute = 'The app sees this route instead of the GPS.',
    this.captionNoRoute = 'Add two or more stops, then build the route.',
    this.copyCoordinates = 'Copy coordinates',
    this.copied = _copied,
    this.findPlace = 'Find a place',
    this.addStop = 'Add a stop',
    this.searchHint = 'Place, coordinates or Maps link',
    this.openMaps = 'Open Maps',
    this.googleMaps = 'Google Maps',
    this.appleMaps = 'Apple Maps',
    this.pasteLink = 'Paste link',
    this.mapsHelp =
        'In Maps, long-press the spot to drop a pin, share it and copy the '
        'link, then come back and tap Paste link.',
    this.mapsFailed = "Couldn't open a maps app.",
    this.clipboardEmpty = 'Nothing copied yet. Copy the link in Maps first.',
    this.search = 'Search',
    this.searching = 'Looking it up…',
    this.nothingFound =
        'Nothing matched. Free map data misses some places: drop a pin on it '
        'in Maps, share it, and paste the link here.',
    this.linkNotFound =
        "That link names a place but not where it is, and the search didn't "
        'find it. In Maps, long-press the spot to drop a pin and share that.',
    this.noPoints =
        'No coordinates in that. Try a place name, or a Maps '
        'link to a place.',
    this.lookupFailed = _lookupFailed,
    this.results = 'Results',
    this.clear = 'Clear',
    this.placesTitle = 'Saved places',
    this.placesEmpty =
        'Places you save are listed here, on this device '
        'only.',
    this.fromApp = 'app',
    this.savePlace = 'Save this place',
    this.editPlace = 'Rename or forget',
    this.placeNameTitle = 'Name this place',
    this.placeNameHint = 'e.g. Office',
    this.placeNameHelp = 'Kept on this device only.',
    this.stopsTitle = 'Stops',
    this.stopsEmpty =
        'Add two or more stops: search above, or tap a saved '
        'place.',
    this.removeStop = 'Remove stop',
    this.clearStops = 'Clear stops',
    this.buildRoute = 'Build route',
    this.buildingRoute = 'Finding a road route…',
    this.routeFailed = _routeFailed,
    this.straightLines = 'Use straight lines',
    this.pasteRoute = 'Paste a route',
    this.pasteRouteBody =
        'Points one per line, a directions link, or an '
        'encoded polyline.',
    this.pasteRouteHint = '25.4775, 80.3349\n25.4790, 80.3361',
    this.pasteRouteHelp = 'Replaces the route and the stops.',
    this.pasteRouteInvalid = 'Needs two or more points.',
    this.playback = 'Playback',
    this.routeSummary = _routeSummary,
    this.progress = _progress,
    this.play = 'Play',
    this.pause = 'Pause',
    this.restart = 'Restart',
    this.speed = 'Speed',
    this.speedValue = _speedValue,
    this.customSpeed = 'Other',
    this.speedTitle = 'Speed',
    this.speedBody = 'In kilometres an hour.',
    this.speedHint = '25',
    this.speedHelp = 'The route carries on from where it is now.',
    this.speedInvalid = 'Needs a number above 0.',
    this.atTheEnd = 'At the end',
    this.endStop = 'Stop',
    this.endLoop = 'Loop',
    this.endReverse = 'Back',
    this.save = 'Save',
    this.cancel = 'Cancel',
    this.forget = 'Forget',
  });

  final String title;
  final String cardOff;
  final String cardNoPoint;
  final String cardNoRoute;
  final String Function(int percent, String speed) cardRoute;
  final String Function(int percent) cardRoutePaused;
  final String cardRouteFinished;
  final String modeOff;
  final String modePoint;
  final String modeRoute;
  final String headlineOff;
  final String headlinePoint;
  final String headlineNoPoint;
  final String headlinePlaying;
  final String headlinePaused;
  final String headlineFinished;
  final String headlineNoRoute;
  final String captionOff;
  final String captionPoint;
  final String captionNoPoint;
  final String captionRoute;
  final String captionNoRoute;
  final String copyCoordinates;
  final String Function(String coordinates) copied;
  final String findPlace;
  final String addStop;
  final String searchHint;
  final String openMaps;
  final String googleMaps;
  final String appleMaps;
  final String pasteLink;
  final String mapsHelp;
  final String mapsFailed;
  final String clipboardEmpty;
  final String search;
  final String searching;
  final String nothingFound;
  final String linkNotFound;
  final String noPoints;
  final String Function(String reason) lookupFailed;
  final String results;
  final String clear;
  final String placesTitle;
  final String placesEmpty;
  final String fromApp;
  final String savePlace;
  final String editPlace;
  final String placeNameTitle;
  final String placeNameHint;
  final String placeNameHelp;
  final String stopsTitle;
  final String stopsEmpty;
  final String removeStop;
  final String clearStops;
  final String buildRoute;
  final String buildingRoute;
  final String Function(String reason) routeFailed;
  final String straightLines;
  final String pasteRoute;
  final String pasteRouteBody;
  final String pasteRouteHint;
  final String pasteRouteHelp;
  final String pasteRouteInvalid;
  final String playback;
  final String Function(int points, double km) routeSummary;
  final String Function(double alongKm, double totalKm) progress;
  final String play;
  final String pause;
  final String restart;
  final String speed;
  final String Function(double kmh) speedValue;
  final String customSpeed;
  final String speedTitle;
  final String speedBody;
  final String speedHint;
  final String speedHelp;
  final String speedInvalid;
  final String atTheEnd;
  final String endStop;
  final String endLoop;
  final String endReverse;
  final String save;
  final String cancel;
  final String forget;

  static String _cardRoute(int percent, String speed) =>
      'Route: $percent% at $speed';
  static String _cardRoutePaused(int percent) => 'Route paused at $percent%';
  static String _copied(String coordinates) => 'Copied $coordinates';
  static String _lookupFailed(String reason) => 'Search failed: $reason';
  static String _routeFailed(String reason) =>
      'No road route: $reason. Straight lines between the stops still work.';
  static String _routeSummary(int points, double km) =>
      '$points points · ${_km(km)} km';
  static String _progress(double alongKm, double totalKm) =>
      '${_km(alongKm)} of ${_km(totalKm)} km';
  static String _speedValue(double kmh) =>
      '${kmh == kmh.roundToDouble() ? kmh.toInt() : kmh} km/h';
  static String _km(double km) => km.toStringAsFixed(km < 10 ? 2 : 1);
}
