import 'dart:async';

import 'package:flutter/widgets.dart';

import 'discovery.dart';
import 'discovery_config.dart';
import 'models.dart';
import 'scanner.dart';
import 'store.dart';

enum PingStatus { idle, checking, online, offline }

enum ScanPhase {
  idle,
  running,
  found,
  nothingFound,
  noNetwork,
  cancelled,

  /// The scanner threw; the error went to [FlutterError.reportError].
  failed,
}

/// State and behaviour behind [DevSetupScreen], free of any widget or
/// navigation concerns so it can be driven directly in tests.
class DevSetupController extends ChangeNotifier {
  DevSetupController({
    required String defaultBaseUrl,
    required this.onBaseUrlChanged,
    this.defaultSuffix = '/api/v1/',
    this.config = const DiscoveryConfig(),
    DevSetupStore? store,
    DevServerScanner Function()? scannerFactory,
    this.pingInterval = const Duration(seconds: 5),
    this.enableDiscovery = true,
  }) : assert(config.ports.isNotEmpty, 'DiscoveryConfig.ports is empty'),
       _defaultBaseUrl = defaultBaseUrl,
       store = store ?? DevSetupStore(config: config),
       _newScanner =
           scannerFactory ?? (() => DevServerDiscovery(config: config));

  final String _defaultBaseUrl;
  final String defaultSuffix;

  /// Called with the full URL every time a choice is committed. Point your
  /// HTTP client at it.
  final void Function(String url) onBaseUrlChanged;
  final DiscoveryConfig config;
  final DevSetupStore store;
  final DevServerScanner Function() _newScanner;
  final Duration pingInterval;
  final bool enableDiscovery;

  static const List<String> schemes = ['http', 'https'];

  final TextEditingController urlController = TextEditingController();
  final TextEditingController suffixController = TextEditingController();

  /// Held apart from [urlController] so the field carries only the host and
  /// a scheme cannot be half-typed into an otherwise valid address.
  String get scheme => _scheme;
  String _scheme = schemes.first;

  /// true = a server from the list or the LAN, false = the default, null = other.
  bool? get urlMode => _urlMode;
  bool? _urlMode;

  PingStatus get pingStatus => _pingStatus;
  PingStatus _pingStatus = PingStatus.idle;

  /// The last result a check actually reached. Surfaces follow this rather
  /// than [pingStatus], so a routine re-check does not repaint them.
  PingStatus get settledStatus => _settledStatus;
  PingStatus _settledStatus = PingStatus.idle;
  bool _wasOnline = false;
  Timer? _pingTimer;
  bool _pingPaused = false;

  ScanPhase get scanPhase => _scanPhase;
  ScanPhase _scanPhase = ScanPhase.idle;
  int get scanProbed => _scanProbed;
  int _scanProbed = 0;
  int get scanTotal => _scanTotal;
  int _scanTotal = 0;
  String get scanLabel => _scanLabel;
  String _scanLabel = '';
  int get foundCount => _foundThisScan.length;
  bool get isScanning => _scanPhase == ScanPhase.running;

  /// A scan the developer started, or one they took over with [toggleScan].
  bool get isManualScan => isScanning && _scanManual;
  double? get scanProgress => isScanning && _scanTotal > 0
      ? (_scanProbed / _scanTotal).clamp(0.0, 1.0)
      : null;

  /// Display order, by endpoint. Saved servers lead in the order they were
  /// saved; discovered ones follow, ranked as they arrive and then held —
  /// nothing the developer does to a row moves it.
  final List<String> _order = [];
  final Map<String, DevServer> _servers = {};
  final Set<String> _foundThisScan = {};
  List<String> _customs = [];
  Map<String, String> _labels = {};
  Map<String, String> _pins = {};
  String? _remembered;
  String? _lanHost;

  // Ranking inputs as they stood when the scan began, so a result that lands
  // mid-scan cannot reshuffle what is already on screen.
  Map<String, String> _rankLabels = {};
  Map<String, String> _rankPins = {};
  String? _rankRemembered;

  /// Advanced only by a new scan or a cancel — never by a scan finishing — so
  /// work that outlives its scan still lands.
  int _generation = 0;

  /// Advanced by every choice the developer makes, so a scan that ends later
  /// does not overrule one made while it ran.
  int _choices = 0;
  DevServerScanner? _activeScanner;
  bool _scanManual = false;
  int _scanChoices = 0;
  DevServer? _scanPreferred;
  bool _disposed = false;

  String get baseOrigin => '$_scheme://${urlController.text.trim()}';
  String get fullUrl => baseOrigin + suffixController.text.trim();
  String get _defaultOrigin => stripSuffix(_defaultBaseUrl, defaultSuffix);

  bool get isValid =>
      urlController.text.trim().isNotEmpty && isValidUrl(baseOrigin);

  bool get canProceed =>
      _pingStatus == PingStatus.online ||
      (_pingStatus == PingStatus.checking && _wasOnline);

  bool get hasServers => _order.isNotEmpty;

  Set<String> get _customEndpoints => {
    for (final origin in _customs)
      ?DevServer.parse(origin, config: config)?.endpoint,
  };

  List<String> get _knownHosts => {
    ?_lanHost,
    ..._pins.values,
    for (final origin in _customs)
      ?DevServer.parse(origin, config: config)?.host,
    ..._labels.keys,
  }.toList();

  List<DevServerEntry> get servers => [
    for (final endpoint in _order)
      if (_servers[endpoint] case final server?) _entryFor(server),
  ];

  DevServerEntry _entryFor(DevServer server) => DevServerEntry(
    server: server,
    label: _labels[server.host],
    pinned: _isPinned(server),
    custom: _customEndpoints.contains(server.endpoint),
  );

  bool _isPinned(DevServer server) =>
      _pins[pinKeyFor(server.host)] == server.host;

  bool isSelected(DevServerEntry entry) =>
      DevServer.fromUrl(baseOrigin)?.origin == entry.server.origin;

  Future<void> init({bool startBackgroundWork = true}) async {
    final saved = await store.baseUrl() ?? _defaultBaseUrl;
    final suffix = await store.suffix() ?? defaultSuffix;
    final customs = await store.customOrigins();
    final labels = await store.labels();
    final pins = await store.pins();
    final remembered = await store.rememberedHost();
    final lanHost = await store.lanHost();
    if (_disposed) return;
    suffixController.text = suffix;
    _setOrigin(stripSuffix(saved, suffix.trim()));
    _customs = customs;
    _labels = labels;
    _pins = pins;
    _remembered = remembered;
    _lanHost = lanHost;
    _resetList();
    _detectUrlMode();
    _notify();
    if (!startBackgroundWork) return;
    startPinging();
    if (enableDiscovery) {
      unawaited(scan(manual: false));
    } else {
      unawaited(refreshSaved());
    }
  }

  // -- scanning --------------------------------------------------------------

  /// Starts a scan, replacing any that is running. [manual] scans come from
  /// the developer asking to find a server, so they may select one;
  /// automatic ones only ever list. With nothing pinned, the scanner's
  /// preferred server is selected the moment it answers rather than when the
  /// sweep ends.
  Future<void> scan({bool manual = true}) async {
    if (!enableDiscovery || _disposed) return;
    cancelScan();
    final generation = ++_generation;
    _scanManual = manual;
    _scanChoices = _choices;
    _scanPreferred = null;
    _scanPhase = ScanPhase.running;
    _scanProbed = 0;
    _scanTotal = 0;
    _scanLabel = '';
    _resetList();
    _rankLabels = Map.of(_labels);
    _rankPins = Map.of(_pins);
    _rankRemembered = _remembered;
    _notify();

    final rememberedOctet = await store.rememberedOctet();
    if (generation != _generation) return;
    final scanner = _newScanner();
    _activeScanner = scanner;
    unawaited(_verifyCustoms(generation, scanner));

    final ScanSummary summary;
    try {
      summary = await scanner.scan(
        currentHost: hostOf(baseOrigin),
        rememberedHost: _remembered,
        rememberedOctet: rememberedOctet,
        knownHosts: _knownHosts,
        onFound: (server) {
          if (generation != _generation) return;
          _noteLan(server.host);
          _upsertFound(server);
          _notify();
        },
        onPreferred: (server) {
          if (generation != _generation) return;
          _scanPreferred = server;
          if (_scanManual && _scanChoices == _choices) _selectPreferredNow();
        },
        onProgress: (probed, total, label) {
          if (generation != _generation) return;
          _scanProbed = probed;
          _scanTotal = total;
          _scanLabel = label;
          _notify();
        },
      );
    } catch (error, stack) {
      if (generation != _generation) return;
      _activeScanner = null;
      _scanPhase = ScanPhase.failed;
      _notify();
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'flutter_dev_setup',
          context: ErrorDescription('while scanning for dev servers'),
        ),
      );
      return;
    }

    if (generation != _generation) return;
    _activeScanner = null;
    _scanLabel = summary.label ?? _scanLabel;
    final autoSelect = _scanManual && _scanChoices == _choices;
    switch (summary.outcome) {
      case ScanOutcome.found:
        final fallback = summary.fallback;
        if (fallback != null) _upsertFound(fallback);
        _scanPhase = ScanPhase.found;
        if (autoSelect) {
          await _selectAfterManualScan(_scanPreferred ?? fallback);
        }
      case ScanOutcome.notFound:
        final fallback = summary.fallback;
        if (fallback != null) {
          _upsertFound(fallback);
          _scanPhase = ScanPhase.found;
          if (autoSelect) {
            await _apply(_servers[fallback.endpoint] ?? fallback);
          }
        } else {
          _scanPhase = ScanPhase.nothingFound;
        }
      case ScanOutcome.noNetwork:
        _scanPhase = ScanPhase.noNetwork;
      case ScanOutcome.cancelled:
        _scanPhase = ScanPhase.cancelled;
    }
    _notify();
  }

  /// What the Local IP control does: starts a manual scan, takes over the
  /// automatic one as if the developer had started it, or cancels a manual one.
  Future<void> toggleScan() async {
    if (isManualScan) {
      cancelScan();
      return;
    }
    if (isScanning) {
      _scanManual = true;
      _scanChoices = _choices;
      _selectPreferredNow();
      _notify();
      return;
    }
    await scan();
  }

  void _selectPreferredNow() {
    final preferred = _scanPreferred;
    if (preferred == null || !(_pins.isEmpty || _isPinned(preferred))) return;
    unawaited(_apply(_servers[preferred.endpoint] ?? preferred));
  }

  void cancelScan() {
    if (!isScanning) return;
    _generation++;
    _activeScanner?.cancel();
    _activeScanner = null;
    _scanPhase = ScanPhase.cancelled;
    _notify();
  }

  /// Re-checks saved servers without sweeping the network.
  Future<void> refreshSaved() => _verifyCustoms(_generation, _newScanner());

  Future<void> _selectAfterManualScan(DevServer? preferred) async {
    final found = [
      for (final endpoint in _order)
        if (_foundThisScan.contains(endpoint)) _servers[endpoint]!,
    ];
    final pinned = found.where(_isPinned);
    if (pinned.isNotEmpty) return _apply(pinned.first);
    if (preferred != null) {
      return _apply(_servers[preferred.endpoint] ?? preferred);
    }
    if (found.length == 1) return _apply(found.single);
  }

  Future<void> _verifyCustoms(int generation, DevServerScanner scanner) async {
    await Future.wait(
      _customs.map((origin) async {
        final placeholder = DevServer.parse(origin, config: config);
        if (placeholder == null) return;
        final live = await scanner.verifyOrigin(origin);
        if (generation != _generation || !_customs.contains(origin)) return;
        final current = _servers[placeholder.endpoint];
        if (current == null) return;
        _servers[placeholder.endpoint] = live == null
            ? placeholder.copyWith(hostname: current.hostname)
            : live.copyWith(scheme: placeholder.scheme);
        _notify();
      }),
    );
  }

  void _resetList() {
    final customs = _customEndpoints;
    _servers.removeWhere((endpoint, _) => !customs.contains(endpoint));
    _order
      ..clear()
      ..addAll(customs);
    for (final origin in _customs) {
      final placeholder = DevServer.parse(origin, config: config);
      if (placeholder == null) continue;
      _servers.putIfAbsent(placeholder.endpoint, () => placeholder);
    }
    _foundThisScan.clear();
  }

  void _upsertFound(DevServer server) {
    final key = server.endpoint;
    _foundThisScan.add(key);
    final existing = _servers[key];
    if (existing != null) {
      _servers[key] = server.copyWith(scheme: existing.scheme);
      return;
    }
    _servers[key] = server;
    final customCount = _order.takeWhile(_customEndpoints.contains).length;
    var index = customCount;
    while (index < _order.length &&
        _compare(_servers[_order[index]]!, server) <= 0) {
      index++;
    }
    _order.insert(index, key);
  }

  int _rank(DevServer server) {
    if (_rankPins[pinKeyFor(server.host)] == server.host) return 0;
    if (_rankRemembered == server.host) return 1;
    final named = DevServerEntry(
      server: server,
      label: _rankLabels[server.host],
    ).isNamed;
    return named ? 2 : 3;
  }

  int _compare(DevServer a, DevServer b) {
    final byRank = _rank(a).compareTo(_rank(b));
    if (byRank != 0) return byRank;
    final byLatency = a.latencyMs.compareTo(b.latencyMs);
    if (byLatency != 0) return byLatency;
    return a.host.compareTo(b.host);
  }

  // -- choosing --------------------------------------------------------------

  Future<void> select(DevServerEntry entry) => _apply(entry.server);

  Future<void> _apply(DevServer server) async {
    _choices++;
    _urlMode = true;
    _resetHealth();
    _setOrigin(server.origin);
    _remembered = server.host;
    await store.setRemembered(server.host);
    await commit();
    _notify();
    _restartPinging();
  }

  /// Persists the current URL and hands it to [onBaseUrlChanged].
  Future<void> commit() async {
    _choices++;
    final url = fullUrl;
    await store.setBaseUrl(url, suffix: suffixController.text.trim());
    onBaseUrlChanged(url);
  }

  Future<void> resetToDefault() async {
    cancelScan();
    _urlMode = false;
    _resetHealth();
    suffixController.text = defaultSuffix;
    _setOrigin(_defaultOrigin);
    await commit();
    _notify();
    _restartPinging();
  }

  /// For edits typed into either field. Typing does not commit — that would
  /// repoint a live app on every keystroke. A pasted URL hands its scheme to
  /// the picker.
  void onUrlEdited() {
    _choices++;
    final typed = urlController.text.trim();
    if (typed.contains('://') && isValidUrl(typed)) {
      _setOrigin(stripSuffix(typed, suffixController.text.trim()));
      urlController.selection = TextSelection.collapsed(
        offset: urlController.text.length,
      );
    }
    _resetHealth();
    _detectUrlMode();
    _notify();
    _restartPinging();
  }

  void setScheme(String? value) {
    if (value == null || value == _scheme || !schemes.contains(value)) return;
    _scheme = value;
    onUrlEdited();
  }

  // -- annotating ------------------------------------------------------------

  Future<void> togglePin(DevServerEntry entry) async {
    final key = pinKeyFor(entry.server.host);
    if (_pins[key] == entry.server.host) {
      _pins.remove(key);
    } else {
      _pins[key] = entry.server.host;
    }
    await store.setPins(_pins);
    _notify();
  }

  /// An empty [label] clears the name.
  Future<void> rename(DevServerEntry entry, String label) async {
    final trimmed = label.trim();
    if (trimmed.isEmpty) {
      _labels.remove(entry.server.host);
    } else {
      _labels[entry.server.host] = trimmed;
    }
    await store.setLabels(_labels);
    _notify();
  }

  /// Saves [origin] at the end of the saved servers, selects it and checks it.
  /// An address already saved under the other scheme is switched in place.
  /// Returns the stored form, or null if it is not an address.
  Future<String?> addCustom(String origin) async {
    final parsed = DevServer.parse(origin, config: config);
    if (parsed == null) return null;
    _choices++;
    final normal = parsed.origin;
    final endpoint = parsed.endpoint;
    if (!_customs.contains(normal)) {
      if (_customEndpoints.contains(endpoint)) {
        _customs = [
          for (final saved in _customs)
            DevServer.parse(saved, config: config)?.endpoint == endpoint
                ? normal
                : saved,
        ];
      } else {
        _order.remove(endpoint);
        _order.insert(
          _order.takeWhile(_customEndpoints.contains).length,
          endpoint,
        );
        _customs = [..._customs, normal];
      }
      final existing = _servers[endpoint];
      _servers[endpoint] = existing != null && existing.scheme == parsed.scheme
          ? existing
          : parsed.copyWith(hostname: existing?.hostname);
      _notify();
      await store.setCustomOrigins(_customs);
      if (_disposed) return normal;
    }
    await _apply(_servers[endpoint]!);
    if (_disposed) return normal;
    final live = await _newScanner().verifyOrigin(normal);
    if (live != null && _customs.contains(normal)) {
      _servers[endpoint] = live.copyWith(scheme: parsed.scheme);
      _notify();
    }
    return normal;
  }

  /// Drops a saved address. One the current scan also found stays listed, as
  /// a discovered server.
  Future<void> forget(DevServerEntry entry) async {
    final endpoint = entry.server.endpoint;
    _customs = [
      for (final origin in _customs)
        if (DevServer.parse(origin, config: config)?.endpoint != endpoint)
          origin,
    ];
    _order.remove(endpoint);
    final server = _servers.remove(endpoint);
    if (_foundThisScan.remove(endpoint) && server != null) {
      _upsertFound(server);
    }
    _notify();
    await store.setCustomOrigins(_customs);
  }

  // -- health ----------------------------------------------------------------

  void startPinging() {
    if (_disposed) return;
    if (!_pingPaused) unawaited(checkHealth());
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(pingInterval, (_) {
      if (!_pingPaused) unawaited(checkHealth());
    });
  }

  /// Skips the periodic health check while the screen cannot be seen.
  void pausePinging() => _pingPaused = true;

  void resumePinging() {
    if (!_pingPaused) return;
    _pingPaused = false;
    if (_pingTimer != null) unawaited(checkHealth());
  }

  void _restartPinging() {
    if (_pingTimer == null) return;
    startPinging();
  }

  /// Uses the discovery check rather than the app's HTTP stack, so an app-wide
  /// interceptor can never make this disagree with the server list.
  Future<void> checkHealth() async {
    if (_disposed) return;
    final origin = baseOrigin;
    if (!isValid) {
      _pingStatus = PingStatus.idle;
      _settledStatus = PingStatus.idle;
      _notify();
      return;
    }
    _pingStatus = PingStatus.checking;
    _notify();
    final server = await _newScanner().verifyOrigin(origin);
    if (baseOrigin != origin || _disposed) return;
    _pingStatus = server == null ? PingStatus.offline : PingStatus.online;
    if (server != null) _noteLan(server.host);
    _wasOnline = _pingStatus == PingStatus.online;
    _settledStatus = _pingStatus;
    _notify();
  }

  /// Keeps the network of a LAN server the developer used or a scan found,
  /// for an emulator scan to sweep. Only a server on another /24 replaces it,
  /// so it holds still while scans keep finding the same network.
  void _noteLan(String? host) {
    if (host == null) return;
    final subnets = DevServerDiscovery.emulatorSubnets(hints: [host]);
    if (subnets.isEmpty) return;
    final (:subnetBase, :centre) = subnets.single;
    final current = _lanHost;
    if (current != null &&
        DevServerDiscovery.subnetBaseOf(current) == subnetBase) {
      return;
    }
    _lanHost = '$subnetBase$centre';
    unawaited(store.setLanHost(_lanHost!));
  }

  void _resetHealth() {
    _wasOnline = false;
    _pingStatus = PingStatus.idle;
    _settledStatus = PingStatus.idle;
  }

  // -- helpers ---------------------------------------------------------------

  void _detectUrlMode() {
    final origin = baseOrigin;
    if (origin == _defaultOrigin) {
      _urlMode = false;
    } else if (DevServerDiscovery.isLocalHost(hostOf(origin)) ||
        _servers.values.any((server) => server.origin == origin)) {
      _urlMode = true;
    } else {
      _urlMode = null;
    }
  }

  /// Splits [url] so the scheme picker owns the scheme and the field owns the
  /// rest. A path is kept rather than silently dropped.
  void _setOrigin(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      urlController.text = url.trim();
      return;
    }
    if (schemes.contains(uri.scheme)) _scheme = uri.scheme;
    final explicit = explicitPortOf(url);
    final port = explicit == null ? '' : ':$explicit';
    final path = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    urlController.text = '${urlHost(uri.host)}$port$path';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _pingTimer?.cancel();
    _activeScanner?.cancel();
    urlController.dispose();
    suffixController.dispose();
    super.dispose();
  }

  static bool isValidUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && uri.hasScheme && uri.host.isNotEmpty;
  }

  static String? hostOf(String url) {
    final host = Uri.tryParse(url.trim())?.host;
    return (host == null || host.isEmpty) ? null : host;
  }

  static String stripSuffix(String url, String suffix) {
    final trimmed = url.trim();
    final bare = suffix.trim();
    if (bare.isEmpty) return trimmed;
    if (trimmed.endsWith(bare)) {
      return trimmed.substring(0, trimmed.length - bare.length);
    }
    final noSlash = bare.endsWith('/')
        ? bare.substring(0, bare.length - 1)
        : bare;
    if (noSlash.isNotEmpty && trimmed.endsWith(noSlash)) {
      return trimmed.substring(0, trimmed.length - noSlash.length);
    }
    return trimmed;
  }
}
