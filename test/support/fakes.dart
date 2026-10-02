import 'package:flutter_dev_setup/flutter_dev_setup.dart';

/// Scripted network: after [scanDelay], reports [preferred] as found and
/// preferred and waits [preferredDelay], then emits [found]. Answers
/// [verifyOrigin] from [verifyResults] after [verifyDelay], throws [error]
/// from [scan] when one is given, and records the [knownHosts] it was given.
class FakeScanner implements DevServerScanner {
  FakeScanner({
    this.found = const [],
    this.preferred,
    this.outcome = ScanOutcome.found,
    this.label = '192.168.0.0/24',
    this.fallback,
    this.verifyResults = const {},
    this.scanDelay = Duration.zero,
    this.preferredDelay = Duration.zero,
    this.verifyDelay = Duration.zero,
    this.error,
  });

  final List<DevServer> found;
  final DevServer? preferred;
  final ScanOutcome outcome;
  final String label;
  final DevServer? fallback;
  final Map<String, DevServer> verifyResults;
  final Duration scanDelay;
  final Duration preferredDelay;
  final Duration verifyDelay;
  final Object? error;
  bool cancelled = false;
  int scanCalls = 0;
  int verifyCalls = 0;
  List<String>? knownHosts;

  @override
  Future<ScanSummary> scan({
    String? currentHost,
    String? rememberedHost,
    int? rememberedOctet,
    Iterable<String> knownHosts = const [],
    required void Function(DevServer server) onFound,
    void Function(DevServer server)? onPreferred,
    void Function(String subnetBase)? onSubnet,
    void Function(int probed, int total, String label)? onProgress,
  }) async {
    scanCalls++;
    this.knownHosts = knownHosts.toList();
    await Future<void>.delayed(scanDelay);
    if (error case final error?) throw error;
    if (preferred case final preferred?) {
      onFound(preferred);
      onPreferred?.call(preferred);
      await Future<void>.delayed(preferredDelay);
    }
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
