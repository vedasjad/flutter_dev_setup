import 'discovery_config.dart';

/// A server that answered the health check, or an address saved by hand.
class DevServer {
  const DevServer({
    required this.host,
    required this.port,
    required this.latencyMs,
    this.hostname,
    this.scheme = 'http',
  });

  final String host;
  final int port;

  /// Round-trip time of the health check; negative when it never answered.
  final int latencyMs;

  /// A name the server advertised, or one a reverse lookup produced.
  final String? hostname;
  final String scheme;

  String get origin => '$scheme://$host:$port';
  String get endpoint => '$host:$port';
  bool get reachable => latencyMs >= 0;

  DevServer copyWith({int? latencyMs, String? hostname, String? scheme}) =>
      DevServer(
        host: host,
        port: port,
        latencyMs: latencyMs ?? this.latencyMs,
        hostname: hostname ?? this.hostname,
        scheme: scheme ?? this.scheme,
      );

  /// Parses a typed address without contacting it. Accepts a hostname as well
  /// as an IP. A bare http address gets the first configured port, since a
  /// saved one is almost always a dev server.
  static DevServer? parse(
    String origin, {
    DiscoveryConfig config = const DiscoveryConfig(),
  }) => _parse(origin, () => config.primaryPort);

  /// Reads [url] the way an HTTP client will: with no port written, it is the
  /// scheme's own, 80 or 443.
  static DevServer? fromUrl(String url) => _parse(url, () => 80);

  static DevServer? _parse(String raw, int Function() httpPort) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.host.isEmpty) return null;
    final scheme = uri.scheme == 'https' ? 'https' : 'http';
    final port = explicitPortOf(raw) ?? (scheme == 'https' ? 443 : httpPort());
    return DevServer(host: uri.host, port: port, latencyMs: -1, scheme: scheme);
  }

  /// The canonical `scheme://host:port` form of a typed address, so the same
  /// server typed two ways is stored, matched and forgotten as one.
  static String? normalize(
    String origin, {
    DiscoveryConfig config = const DiscoveryConfig(),
  }) => parse(origin, config: config)?.origin;
}

/// A row in the server list, with the developer's own annotations.
class DevServerEntry {
  const DevServerEntry({
    required this.server,
    this.label,
    this.pinned = false,
    this.custom = false,
  });

  final DevServer server;
  final String? label;
  final bool pinned;

  /// Added by hand rather than discovered; survives scans and can be forgotten.
  final bool custom;

  String get displayName {
    final own = label;
    if (own != null && own.isNotEmpty) return own;
    final resolved = server.hostname;
    if (resolved != null && resolved.isNotEmpty) {
      return prettyHostname(resolved);
    }
    return server.host;
  }

  bool get isNamed => displayName != server.host;
}

/// The port written in [raw], if any. Dart's [Uri] drops a port equal to the
/// scheme's default, so `http://box:80` and `http://box` parse identically —
/// and a bare http host here means the dev port, not 80.
int? explicitPortOf(String raw) {
  final match = _authority.firstMatch(raw.trim());
  final digits = match?.group(1);
  return digits == null ? null : int.tryParse(digits);
}

final RegExp _authority = RegExp(
  r'^[a-zA-Z][a-zA-Z0-9+.\-]*://(?:[^/?#@]*@)?(?:\[[^\]]*\]|[^/?#:@]*)(?::(\d+))?',
);

String prettyHostname(String raw) {
  var name = raw.endsWith('.') ? raw.substring(0, raw.length - 1) : raw;
  for (final suffix in const ['.local', '.lan', '.home', '.localdomain']) {
    if (name.toLowerCase().endsWith(suffix)) {
      name = name.substring(0, name.length - suffix.length);
      break;
    }
  }
  return name.isEmpty ? raw : name;
}

enum ScanOutcome { found, notFound, cancelled, noNetwork }

class ScanSummary {
  const ScanSummary(this.outcome, {this.subnetBase, this.label, this.fallback});

  final ScanOutcome outcome;
  final String? subnetBase;

  /// What was searched, e.g. `192.168.0.0/24`.
  final String? label;

  /// An address worth offering even though nothing answered — the emulator's
  /// alias for the host machine.
  final DevServer? fallback;
}
