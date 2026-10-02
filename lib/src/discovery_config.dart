/// How a dev server is recognised and how hard to look for one.
class DiscoveryConfig {
  const DiscoveryConfig({
    this.ports = const [8080, 3000, 5000, 8000],
    this.healthPath = '/',
    this.isHealthy = defaultIsHealthy,
    this.hostHeader = 'x-dev-host',
    this.lanAddressHeader = 'x-dev-lan',
    this.routerAddresses = defaultRouterAddresses,
    this.leaseBandStart = 100,
    this.leaseBandEnd = 120,
    this.connectTimeout = const Duration(milliseconds: 600),
    this.emulatorConnectTimeout = const Duration(milliseconds: 1500),
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

  /// A response header the server may use to list its own LAN IPv4 addresses,
  /// comma-separated or on repeated lines. Read only from an emulator's alias
  /// for the host machine, where it names the LAN to sweep. Null turns it off.
  final String? lanAddressHeader;

  /// Where an emulator looks for the host machine's router when neither the
  /// server's [lanAddressHeader] nor the device's own address names the LAN.
  /// Those that accept or refuse a connection on port 80 or 53 name the /24s
  /// to sweep, in this order and ahead of the networks of servers the
  /// developer has used; an emulator sweeps two /24s at most. Defaults to
  /// common home, office and hotspot router addresses, with a cable or fibre
  /// modem's 192.168.100.1 last, since it answers from behind the router too.
  final List<String> routerAddresses;

  /// Most routers lease from .100 up, so this band gets probed before the rest.
  final int leaseBandStart;
  final int leaseBandEnd;

  /// The sweep's TCP probe. Paid once per dead host, so it stays tight. Health
  /// checks do not use it.
  final Duration connectTimeout;

  /// The sweep's TCP probe on an emulator, where every connect crosses the
  /// emulator's NAT and takes 0.3 to 1.1 s whatever the target, refusals
  /// included, so [connectTimeout] would count live hosts as dead.
  final Duration emulatorConnectTimeout;

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

  static const List<String> defaultRouterAddresses = [
    '192.168.0.1',
    '192.168.1.1',
    '192.168.2.1',
    '192.168.10.1',
    '192.168.29.1',
    '192.168.31.1',
    '192.168.43.1',
    '192.168.50.1',
    '192.168.68.1',
    '192.168.86.1',
    '192.168.88.1',
    '192.168.178.1',
    '192.168.0.254',
    '192.168.1.254',
    '10.0.0.1',
    '10.0.1.1',
    '10.1.1.1',
    '10.10.10.1',
    '172.16.0.1',
    '172.20.10.1',
    '192.168.100.1',
  ];
}
