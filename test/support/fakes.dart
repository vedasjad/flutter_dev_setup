import 'package:flutter_dev_setup/flutter_dev_setup.dart';

/// Scripted network: emits [found] after [scanDelay], answers [verifyOrigin]
/// from [verifyResults] after [verifyDelay], and throws [error] from [scan]
/// when one is given.
class FakeScanner implements DevServerScanner {
  FakeScanner({
    this.found = const [],
    this.outcome = ScanOutcome.found,
    this.label = '192.168.0.0/24',
    this.fallback,
    this.verifyResults = const {},
    this.scanDelay = Duration.zero,
    this.verifyDelay = Duration.zero,
    this.error,
  });

  final List<DevServer> found;
  final ScanOutcome outcome;
  final String label;
  final DevServer? fallback;
  final Map<String, DevServer> verifyResults;
  final Duration scanDelay;
  final Duration verifyDelay;
  final Object? error;
  bool cancelled = false;
  int scanCalls = 0;
  int verifyCalls = 0;

  @override
  Future<ScanSummary> scan({
    String? currentHost,
    String? rememberedHost,
    int? rememberedOctet,
    required void Function(DevServer server) onFound,
    void Function(String subnetBase)? onSubnet,
    void Function(int probed, int total, String label)? onProgress,
  }) async {
    scanCalls++;
    await Future<void>.delayed(scanDelay);
    if (error case final error?) throw error;
    for (final server in found) {
      onFound(server);
    }
    return ScanSummary(
      cancelled ? ScanOutcome.cancelled : outcome,
      subnetBase: '192.168.0.',
      label: label,
      fallback: fallback,
    );
  }

  @override
  Future<DevServer?> verifyOrigin(String origin) async {
    verifyCalls++;
    await Future<void>.delayed(verifyDelay);
    return verifyResults[DevServer.normalize(origin)];
  }

  @override
  void cancel() => cancelled = true;
}

DevServer server(String host, {int port = 5001, int ms = 10, String? name}) =>
    DevServer(host: host, port: port, latencyMs: ms, hostname: name);

const testConfig = DiscoveryConfig(ports: [5001, 8080]);
const defaultUrl = 'https://staging.example.com/api/v1/';

DevSetupStore testStore() =>
    DevSetupStore(keyPrefix: 'dev', config: testConfig);

/// A controller wired to [scanner], with commits recorded in [committed].
Future<DevSetupController> buildController({
  FakeScanner? scanner,
  List<String>? committed,
  Duration pingInterval = const Duration(seconds: 5),
}) async {
  final fake = scanner ?? FakeScanner();
  final controller = DevSetupController(
    defaultBaseUrl: defaultUrl,
    onBaseUrlChanged: (url) => committed?.add(url),
    config: testConfig,
    store: testStore(),
    scannerFactory: () => fake,
    pingInterval: pingInterval,
  );
  await controller.init(startBackgroundWork: false);
  return controller;
}
