import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'geo.dart';

/// A lookup that did not produce an answer, with a reason fit to show.
class LocationLookupException implements Exception {
  const LocationLookupException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A place a search found.
///
/// An autocomplete API answers with names and an id, and charges for every
/// lookup of coordinates; such a search leaves [point] out and gives
/// [locate], which runs only for the result the developer picks.
class PlaceResult {
  const PlaceResult(this.name, {this.point, this.detail, this.locate})
    : assert(point != null || locate != null, 'Needs a point or a locate');

  final String name;
  final MockPoint? point;

  /// A second line, such as the address.
  final String? detail;
  final Future<MockPoint?> Function()? locate;

  /// [point], or what [locate] finds. Null when neither gives one.
  Future<MockPoint?> resolve() async => point ?? await locate?.call();
}

/// Turns typed text into places.
abstract interface class PlaceSearch {
  /// Your own search as a function — your backend's place search, say — to
  /// use alone or in a [CombinedPlaceSearch] with [defaultPlaceSearch].
  factory PlaceSearch.from(
    Future<List<PlaceResult>> Function(String query, MockPoint? near) search,
  ) = _PlaceSearchFunction;

  /// Places matching [query], best first. [near] is where the developer is
  /// working, for ranking nearby places first.
  Future<List<PlaceResult>> search(String query, {MockPoint? near});
}

class _PlaceSearchFunction implements PlaceSearch {
  _PlaceSearchFunction(this._search);

  final Future<List<PlaceResult>> Function(String query, MockPoint? near)
  _search;

  @override
  Future<List<PlaceResult>> search(String query, {MockPoint? near}) =>
      _search(query, near);
}

/// Builds a road path through stops.
abstract interface class RouteFinder {
  /// Your own routing as a function — your backend's directions, say.
  factory RouteFinder.from(
    Future<List<MockPoint>> Function(List<MockPoint> stops) route,
  ) = _RouteFinderFunction;

  /// The points of a path through [stops], in order, starting at the first
  /// and ending at the last.
  Future<List<MockPoint>> route(List<MockPoint> stops);
}

class _RouteFinderFunction implements RouteFinder {
  _RouteFinderFunction(this._route);

  final Future<List<MockPoint>> Function(List<MockPoint> stops) _route;

  @override
  Future<List<MockPoint>> route(List<MockPoint> stops) => _route(stops);
}

/// Identifies this package to the free services, as their usage policies ask.
const String defaultLookupUserAgent =
    'flutter_dev_setup (+https://github.com/vedasjad/flutter_dev_setup)';

/// OpenStreetMap's free geocoder. No key.
///
/// The public instance allows about one request a second and no searching as
/// the developer types, so the screen searches only on submit. Pass
/// [baseUrl] to use your own instance.
class NominatimPlaceSearch implements PlaceSearch {
  const NominatimPlaceSearch({
    this.baseUrl = 'https://nominatim.openstreetmap.org',
    this.countryCodes = const [],
    this.limit = 8,
    this.userAgent = defaultLookupUserAgent,
    this.timeout = const Duration(seconds: 10),
  });

  final String baseUrl;

  /// ISO 3166-1 alpha-2 codes, such as `in`, to keep results to.
  final List<String> countryCodes;
  final int limit;
  final String userAgent;
  final Duration timeout;

  /// Half the side of the box results near [search]'s `near` are ranked up
  /// in, in degrees. Places outside it can still be found.
  static const double biasDegrees = 0.5;

  @override
  Future<List<PlaceResult>> search(String query, {MockPoint? near}) async {
    final uri = Uri.parse('$baseUrl/search').replace(
      queryParameters: {
        'q': query,
        'format': 'jsonv2',
        'limit': '$limit',
        if (countryCodes.isNotEmpty) 'countrycodes': countryCodes.join(','),
        if (near != null)
          'viewbox': [
            near.longitude - biasDegrees,
            near.latitude + biasDegrees,
            near.longitude + biasDegrees,
            near.latitude - biasDegrees,
          ].join(','),
      },
    );
    final body = await requestJson(
      uri,
      headers: {'user-agent': userAgent},
      timeout: timeout,
    );
    if (body is! List) throw const LocationLookupException('Unexpected reply');
    return [
      for (final item in body)
        if (item is Map)
          if (_point(item['lat'], item['lon']) case final point?)
            _place(item, point),
    ];
  }

  static PlaceResult _place(Map<Object?, Object?> item, MockPoint point) {
    final display = '${item['display_name'] ?? ''}';
    final name = '${item['name'] ?? ''}';
    final title = name.isNotEmpty ? name : display.split(',').first.trim();
    final rest = display.startsWith(title)
        ? display.substring(title.length).replaceFirst(RegExp(r'^,\s*'), '')
        : display;
    return PlaceResult(title, point: point, detail: rest.isEmpty ? null : rest);
  }

  static MockPoint? _point(Object? lat, Object? lng) {
    final latitude = double.tryParse('$lat');
    final longitude = double.tryParse('$lng');
    if (latitude == null || longitude == null) return null;
    return MockPoint.tryCreate(latitude, longitude);
  }
}

/// Komoot's free Photon geocoder over OpenStreetMap. No key.
///
/// With [boundDegrees] set it only looks in a box that size around the
/// search's `near`, which finds a local school or shop that a worldwide
/// search ranks below namesakes in other countries.
class PhotonPlaceSearch implements PlaceSearch {
  const PhotonPlaceSearch({
    this.baseUrl = 'https://photon.komoot.io',
    this.limit = 8,
    this.boundDegrees = 0.5,
    this.userAgent = defaultLookupUserAgent,
    this.timeout = const Duration(seconds: 10),
  });

  final String baseUrl;
  final int limit;

  /// Half the side of the box searched, in degrees. Null searches
  /// everywhere, nearest first.
  final double? boundDegrees;
  final String userAgent;
  final Duration timeout;

  @override
  Future<List<PlaceResult>> search(String query, {MockPoint? near}) async {
    final bound = boundDegrees;
    final uri = Uri.parse('$baseUrl/api/').replace(
      queryParameters: {
        'q': query,
        'limit': '$limit',
        if (near != null && bound != null)
          'bbox': [
            near.longitude - bound,
            near.latitude - bound,
            near.longitude + bound,
            near.latitude + bound,
          ].join(',')
        else if (near != null) ...{
          'lat': '${near.latitude}',
          'lon': '${near.longitude}',
        },
      },
    );
    final body = await requestJson(
      uri,
      headers: {'user-agent': userAgent},
      timeout: timeout,
    );
    final features = _dig(body, ['features']);
    if (features is! List) {
      throw const LocationLookupException('Unexpected reply');
    }
    return [for (final feature in features) ?_feature(feature)];
  }

  static PlaceResult? _feature(Object? feature) {
    final coordinates = _dig(feature, ['geometry', 'coordinates']);
    if (coordinates is! List || coordinates.length < 2) return null;
    final [lng, lat, ...] = coordinates;
    if (lat is! num || lng is! num) return null;
    final point = MockPoint.tryCreate(lat.toDouble(), lng.toDouble());
    final properties = _dig(feature, ['properties']);
    if (point == null || properties is! Map) return null;
    String? text(String key) => switch (properties[key]) {
      final String value when value.trim().isNotEmpty => value.trim(),
      _ => null,
    };
    final street = [text('street'), text('housenumber')].nonNulls.join(' ');
    final parts = <String>[];
    for (final part in [
      street.isEmpty ? null : street,
      text('locality'),
      text('district'),
      text('city'),
      text('county'),
      text('state'),
      text('country'),
    ]) {
      if (part != null && !parts.contains(part)) parts.add(part);
    }
    final name = text('name') ?? (parts.isEmpty ? point.format() : parts.first);
    final detail = parts.where((part) => part != name).join(', ');
    return PlaceResult(
      name,
      point: point,
      detail: detail.isEmpty ? null : detail,
    );
  }
}

/// Runs several searches at once. The first one's results lead, in its own
/// order; the rest follow nearest the search's `near` first, so a namesake
/// abroad comes after one in the same country. A place an earlier search
/// already found is dropped. A search that fails is left out; only when every
/// one fails does the first failure reach the screen.
class CombinedPlaceSearch implements PlaceSearch {
  const CombinedPlaceSearch(this.searches, {this.limit = 12});

  final List<PlaceSearch> searches;
  final int limit;

  /// The same name this close is the same place.
  static const double sameWithinMeters = 150;

  @override
  Future<List<PlaceResult>> search(String query, {MockPoint? near}) async {
    final outcomes = await Future.wait([
      for (final search in searches)
        search
            .search(query, near: near)
            .then<Object>((places) => places, onError: (Object e) => e),
    ]);
    if (outcomes.every((outcome) => outcome is! List<PlaceResult>)) {
      if (outcomes.isEmpty) return const [];
      throw outcomes.first;
    }
    final lead = switch (outcomes.first) {
      final List<PlaceResult> places => places,
      _ => const <PlaceResult>[],
    };
    final rest = [
      for (final outcome in outcomes.skip(1))
        if (outcome is List<PlaceResult>) ...outcome,
    ];
    if (near != null) {
      double away(PlaceResult place) =>
          place.point?.distanceTo(near) ?? double.infinity;
      rest.sort((a, b) => away(a).compareTo(away(b)));
    }
    final merged = <PlaceResult>[];
    for (final place in [...lead, ...rest]) {
      final known = merged.any(
        (seen) =>
            seen.name.toLowerCase() == place.name.toLowerCase() &&
            switch ((seen.point, place.point)) {
              (final a?, final b?) => a.distanceTo(b) <= sameWithinMeters,
              _ => seen.detail == place.detail,
            },
      );
      if (!known) merged.add(place);
      if (merged.length >= limit) break;
    }
    return merged;
  }
}

/// The free search the screen uses unless told otherwise: Photon around the
/// developer's area first, then Nominatim everywhere.
const PlaceSearch defaultPlaceSearch = CombinedPlaceSearch([
  PhotonPlaceSearch(),
  NominatimPlaceSearch(),
]);

/// The OSRM demo server: free road routing, no key, driving only. Fine for
/// building a test route now and then; not for traffic. FOSSGIS runs
/// walking and cycling servers too, such as
/// `https://routing.openstreetmap.de/routed-foot` with profile `driving`.
class OsrmRouteFinder implements RouteFinder {
  const OsrmRouteFinder({
    this.baseUrl = 'https://router.project-osrm.org',
    this.profile = 'driving',
    this.userAgent = defaultLookupUserAgent,
    this.timeout = const Duration(seconds: 15),
  });

  final String baseUrl;
  final String profile;
  final String userAgent;
  final Duration timeout;

  @override
  Future<List<MockPoint>> route(List<MockPoint> stops) async {
    final path = stops.map((s) => '${s.longitude},${s.latitude}').join(';');
    final uri = Uri.parse(
      '$baseUrl/route/v1/$profile/$path',
    ).replace(queryParameters: {'overview': 'full', 'geometries': 'geojson'});
    final body = await requestJson(
      uri,
      headers: {'user-agent': userAgent},
      timeout: timeout,
    );
    if (body is! Map) throw const LocationLookupException('Unexpected reply');
    if (body['code'] != 'Ok') {
      throw LocationLookupException('${body['message'] ?? body['code']}');
    }
    final coordinates = _dig(body, ['routes', 0, 'geometry', 'coordinates']);
    if (coordinates is! List) {
      throw const LocationLookupException('No route found');
    }
    return [
      for (final pair in coordinates)
        if (pair is List && pair.length >= 2)
          if (pair[0] is num && pair[1] is num)
            ?MockPoint.tryCreate(
              (pair[1] as num).toDouble(),
              (pair[0] as num).toDouble(),
            ),
    ];
  }
}

/// Google's Places API (New) text search. Needs a key with that API enabled,
/// and it is billed per request. A key restricted to Android or iOS apps
/// only works with [headers] naming the app: `X-Android-Package` and
/// `X-Android-Cert`, or `X-Ios-Bundle-Identifier`.
class GooglePlaceSearch implements PlaceSearch {
  const GooglePlaceSearch({
    required this.apiKey,
    this.headers = const {},
    this.timeout = const Duration(seconds: 10),
  });

  final String apiKey;
  final Map<String, String> headers;
  final Duration timeout;

  @override
  Future<List<PlaceResult>> search(String query, {MockPoint? near}) async {
    final body = await requestJson(
      Uri.parse('https://places.googleapis.com/v1/places:searchText'),
      method: 'POST',
      headers: {
        ...headers,
        'x-goog-api-key': apiKey,
        'x-goog-fieldmask':
            'places.displayName,places.formattedAddress,places.location',
      },
      body: {
        'textQuery': query,
        if (near != null)
          'locationBias': {
            'circle': {
              'center': {
                'latitude': near.latitude,
                'longitude': near.longitude,
              },
              'radius': 50000.0,
            },
          },
      },
      timeout: timeout,
    );
    final places = body is Map ? body['places'] : null;
    if (places is! List) return const [];
    return [
      for (final place in places)
        if (place is Map)
          if (_location(place['location']) case final point?)
            PlaceResult(
              '${_dig(place, ['displayName', 'text']) ?? point.format()}',
              point: point,
              detail: switch (place['formattedAddress']) {
                final String address => address,
                _ => null,
              },
            ),
    ];
  }
}

/// Google's Routes API. Needs a key with that API enabled, and it is billed
/// per request. See [GooglePlaceSearch] for app-restricted keys.
class GoogleRouteFinder implements RouteFinder {
  const GoogleRouteFinder({
    required this.apiKey,
    this.travelMode = 'DRIVE',
    this.headers = const {},
    this.timeout = const Duration(seconds: 15),
  });

  final String apiKey;

  /// `DRIVE`, `TWO_WHEELER`, `WALK` or `BICYCLE`.
  final String travelMode;
  final Map<String, String> headers;
  final Duration timeout;

  @override
  Future<List<MockPoint>> route(List<MockPoint> stops) async {
    Map<String, Object?> waypoint(MockPoint p) => {
      'location': {
        'latLng': {'latitude': p.latitude, 'longitude': p.longitude},
      },
    };
    final body = await requestJson(
      Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes'),
      method: 'POST',
      headers: {
        ...headers,
        'x-goog-api-key': apiKey,
        'x-goog-fieldmask': 'routes.polyline.encodedPolyline',
      },
      body: {
        'origin': waypoint(stops.first),
        'destination': waypoint(stops.last),
        if (stops.length > 2)
          'intermediates': [
            for (final stop in stops.sublist(1, stops.length - 1))
              waypoint(stop),
          ],
        'travelMode': travelMode,
        'polylineQuality': 'HIGH_QUALITY',
      },
      timeout: timeout,
    );
    final polyline = _dig(body, ['routes', 0, 'polyline', 'encodedPolyline']);
    if (polyline is! String) {
      throw const LocationLookupException('No route found');
    }
    return decodePolyline(polyline);
  }
}

/// Walks [path] into decoded JSON: a string indexes a map, an int a list.
Object? _dig(Object? json, List<Object> path) {
  var node = json;
  for (final step in path) {
    node = switch ((node, step)) {
      (final Map<Object?, Object?> map, final String key) => map[key],
      (final List<Object?> list, final int index) when index < list.length =>
        list[index],
      _ => null,
    };
    if (node == null) return null;
  }
  return node;
}

MockPoint? _location(Object? json) {
  if (json is! Map) return null;
  final lat = json['latitude'];
  final lng = json['longitude'];
  if (lat is! num || lng is! num) return null;
  return MockPoint.tryCreate(lat.toDouble(), lng.toDouble());
}

/// Short map links, such as `https://maps.app.goo.gl/…`, which carry no
/// coordinates until they are followed.
abstract final class MapsLinks {
  static const Set<String> _shortHosts = {
    'maps.app.goo.gl',
    'goo.gl',
    'g.co',
    'maps.apple',
  };

  static bool isShort(String text) {
    final uri = Uri.tryParse(text.trim());
    return uri != null &&
        uri.hasScheme &&
        _shortHosts.contains(uri.host.toLowerCase());
  }

  /// Follows [link]'s redirects without loading the page they end on, up to
  /// the first address that holds coordinates or a place name, and returns
  /// it; null if it could not be followed.
  static Future<String?> resolve(
    String link, {
    Duration timeout = const Duration(seconds: 8),
    @visibleForTesting HttpClient Function()? httpClient,
  }) async {
    final client = (httpClient ?? HttpClient.new)()
      ..connectionTimeout = timeout
      ..userAgent = defaultLookupUserAgent;
    var current = Uri.tryParse(link.trim());
    try {
      for (var hop = 0; current != null && hop < 5; hop++) {
        final request = await client.getUrl(current).timeout(timeout);
        request.followRedirects = false;
        final response = await request.close().timeout(timeout);
        unawaited(response.drain<void>().catchError((_) {}));
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (!response.isRedirect || location == null) {
          return hop == 0 ? null : current.toString();
        }
        final next = current.resolve(location);
        final resumed = next.queryParameters['continue'];
        current = resumed != null && next.host.startsWith('consent.')
            ? Uri.tryParse(resumed)
            : next;
        if (current != null && _namesAPlace(current.toString())) {
          return current.toString();
        }
      }
      return current?.toString();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

bool _namesAPlace(String link) =>
    pointsInLink(link).isNotEmpty || searchTextInLink(link) != null;

/// A JSON request with a deadline. A reply that is not 2xx becomes a
/// [LocationLookupException] carrying the service's own error message when
/// it sent one.
@visibleForTesting
Future<Object?> requestJson(
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
  Object? body,
  Duration timeout = const Duration(seconds: 10),
  HttpClient Function()? httpClient,
}) async {
  final client = (httpClient ?? HttpClient.new)()..connectionTimeout = timeout;
  try {
    final request = await client.openUrl(method, uri).timeout(timeout);
    headers.forEach(request.headers.set);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join().timeout(timeout);
    final Object? decoded;
    try {
      decoded = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      throw LocationLookupException('HTTP ${response.statusCode}');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LocationLookupException(
        _errorMessage(decoded) ?? 'HTTP ${response.statusCode}',
      );
    }
    return decoded;
  } on LocationLookupException {
    rethrow;
  } on TimeoutException {
    throw const LocationLookupException('Timed out');
  } on SocketException catch (error) {
    throw LocationLookupException(error.osError?.message ?? error.message);
  } on HandshakeException {
    throw const LocationLookupException('Secure connection failed');
  } on HttpException catch (error) {
    throw LocationLookupException(error.message);
  } finally {
    client.close(force: true);
  }
}

String? _errorMessage(Object? body) {
  if (body is! Map) return null;
  final error = body['error'];
  if (error is Map && error['message'] is String) {
    return error['message'] as String;
  }
  if (error is String) return error;
  final message = body['message'];
  return message is String ? message : null;
}
