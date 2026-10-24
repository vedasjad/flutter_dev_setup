import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dev_setup/flutter_dev_setup.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

const defaultBaseUrl = 'https://example.com/api/v1/';

final apiBaseUrl = ValueNotifier<String>(defaultBaseUrl);

/// Optional: `--dart-define=MAPS_API_KEY=...` adds Google search and routing
/// on top of the free ones.
const mapsApiKey = String.fromEnvironment('MAPS_API_KEY');

final mockLocation = MockLocationConfig(
  places: const [
    MockPlace('Example office', MockPoint(25.4762689, 80.3395498)),
  ],
  placeSearch: mapsApiKey.isEmpty
      ? defaultPlaceSearch
      : const CombinedPlaceSearch([
          GooglePlaceSearch(apiKey: mapsApiKey),
          defaultPlaceSearch,
        ]),
  routeFinder: mapsApiKey.isEmpty
      ? const OsrmRouteFinder()
      : const GoogleRouteFinder(apiKey: mapsApiKey),
  openUrl: (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    final saved = await DevSetup.savedBaseUrl();
    if (saved != null && await DevSetup.isReachable(saved)) {
      apiBaseUrl.value = saved;
    }
  }
  runApp(const ExampleApp());
}

/// Where the app reads its position. In debug builds both calls ask
/// [MockLocation] first.
abstract final class AppLocation {
  static Future<Position> current() async {
    if (kDebugMode) {
      final mock = await MockLocation.current();
      if (mock != null) return _toPosition(mock);
    }
    return Geolocator.getCurrentPosition();
  }

  static Stream<Position> positions() {
    final real = Geolocator.getPositionStream();
    return kDebugMode ? MockLocation.overlay(real, _toPosition) : real;
  }

  static Position _toPosition(MockPosition mock) => Position(
    latitude: mock.latitude,
    longitude: mock.longitude,
    timestamp: mock.timestamp,
    accuracy: mock.accuracy,
    altitude: mock.altitude,
    altitudeAccuracy: 0,
    heading: mock.heading,
    headingAccuracy: 0,
    speed: mock.speed,
    speedAccuracy: 0,
    isMocked: true,
  );
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_dev_setup example',
      home: kDebugMode
          ? DevSetupScreen(
              defaultBaseUrl: defaultBaseUrl,
              onBaseUrlChanged: (url) => apiBaseUrl.value = url,
              mockLocation: mockLocation,
              onProceed: (context) => Navigator.of(context).pushReplacement(
                MaterialPageRoute<void>(builder: (_) => const HomePage()),
              ),
            )
          : const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamSubscription<Position>? _positions;
  Position? _latest;
  Position? _oneOff;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (!mounted) return;
    _positions = AppLocation.positions().listen(
      (position) => setState(() {
        _latest = position;
        _error = null;
      }),
      onError: (Object error) => setState(() => _error = error),
    );
  }

  Future<void> _fetchOnce() async {
    try {
      final position = await AppLocation.current();
      if (mounted) setState(() => _oneOff = position);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    unawaited(_positions?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          if (kDebugMode)
            IconButton(
              tooltip: 'Developer setup',
              icon: const Icon(Icons.developer_mode_rounded),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => DevSetupScreen(
                    defaultBaseUrl: defaultBaseUrl,
                    onBaseUrlChanged: (url) => apiBaseUrl.value = url,
                    mockLocation: mockLocation,
                    onProceed: (context) => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('API base URL', style: text.labelLarge),
          const SizedBox(height: 8),
          ValueListenableBuilder<String>(
            valueListenable: apiBaseUrl,
            builder: (context, url, _) => SelectableText(url),
          ),
          const SizedBox(height: 24),
          Text('Position stream', style: text.labelLarge),
          const SizedBox(height: 8),
          _PositionText(position: _latest),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text('$_error', style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 24),
          Text('One-off position', style: text.labelLarge),
          const SizedBox(height: 8),
          _PositionText(position: _oneOff),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: _fetchOnce,
              child: const Text('Get current position'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PositionText extends StatelessWidget {
  const _PositionText({required this.position});

  final Position? position;

  @override
  Widget build(BuildContext context) {
    final p = position;
    if (p == null) return const Text('Waiting…');
    return SelectableText(
      '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}\n'
      'heading ${p.heading.toStringAsFixed(0)}° · '
      '${(p.speed * 3.6).toStringAsFixed(0)} km/h · '
      '${p.isMocked ? 'mocked' : 'real'}',
    );
  }
}
