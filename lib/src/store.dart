import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'discovery.dart';
import 'discovery_config.dart';
import 'models.dart';

/// Everything the screen remembers, in [SharedPreferences].
///
/// Keys are [keyPrefix] followed by a fixed name — `BaseUrl`, `CustomServers`
/// and so on — so an app with existing keys can pass its own prefix and keep
/// them.
class DevSetupStore {
  DevSetupStore({
    this.keyPrefix = 'devSetup',
    this.config = const DiscoveryConfig(),
  });

  final String keyPrefix;
  final DiscoveryConfig config;

  String get baseUrlKey => '${keyPrefix}BaseUrl';
  String get suffixKey => '${keyPrefix}BaseUrlSuffix';
  String get customKey => '${keyPrefix}CustomServers';
  String get labelsKey => '${keyPrefix}ServerLabels';
  String get pinsKey => '${keyPrefix}ServerPins';
  String get rememberedHostKey => '${keyPrefix}DiscoveredHost';
  String get rememberedOctetKey => '${keyPrefix}DiscoveredOctet';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  /// The full committed URL, origin and suffix together.
  Future<String?> baseUrl() async =>
      _nonEmpty(_string(await _read(baseUrlKey)));

  Future<String?> suffix() async => _string(await _read(suffixKey));

  Future<void> setBaseUrl(String url, {required String suffix}) async {
    final prefs = await _prefs;
    await prefs.setString(baseUrlKey, url);
    await prefs.setString(suffixKey, suffix);
  }

  /// Normalised on the way out as well as in, so entries saved before
  /// normalisation existed still match — and can still be forgotten. One
  /// entry per host and port, as the list shows them.
  Future<List<String>> customOrigins() async {
    final stored = await _read(customKey);
    final raw = stored is List ? stored.whereType<String>() : const <String>[];
    final seen = <String>{};
    return [
      for (final origin in raw)
        if (DevServer.parse(origin, config: config) case final server?)
          if (seen.add(server.endpoint)) server.origin,
    ];
  }

  Future<void> setCustomOrigins(List<String> origins) async {
    await (await _prefs).setStringList(customKey, origins);
  }

  Future<Map<String, String>> labels() async => _readMap(labelsKey);
  Future<void> setLabels(Map<String, String> labels) =>
      _writeMap(labelsKey, labels);

  /// Keyed by the pinned host's subnet for a LAN address and by
  /// [globalPinKey] for anything else. A pin found under another key, such as
  /// the phone's subnet an older screen used, moves to its host's key unless
  /// one is already there. A value that is not a bare host is dropped, so it
  /// cannot take a key from a real pin.
  Future<Map<String, String>> pins() async =>
      _keyedByHost(await _readMap(pinsKey));
  Future<void> setPins(Map<String, String> pins) =>
      _writeMap(pinsKey, _keyedByHost(pins));

  static Map<String, String> _keyedByHost(Map<String, String> pins) {
    final held = pins.entries.where((pin) => _isBareHost(pin.value));
    final keyed = {
      for (final MapEntry(:key, :value) in held)
        if (key == pinKeyFor(value)) key: value,
    };
    for (final MapEntry(:value) in held) {
      keyed.putIfAbsent(pinKeyFor(value), () => value);
    }
    return keyed;
  }

  static bool _isBareHost(String value) =>
      value.isNotEmpty &&
      Uri.tryParse('http://${urlHost(value)}')?.host == value;

  Future<String?> rememberedHost() async =>
      _nonEmpty(_string(await _read(rememberedHostKey)));

  Future<int?> rememberedOctet() async {
    final octet = await _read(rememberedOctetKey);
    return octet is int ? octet : null;
  }

  Future<void> setRemembered(String host) async {
    final prefs = await _prefs;
    await prefs.setString(rememberedHostKey, host);
    final octet = DevServerDiscovery.lastOctetOf(host);
    if (octet != null) {
      await prefs.setInt(rememberedOctetKey, octet);
    }
  }

  Future<Map<String, String>> _readMap(String key) async {
    final raw = _string(await _read(key));
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final MapEntry(:key, :value) in decoded.entries)
          if (value is String) '$key': value,
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeMap(String key, Map<String, String> value) async {
    await (await _prefs).setString(key, jsonEncode(value));
  }

  /// Untyped, so a key another version of the app wrote with a different
  /// type reads as unset instead of throwing.
  Future<Object?> _read(String key) async => (await _prefs).get(key);

  static String? _string(Object? value) => value is String ? value : null;

  static String? _nonEmpty(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  /// Pin bucket for addresses outside any LAN — a VPN or tunnel name — so a
  /// pin made on one network still holds on another.
  static const String globalPinKey = '*';
}

/// LAN addresses pin per subnet, so home and office keep separate choices;
/// anything else — a VPN or tunnel name — pins everywhere.
String pinKeyFor(String host) => DevServerDiscovery.isPrivateIpv4(host)
    ? DevServerDiscovery.subnetBaseOf(host)!
    : DevSetupStore.globalPinKey;

/// Entry points for app bootstrap.
abstract final class DevSetup {
  /// The base URL the developer last committed, or null if they never did.
  /// Apply it to your HTTP configuration before the first request goes out —
  /// services commonly start calling before the screen is ever shown.
  static Future<String?> savedBaseUrl({String keyPrefix = 'devSetup'}) async {
    try {
      return await DevSetupStore(keyPrefix: keyPrefix).baseUrl();
    } catch (_) {
      return null;
    }
  }

  /// Whether [url]'s server answers the health check within [timeout]. Use it
  /// to avoid pointing launch-time requests at an address that has gone stale.
  static Future<bool> isReachable(
    String url, {
    DiscoveryConfig config = const DiscoveryConfig(),
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    final server = await DevServerDiscovery(
      config: config,
    ).verifyOrigin(url).timeout(timeout, onTimeout: () => null);
    return server != null;
  }
}
