import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';

import 'discovery_config.dart';
import 'models.dart';
import 'scanner.dart';

enum PortState { open, refused, dead }

/// Finds dev servers on the subnet this device is joined to.
///
/// The device's own address is never the answer on a physical handset — the
/// server runs on a laptop — so it sweeps the /24 and verifies every responder
/// against the health check rather than trusting an open port.
class DevServerDiscovery implements DevServerScanner {
  DevServerDiscovery({
    this.config = const DiscoveryConfig(),
    Future<bool> Function()? isEmulator,
    Future<String?> Function()? lanAddress,
  }) : assert(config.ports.isNotEmpty, 'DiscoveryConfig.ports is empty'),
       _isEmulator = isEmulator ?? detectEmulator,
       _lanAddress = lanAddress ?? deviceLanAddress;

  final DiscoveryConfig config;
  final Future<bool> Function() _isEmulator;
  final Future<String?> Function() _lanAddress;

  static const List<String> _skipInterfacePrefixes = [
    'awdl',
    'llw',
    'ap',
    'p2p',
    'rmnet',
    'tun',
    'utun',
    'ccmni',
    'dummy',
    'bond',
    'rndis',
    'pdp_ip',
    'ipsec',
    'ppp',
    'wwan',
    'seth',
    'clat',
    'v4-',
  ];

  static const int _bodyLimit = 1 << 20;

  bool _cancelled = false;

  @override
  void cancel() => _cancelled = true;

  @override
  Future<ScanSummary> scan({
    String? currentHost,
    String? rememberedHost,
    int? rememberedOctet,
    required void Function(DevServer server) onFound,
    void Function(String subnetBase)? onSubnet,
    void Function(int probed, int total, String label)? onProgress,
  }) async {
    _cancelled = false;
    final foundHosts = <String>{};

    if (await _isEmulator()) {
      final host = Platform.isAndroid ? '10.0.2.2' : '127.0.0.1';
      const label = 'emulator host';
      final ports = config.ports;
      onProgress?.call(0, ports.length, label);
      for (var i = 0; i < ports.length; i++) {
        if (_cancelled) return const ScanSummary(ScanOutcome.cancelled);
        final server = await verify(host, ports[i]);
        onProgress?.call(i + 1, ports.length, label);
        if (server != null && foundHosts.add(host)) {
          onFound(await _named(server));
        }
      }
      if (foundHosts.isNotEmpty) {
        return const ScanSummary(ScanOutcome.found, label: label);
      }
      // The alias is right even before the server is up, so offer it anyway.
      return ScanSummary(
        ScanOutcome.notFound,
        label: label,
        fallback: DevServer(host: host, port: config.primaryPort, latencyMs: 0),
      );
    }

    final local = await _lanAddress();
    final subnetBase = local == null ? null : subnetBaseOf(local);
    final ownOctet = local == null ? null : lastOctetOf(local);
    if (subnetBase == null || ownOctet == null) {
      return const ScanSummary(ScanOutcome.noNetwork);
    }

    onSubnet?.call(subnetBase);
    final label = '${subnetBase}0/24';
    final phases = candidatePhases(
      subnetBase: subnetBase,
      ownOctet: ownOctet,
      rememberedHost: rememberedHost,
      currentHost: currentHost,
      rememberedOctet: rememberedOctet,
      bandStart: config.leaseBandStart,
      bandEnd: config.leaseBandEnd,
    );
    final total = phases.fold<int>(0, (sum, phase) => sum + phase.length);
    onProgress?.call(0, total, label);

    final liveHosts = <String>{};
    var done = 0;
    for (final phase in phases) {
      if (phase.isEmpty) continue;
      final offset = done;
      await _sweep(
        phase,
        config.primaryPort,
        liveHosts: liveHosts,
        foundHosts: foundHosts,
        onFound: onFound,
        onProbed: (probed) => onProgress?.call(offset + probed, total, label),
      );
      if (_cancelled) {
        return ScanSummary(
          ScanOutcome.cancelled,
          subnetBase: subnetBase,
          label: label,
        );
      }
      done += phase.length;
      onProgress?.call(done, total, label);
    }

    // Only hosts that answered the primary sweep — with a connection or a
    // refusal — are known to be up, so other ports cost a handful of probes
    // rather than another full pass.
    final alternates = liveHosts.difference(foundHosts).toList();
    for (final port in config.fallbackPorts) {
      if (_cancelled || alternates.isEmpty) break;
      await _sweep(
        alternates,
        port,
        liveHosts: {},
        foundHosts: foundHosts,
        onFound: onFound,
      );
    }

    if (_cancelled) {
      return ScanSummary(
        ScanOutcome.cancelled,
        subnetBase: subnetBase,
        label: label,
      );
    }
    return ScanSummary(
      foundHosts.isEmpty ? ScanOutcome.notFound : ScanOutcome.found,
      subnetBase: subnetBase,
      label: label,
    );
  }

  Future<void> _sweep(
    List<String> hosts,
    int port, {
    required Set<String> liveHosts,
    required Set<String> foundHosts,
    required void Function(DevServer server) onFound,
    void Function(int probed)? onProbed,
  }) async {
    var next = 0;
    var probed = 0;

    Future<void> worker() async {
      while (true) {
        if (_cancelled || next >= hosts.length) return;
        final host = hosts[next++];
        final state = await tcpProbe(host, port);
        onProbed?.call(++probed);
        if (state == PortState.dead) continue;
        liveHosts.add(host);
        if (state != PortState.open || foundHosts.contains(host)) continue;
        final server = await verify(host, port);
        if (server == null || _cancelled || !foundHosts.add(host)) continue;
        onFound(await _named(server));
      }
    }

    final workers = hosts.length < config.concurrency
        ? hosts.length
        : config.concurrency;
    await Future.wait(List.generate(workers, (_) => worker()));
  }

  Future<DevServer> _named(DevServer server) async {
    final advertised = server.hostname;
    if (advertised != null && advertised.isNotEmpty) return server;
    final name = await reverseLookup(
      server.host,
      timeout: config.reverseLookupTimeout,
    );
    return name == null ? server : server.copyWith(hostname: name);
  }

  Future<PortState> tcpProbe(String host, int port) async {
    final started = DateTime.now();
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: config.connectTimeout);
      return PortState.open;
    } on SocketException {
      // Refusal error codes differ per platform; the timing does not. A
      // refusal comes back at once and still proves the host is up.
      final elapsed = DateTime.now().difference(started);
      return elapsed < config.connectTimeout * 0.8
          ? PortState.refused
          : PortState.dead;
    } catch (_) {
      return PortState.dead;
    } finally {
      socket?.destroy();
    }
  }

  Future<DevServer?> verify(
    String host,
    int port, {
    String scheme = 'http',
  }) async {
    final client = HttpClient()..connectionTimeout = config.connectTimeout;
    final elapsed = Stopwatch()..start();
    final path = config.healthPath.startsWith('/')
        ? config.healthPath
        : '/${config.healthPath}';
    try {
      final request = await client
          .getUrl(Uri.parse('$scheme://${urlHost(host)}:$port$path'))
          .timeout(config.verifyTimeout);
      final response = await request.close().timeout(config.verifyTimeout);
      final body = await _readBody(response).timeout(config.verifyTimeout);
      if (!config.isHealthy(response.statusCode, body)) return null;
      return DevServer(
        host: host,
        port: port,
        latencyMs: elapsed.elapsedMilliseconds,
        hostname: _advertisedName(response.headers[config.hostHeader]),
        scheme: scheme,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _readBody(Stream<List<int>> response) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      final room = _bodyLimit - bytes.length;
      bytes.add(chunk.length > room ? chunk.sublist(0, room) : chunk);
      if (bytes.length >= _bodyLimit) break;
    }
    return const Utf8Decoder(allowMalformed: true).convert(bytes.takeBytes());
  }

  /// A repeated header arrives either as several values — where
  /// `headers.value` throws, and a server would be rejected over it — or
  /// folded into one comma-joined value. Either way the first name wins.
  static String? _advertisedName(List<String>? values) {
    if (values == null || values.isEmpty) return null;
    final name = values.first.split(',').first.trim();
    return name.isEmpty ? null : name;
  }

  @override
  Future<DevServer?> verifyOrigin(String origin) async {
    final parsed = DevServer.fromUrl(origin);
    if (parsed == null) return null;
    return verify(parsed.host, parsed.port, scheme: parsed.scheme);
  }

  static Future<String?> reverseLookup(
    String host, {
    Duration timeout = const Duration(milliseconds: 400),
  }) async {
    try {
      final resolved = await InternetAddress(host).reverse().timeout(timeout);
      final name = resolved.host;
      return (name.isEmpty || name == host) ? null : name;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> deviceLanAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final candidates = <MapEntry<int, String>>[];
      for (final interface in interfaces) {
        final priority = interfacePriority(interface.name);
        if (priority == null) continue;
        for (final address in interface.addresses) {
          if (!isPrivateIpv4(address.address)) continue;
          candidates.add(MapEntry(priority, address.address));
        }
      }
      if (candidates.isEmpty) return null;
      candidates.sort((a, b) => a.key.compareTo(b.key));
      return candidates.first.value;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> detectEmulator() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) return !(await info.androidInfo).isPhysicalDevice;
      if (Platform.isIOS) return !(await info.iosInfo).isPhysicalDevice;
    } catch (_) {}
    return false;
  }

  /// Lower sorts first; `null` means the interface can never carry the LAN.
  static int? interfacePriority(String name) {
    final lower = name.toLowerCase();
    for (final prefix in _skipInterfacePrefixes) {
      if (lower.startsWith(prefix)) return null;
    }
    if (lower.startsWith('wlan') || lower == 'en0') return 0;
    if (lower.startsWith('eth')) return 1;
    if (lower.startsWith('en')) return 2;
    return 50;
  }

  static bool isPrivateIpv4(String ip) {
    final octets = octetsOf(ip);
    if (octets == null) return false;
    if (octets[0] == 10) return true;
    if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
    return octets[0] == 192 && octets[1] == 168;
  }

  static bool isLocalHost(String? host) {
    if (host == null || host.isEmpty) return false;
    if (host == 'localhost' || host == '127.0.0.1') return true;
    return isPrivateIpv4(host);
  }

  static List<int>? octetsOf(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
      octets.add(value);
    }
    return octets;
  }

  static String? subnetBaseOf(String ip) {
    final octets = octetsOf(ip);
    if (octets == null) return null;
    return '${octets[0]}.${octets[1]}.${octets[2]}.';
  }

  static int? lastOctetOf(String ip) => octetsOf(ip)?[3];

  /// Cheapest first: hosts already known, then the lease band, then the rest of
  /// the subnet walking outward from our own octet. Each phase runs to the end
  /// before the next starts, so an earlier phase wins when two servers answer.
  static List<List<String>> candidatePhases({
    required String subnetBase,
    required int ownOctet,
    String? rememberedHost,
    String? currentHost,
    int? rememberedOctet,
    int bandStart = 100,
    int bandEnd = 120,
  }) {
    final taken = <String>{'$subnetBase$ownOctet'};
    List<String> phase(Iterable<String> hosts) => [
      for (final host in hosts)
        if (taken.add(host)) host,
    ];

    final known = phase(
      [
        ?rememberedHost,
        ?currentHost,
        if (rememberedOctet != null) '$subnetBase$rememberedOctet',
      ].where((host) => host.startsWith(subnetBase) && isPrivateIpv4(host)),
    );
    final band = phase([
      for (var octet = bandStart; octet <= bandEnd; octet++)
        if (octet >= 1 && octet <= 254) '$subnetBase$octet',
    ]);
    final rest = <String>[];
    for (var distance = 1; distance <= 254; distance++) {
      for (final octet in [ownOctet - distance, ownOctet + distance]) {
        if (octet >= 1 && octet <= 254) rest.add('$subnetBase$octet');
      }
    }
    return [known, band, phase(rest)];
  }
}
