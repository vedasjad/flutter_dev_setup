/// How a dev server is recognised and how hard to look for one.
class DiscoveryConfig {
  const DiscoveryConfig({
    this.ports = const [8080, 3000, 5000, 8000],
    this.healthPath = '/',
    this.isHealthy = defaultIsHealthy,
    this.hostHeader = 'x-dev-host',
    this.leaseBandStart = 100,
    this.leaseBandEnd = 120,
    this.connectTimeout = const Duration(milliseconds: 600),
    this.verifyTimeout = const Duration(seconds: 4),
    this.reverseLookupTimeout = const Duration(milliseconds: 400),
    this.concurrency = 48,
  }) : assert(concurrency > 0, 'concurrency must be at least 1');

  /// The first is swept across the whole subnet; the rest are only tried on
  /// hosts that already proved they are up. Must not be empty.
  final List<int> ports;

  /// Requested on every candidate; [isHealthy] decides whether it is a server.
  /// A missing leading slash is added. [isHealthy] sees at most the first
  /// megabyte of the body.
  final String healthPath;
  final bool Function(int statusCode, String body) isHealthy;

  /// A response header the server may use to name itself.
  final String hostHeader;

  /// Most routers lease from .100 up, so this band gets probed before the rest.
  final int leaseBandStart;
  final int leaseBandEnd;

  /// The sweep's TCP probe. Paid once per dead host, so it stays tight. Health
  /// checks do not use it.
  final Duration connectTimeout;

  /// Each step of a health check: connecting (DNS, TCP and TLS), sending, and
  /// reading the response. Paid only by hosts that accepted a probe and by URLs
  /// checked directly, so it can wait out Wi-Fi power saving or the slow DNS of
  /// an emulator.
  final Duration verifyTimeout;
  final Duration reverseLookupTimeout;

  /// Probing an unseen host needs an ARP resolution, and the kernel's queue of
  /// unresolved entries is small; a wider burst drops packets and reports live
  /// hosts as dead.
  final int concurrency;

  int get primaryPort => ports.first;
  List<int> get fallbackPorts => ports.sublist(1);

  static bool defaultIsHealthy(int statusCode, String body) =>
      statusCode >= 200 && statusCode < 300;
}
