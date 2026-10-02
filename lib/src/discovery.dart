import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'discovery_config.dart';
import 'models.dart';
import 'scanner.dart';

enum PortState { open, refused, dead }

/// Finds dev servers on the subnet this device is joined to.
///
/// The device's own address is never the answer on a physical handset — the
/// server runs on a laptop — so it sweeps the /24 and verifies every responder
/// against the health check rather than trusting an open port.
///
/// On an emulator it checks the fixed alias for the host machine first, then
/// sweeps the LAN that the host's server, the device's own address, a router
/// from [DiscoveryConfig.routerAddresses] that answers, or the developer's
/// history points to; see [emulatorSubnets].
class DevServerDiscovery implements DevServerScanner {
  DevServerDiscovery({
    this.config = const DiscoveryConfig(),
    Future<bool> Function()? isEmulator,
    Future<String?> Function()? lanAddress,
    @visibleForTesting HttpClient Function()? httpClient,
    @visibleForTesting String? emulatorHost,
    @visibleForTesting bool Function(String ip)? isLanAddress,
    @visibleForTesting Future<bool> Function(String host)? routerProbe,
    @visibleForTesting bool? isAndroid,
  }) : assert(config.ports.isNotEmpty, 'DiscoveryConfig.ports is empty'),
       _isEmulator = isEmulator ?? detectEmulator,
       _lanAddress = lanAddress ?? deviceLanAddress,
       _newHttpClient = httpClient ?? HttpClient.new,
       _emulatorHost = emulatorHost,
       _isLanAddress = isLanAddress ?? isPrivateIpv4,
       _routerProbe = routerProbe,
       _isAndroid = isAndroid ?? Platform.isAndroid;

  final DiscoveryConfig config;
  final HttpClient Function() _newHttpClient;
  final Future<bool> Function() _isEmulator;
  final Future<String?> Function() _lanAddress;
  final String? _emulatorHost;
  final bool Function(String ip) _isLanAddress;
  final Future<bool> Function(String host)? _routerProbe;
  final bool _isAndroid;

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

  /// The Android emulator's own network, behind its NAT.
  static const String _emulatorNat = '10.0.2.';

  bool _cancelled = false;

  @override
  void cancel() => _cancelled = true;

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
    _cancelled = false;
    final foundHosts = <String>{};

    if (await _isEmulator()) {
      return _scanFromEmulator(
        hints: [?currentHost, ?rememberedHost, ...knownHosts],
        foundHosts: foundHosts,
        onFound: onFound,
        onPreferred: onPreferred,
        onSubnet: onSubnet,
        onProgress: onProgress,
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
    final finished = await _sweepSubnet(
      candidatePhases(
        subnetBase: subnetBase,
        ownOctet: ownOctet,
        rememberedHost: rememberedHost,
        currentHost: currentHost,
        rememberedOctet: rememberedOctet,
        bandStart: config.leaseBandStart,
        bandEnd: config.leaseBandEnd,
      ),
      label: label,
      connectTimeout: config.connectTimeout,
      foundHosts: foundHosts,
      onFound: onFound,
      onProgress: onProgress,
    );
    if (!finished) {
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

  Future<ScanSummary> _scanFromEmulator({
    required List<String> hints,
    required Set<String> foundHosts,
    required void Function(DevServer server) onFound,
    void Function(DevServer server)? onPreferred,
    void Function(String subnetBase)? onSubnet,
    void Function(int probed, int total, String label)? onProgress,
  }) async {
    final host = _emulatorHost ?? (_isAndroid ? '10.0.2.2' : '127.0.0.1');
    const hostLabel = 'emulator host';
    final deviceAddress = _isAndroid ? null : await _lanAddress();
    final deviceNamesLan = emulatorSubnets(
      deviceAddress: deviceAddress,
      isLan: _isLanAddress,
    ).isNotEmpty;
    final routers = deviceNamesLan ? null : _answeringRouters();
    final ports = config.ports;
    final advertised = <String>[];
    onProgress?.call(0, ports.length, hostLabel);
    for (var i = 0; i < ports.length; i++) {
      if (_cancelled) return const ScanSummary(ScanOutcome.cancelled);
      final answer = await _check(host, ports[i]);
      onProgress?.call(i + 1, ports.length, hostLabel);
      if (answer == null) continue;
      advertised.addAll(answer.lan);
      if (!foundHosts.add(host)) continue;
      final server = await _named(answer.server);
      onFound(server);
      onPreferred?.call(server);
    }
    if (_cancelled) return const ScanSummary(ScanOutcome.cancelled);

    final hostNamesLan = emulatorSubnets(
      advertised: advertised,
      isLan: _isLanAddress,
    ).isNotEmpty;
    final subnets = emulatorSubnets(
      advertised: advertised,
      deviceAddress: deviceAddress,
      hints: [if (routers != null && !hostNamesLan) ...await routers, ...hints],
      isLan: _isLanAddress,
    );
    final swept = <String>[];
    for (final subnet in subnets) {
      if (_cancelled) break;
      swept.add(subnet.subnetBase);
      onSubnet?.call(subnet.subnetBase);
      await _sweepSubnet(
        candidatePhases(
          subnetBase: subnet.subnetBase,
          ownOctet: subnet.centre,
          knownHosts: hints,
          exclude: foundHosts,
          isLan: _isLanAddress,
          bandStart: config.leaseBandStart,
          bandEnd: config.leaseBandEnd,
        ),
        label: '${subnet.subnetBase}0/24',
        connectTimeout: config.emulatorConnectTimeout,
        foundHosts: foundHosts,
        onFound: onFound,
        onProgress: onProgress,
      );
    }

    final label = swept.isEmpty
        ? hostLabel
        : '$hostLabel and ${swept.map((base) => '${base}0/24').join(', ')}';
    final subnetBase = swept.firstOrNull;
    if (_cancelled) {
      return ScanSummary(
        ScanOutcome.cancelled,
        subnetBase: subnetBase,
        label: label,
      );
    }
    // The alias is right even before the server is up, so offer it anyway.
    final fallback = foundHosts.contains(host)
        ? null
        : DevServer(host: host, port: config.primaryPort, latencyMs: 0);
    return ScanSummary(
      foundHosts.isEmpty ? ScanOutcome.notFound : ScanOutcome.found,
      subnetBase: subnetBase,
      label: label,
      fallback: fallback,
    );
  }

  /// The [DiscoveryConfig.routerAddresses] that answer, in their order.
  Future<List<String>> _answeringRouters() async {
    final probe =
        _routerProbe ??
        (host) => routerAnswers(host, timeout: config.emulatorConnectTimeout);
    final answered = await Future.wait([
      for (final router in config.routerAddresses)
        probe(router).then((up) => up ? router : null, onError: (_) => null),
    ]);
    return [for (final router in answered) ?router];
  }

  /// Whether [host] accepts or refuses a connection on any of [ports]. Only
  /// an explicit refusal counts: an unreachable host or network can come back
  /// just as fast from a router that is not on this LAN.
  @visibleForTesting
  static Future<bool> routerAnswers(
    String host, {
    List<int> ports = const [80, 53],
    required Duration timeout,
    Future<Socket> Function(String host, int port, {Duration? timeout})?
    connect,
  }) async {
    final refused = _errorCodes(Platform.operatingSystem).refused;
    final answers = await Future.wait([
      for (final port in ports)
        (connect ?? Socket.connect)(host, port, timeout: timeout).then(
          (socket) {
            socket.destroy();
            return true;
          },
          onError: (Object error) =>
              error is SocketException &&
              refused.contains(error.osError?.errorCode),
        ),
    ]);
    return answers.contains(true);
  }

  /// Sweeps [phases] in order on the first port, then tries the other ports
  /// on the hosts that proved they are up. False when cancelled.
  Future<bool> _sweepSubnet(
    List<List<String>> phases, {
    required String label,
    required Duration connectTimeout,
    required Set<String> foundHosts,
    required void Function(DevServer server) onFound,
    void Function(int probed, int total, String label)? onProgress,
  }) async {
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
        connectTimeout: connectTimeout,
        liveHosts: liveHosts,
        foundHosts: foundHosts,
        onFound: onFound,
        onProbed: (probed) => onProgress?.call(offset + probed, total, label),
      );
      if (_cancelled) return false;
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
        connectTimeout: connectTimeout,
        liveHosts: {},
        foundHosts: foundHosts,
        onFound: onFound,
      );
    }
    return !_cancelled;
  }

  Future<void> _sweep(
    List<String> hosts,
    int port, {
    required Duration connectTimeout,
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
        final state = await tcpProbe(host, port, timeout: connectTimeout);
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

  /// [timeout] defaults to [DiscoveryConfig.connectTimeout].
  Future<PortState> tcpProbe(String host, int port, {Duration? timeout}) async {
    final budget = timeout ?? config.connectTimeout;
    final elapsed = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: budget);
      return PortState.open;
    } on SocketException catch (error) {
      return classifyConnectError(
        error.osError?.errorCode,
        elapsed: elapsed.elapsed,
        timeout: budget,
      );
    } catch (_) {
      return PortState.dead;
    } finally {
      socket?.destroy();
    }
  }

  /// What a failed connect says about the host. A refusal proves it is up, and
  /// an unreachable network or a host reported down counts as down, however
  /// long either took: through an emulator's NAT a refusal can take a second,
  /// and an address with no host behind it fails as an unreachable network.
  /// Any other error is read by its timing, since a failure well inside
  /// [timeout] came back from the host. That includes an unreachable host,
  /// which is how Linux reports a firewall's administratively prohibited
  /// reject. [operatingSystem] picks the error codes and defaults to this one.
  static PortState classifyConnectError(
    int? errorCode, {
    required Duration elapsed,
    required Duration timeout,
    String? operatingSystem,
  }) {
    final (:refused, :down) = _errorCodes(
      operatingSystem ?? Platform.operatingSystem,
    );
    if (refused.contains(errorCode)) return PortState.refused;
    if (down.contains(errorCode)) return PortState.dead;
    return elapsed < timeout * 0.8 ? PortState.refused : PortState.dead;
  }

  static ({List<int> refused, List<int> down}) _errorCodes(String os) =>
      switch (os) {
        'macos' || 'ios' => (refused: const [61], down: const [51, 64]),
        // A failed connect can come back with its WinSock or its Win32 code.
        'windows' => (
          refused: const [10061, 1225],
          down: const [10051, 10064, 1231, 1256],
        ),
        _ => (refused: const [111], down: const [101, 112]),
      };

  Future<DevServer?> verify(
    String host,
    int port, {
    String scheme = 'http',
  }) async => (await _check(host, port, scheme: scheme))?.server;

  /// [verify], along with the addresses the server lists in
  /// [DiscoveryConfig.lanAddressHeader].
  Future<({DevServer server, List<String> lan})?> _check(
    String host,
    int port, {
    String scheme = 'http',
  }) async {
    // Only a host that already accepted a probe, or one URL checked directly,
    // gets here, so connecting (DNS, TCP and TLS) takes the verify budget. On
    // an emulator that alone often runs past a second.
    final client = _newHttpClient()..connectionTimeout = config.verifyTimeout;
    final elapsed = Stopwatch()..start();
    final path = config.healthPath.startsWith('/')
        ? config.healthPath
        : '/${config.healthPath}';
    try {
      final request = await client
          .getUrl(Uri.parse('$scheme://${urlHost(host)}:$port$path'))
          .timeout(config.verifyTimeout);
      request.followRedirects = false;
      final response = await request.close().timeout(config.verifyTimeout);
      final body = await _readBody(response).timeout(config.verifyTimeout);
      if (!config.isHealthy(response.statusCode, body)) return null;
      final lanHeader = config.lanAddressHeader;
      return (
        server: DevServer(
          host: host,
          port: port,
          latencyMs: elapsed.elapsedMilliseconds,
          hostname: _advertisedName(response.headers[config.hostHeader]),
          scheme: scheme,
        ),
        lan: lanHeader == null
            ? const <String>[]
            : _listed(response.headers[lanHeader]),
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

  /// Every item of a header that may be repeated, comma-joined, or both.
  static List<String> _listed(List<String>? values) => [
    for (final value in values ?? const <String>[])
      for (final item in value.split(','))
        if (item.trim().isNotEmpty) item.trim(),
  ];

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

  /// The /24s an emulator sweeps after the alias, best first and at most
  /// [limit]: those of the host machine's own LAN addresses, [advertised] by
  /// the alias; of [deviceAddress], the device's own; then of [hints], the
  /// routers that answered and then hosts the developer has used. Only IPv4
  /// addresses [isLan] accepts count, and none in the Android emulator's NAT,
  /// 10.0.2.0/24. By default that rules out loopback, public addresses and
  /// hostnames.
  ///
  /// Each walk is centred on the subnet's first host or device address, or
  /// else on its first hint. Those addresses are swept like any other, so the
  /// host is listed by its LAN address as well as by the alias.
  static List<({String subnetBase, int centre})> emulatorSubnets({
    Iterable<String> advertised = const [],
    String? deviceAddress,
    Iterable<String> hints = const [],
    bool Function(String ip) isLan = isPrivateIpv4,
    int limit = 2,
  }) {
    String? usable(String ip) {
      final octets = octetsOf(ip);
      if (octets == null) return null;
      final address = octets.join('.');
      if (subnetBaseOf(address) == _emulatorNat || !isLan(address)) {
        return null;
      }
      return address;
    }

    final ranked = {
      for (final ip in [...advertised, ?deviceAddress, ...hints]) ?usable(ip),
    };
    final bases = <String>{};
    for (final ip in ranked) {
      if (bases.length == limit) break;
      bases.add(subnetBaseOf(ip)!);
    }
    return [
      for (final base in bases)
        (
          subnetBase: base,
          centre: lastOctetOf(ranked.firstWhere((ip) => ip.startsWith(base)))!,
        ),
    ];
  }

  /// Cheapest first: hosts already known, then the lease band, then the rest of
  /// the subnet walking outward from our own octet. Each phase runs to the end
  /// before the next starts, so an earlier phase wins when two servers answer.
  ///
  /// [exclude] is never proposed and defaults to our own address. With nothing
  /// to exclude, [ownOctet] is only where the walk starts, and is proposed
  /// like any other host. A known host counts only on this subnet and if
  /// [isLan] accepts it.
  static List<List<String>> candidatePhases({
    required String subnetBase,
    required int ownOctet,
    String? rememberedHost,
    String? currentHost,
    int? rememberedOctet,
    Iterable<String> knownHosts = const [],
    Iterable<String>? exclude,
    bool Function(String ip) isLan = isPrivateIpv4,
    int bandStart = 100,
    int bandEnd = 120,
  }) {
    final taken = <String>{
      ...exclude ?? ['$subnetBase$ownOctet'],
    };
    List<String> phase(Iterable<String> hosts) => [
      for (final host in hosts)
        if (taken.add(host)) host,
    ];

    final known = phase(
      [
        ?rememberedHost,
        ?currentHost,
        if (rememberedOctet != null) '$subnetBase$rememberedOctet',
        ...knownHosts,
      ].where((host) => host.startsWith(subnetBase) && isLan(host)),
    );
    final band = phase([
      for (var octet = bandStart; octet <= bandEnd; octet++)
        if (octet >= 1 && octet <= 254) '$subnetBase$octet',
    ]);
    final rest = <String>[];
    for (var distance = 0; distance <= 254; distance++) {
      for (final octet in {ownOctet - distance, ownOctet + distance}) {
        if (octet >= 1 && octet <= 254) rest.add('$subnetBase$octet');
      }
    }
    return [known, band, phase(rest)];
  }
}
