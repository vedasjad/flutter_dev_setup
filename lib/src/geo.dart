import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// A latitude and longitude, in degrees.
class MockPoint {
  const MockPoint(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  /// Null unless both are finite and in range.
  static MockPoint? tryCreate(double latitude, double longitude) =>
      latitude.isFinite &&
          longitude.isFinite &&
          latitude.abs() <= 90 &&
          longitude.abs() <= 180
      ? MockPoint(latitude, longitude)
      : null;

  /// Great-circle distance in metres.
  double distanceTo(MockPoint other) {
    final lat1 = _radians(latitude);
    final lat2 = _radians(other.latitude);
    final dLat = lat2 - lat1;
    final dLng = _radians(other.longitude - longitude);
    final a =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLng / 2), 2);
    return 2 * _earthRadius * math.asin(math.min(1, math.sqrt(a)));
  }

  /// Initial bearing toward [other], clockwise from north in [0, 360).
  double bearingTo(MockPoint other) {
    final lat1 = _radians(latitude);
    final lat2 = _radians(other.latitude);
    final dLng = _radians(other.longitude - longitude);
    final y = math.sin(dLng) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return (_degrees(math.atan2(y, x)) + 360) % 360;
  }

  /// Linear in degrees, which is close enough over a road segment.
  MockPoint lerp(MockPoint other, double t) => MockPoint(
    latitude + (other.latitude - latitude) * t,
    longitude + (other.longitude - longitude) * t,
  );

  String format({int digits = 6}) =>
      '${latitude.toStringAsFixed(digits)}, ${longitude.toStringAsFixed(digits)}';

  List<double> toJson() => [latitude, longitude];

  static MockPoint? fromJson(Object? json) {
    if (json is! List || json.length != 2) return null;
    final [lat, lng] = json;
    if (lat is! num || lng is! num) return null;
    return tryCreate(lat.toDouble(), lng.toDouble());
  }

  @override
  bool operator ==(Object other) =>
      other is MockPoint &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() => 'MockPoint(${format()})';

  static const double _earthRadius = 6371008.8;
  static double _radians(double degrees) => degrees * math.pi / 180;
  static double _degrees(double radians) => radians * 180 / math.pi;
}

/// Every point written in [text], in order, or an empty list when any part of
/// it is not a point.
///
/// Reads decimal degrees (`25.4775, 80.3349`, optionally with N/S/E/W),
/// degrees-minutes-seconds as Google Maps shows them (`25°28'39.0"N
/// 80°20'05.6"E`), a `geo:` URI, and Google Maps links. A directions link
/// gives one point per stop written as coordinates; a place link gives the
/// pin rather than the middle of the map. Several points can be given one per
/// line, or separated by `;` or `|`.
List<MockPoint> parsePoints(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];
  if (_looksLikeLink(trimmed)) return pointsInLink(trimmed);
  final parts = trimmed
      .split(RegExp(r'[\n;|]'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
  final points = <MockPoint>[];
  for (final part in parts) {
    final point = _pair(part);
    if (point == null) return const [];
    points.add(point);
  }
  return points;
}

/// The single point in [text], or null when it holds none or several.
MockPoint? parsePoint(String text) {
  final points = parsePoints(text);
  return points.length == 1 ? points.single : null;
}

/// The points a pasted route holds: coordinates one per line, a directions
/// link's stops, or an encoded polyline.
List<MockPoint> routePoints(String text) {
  final trimmed = text.trim();
  final points = parsePoints(trimmed);
  if (points.length >= 2 || trimmed.contains(RegExp(r'\s'))) return points;
  return decodePolyline(trimmed);
}

bool _looksLikeLink(String text) =>
    text.contains('://') || text.toLowerCase().startsWith('geo:');

/// Points written into a map link. Short links (`maps.app.goo.gl`) carry
/// none until they are resolved.
List<MockPoint> pointsInLink(String link) {
  try {
    return _pointsInLink(link);
  } on FormatException {
    return const [];
  } on ArgumentError {
    return const [];
  }
}

List<MockPoint> _pointsInLink(String link) {
  final trimmed = link.trim();
  if (trimmed.toLowerCase().startsWith('geo:')) {
    final body = trimmed.substring(4).split(RegExp(r'[?;]')).first;
    final point = _pair(Uri.decodeComponent(body));
    return point == null ? const [] : [point];
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return const [];
  final raw = Uri.decodeFull(trimmed);
  if (uri.pathSegments.contains('dir')) {
    return [for (final stop in _dirStops(uri, raw)) stop.point];
  }

  final pins = _pinPattern
      .allMatches(raw)
      .map(
        (m) => MockPoint.tryCreate(double.parse(m[1]!), double.parse(m[2]!)),
      );
  if (pins.nonNulls.isNotEmpty) return [pins.nonNulls.first];

  final segments = uri.pathSegments.map(
    (segment) => segment.replaceAll('+', ' '),
  );
  final inPath = [for (final segment in segments) ?_pair(segment)];
  if (inPath.isNotEmpty) return inPath;

  for (final name in _pointParams) {
    final value = uri.queryParameters[name];
    if (value == null) continue;
    final point = _pair(value.replaceAll('+', ' '));
    if (point != null) return [point];
  }

  final centre = _centrePattern.firstMatch(raw);
  if (centre != null) {
    final point = MockPoint.tryCreate(
      double.parse(centre[1]!),
      double.parse(centre[2]!),
    );
    if (point != null) return [point];
  }
  return const [];
}

typedef LinkStop = ({String? name, MockPoint point});

/// The stops of a Google Maps directions link, in order, named when the link
/// names them. A shared route carries its stops but not the road between
/// them. Empty for any other link.
List<LinkStop> stopsInLink(String link) {
  try {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || !uri.pathSegments.contains('dir')) return const [];
    return _dirStops(uri, Uri.decodeFull(link.trim()));
  } on FormatException {
    return const [];
  } on ArgumentError {
    return const [];
  }
}

/// Stops written as coordinates sit in the path. Named ones sit in the path
/// by name, and their coordinates in the data blob as `!1d<lng>!2d<lat>`, in
/// the same order.
List<LinkStop> _dirStops(Uri uri, String raw) {
  final segments = uri.pathSegments;
  final written = [
    for (final segment in segments.skip(segments.indexOf('dir') + 1))
      if (segment.isNotEmpty &&
          !segment.startsWith('@') &&
          !segment.startsWith('data='))
        segment.replaceAll('+', ' ').trim(),
  ];
  final located = [
    for (final m in _dirStopPattern.allMatches(raw))
      ?MockPoint.tryCreate(double.parse(m[2]!), double.parse(m[1]!)),
  ];
  String? nameOf(String stop) => _pair(stop) == null ? stop : null;
  if (located.length == written.length) {
    return [
      for (var i = 0; i < written.length; i++)
        (name: nameOf(written[i]), point: located[i]),
    ];
  }
  final named = written.where((stop) => nameOf(stop) != null).length;
  if (located.length != named) {
    return [
      for (final stop in written)
        if (_pair(stop) case final point?) (name: null, point: point),
    ];
  }
  var next = 0;
  return [
    for (final stop in written)
      switch (_pair(stop)) {
        final point? => (name: null, point: point),
        null => (name: stop, point: located[next++]),
      },
  ];
}

/// The text a map link searches for, such as `?q=Banda+Railway+Station`, when
/// it has no coordinates to give.
String? searchTextInLink(String link) {
  try {
    return _searchTextInLink(link);
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

String? _searchTextInLink(String link) {
  final uri = Uri.tryParse(link.trim());
  if (uri == null) return null;
  for (final name in const [
    'q',
    'query',
    'name',
    'address',
    'destination',
    'daddr',
  ]) {
    final value = uri.queryParameters[name]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  final segments = uri.pathSegments;
  for (final marker in const ['place', 'search']) {
    final index = segments.indexOf(marker);
    if (index >= 0 && index + 1 < segments.length) {
      final value = segments[index + 1].replaceAll('+', ' ').trim();
      if (value.isNotEmpty && !value.startsWith('@')) return value;
    }
  }
  return null;
}

/// Roughly where a Google Maps link's place is, from its feature id
/// (`!1s0x…:0x…` or `ftid=0x…:0x…`), for a link that names a place without
/// its coordinates. The id's first half is an S2 cell near the place, often
/// a kilometre off, so it only says where to search.
MockPoint? approximatePointInLink(String link) {
  final match = _featureIdPattern.firstMatch(link);
  if (match == null) return null;
  final id = BigInt.tryParse(match[1]!, radix: 16);
  if (id == null || id.bitLength > 64) return null;
  return s2CellCentre(id.toSigned(64).toInt());
}

/// The centre of a leaf S2 cell, or null for any other id.
@visibleForTesting
MockPoint? s2CellCentre(int id) {
  final face = id >>> 61;
  if (face > 5 || id & 1 != 1) return null;
  var i = 0;
  var j = 0;
  var orientation = face & _s2Swap;
  for (var level = 1; level <= 30; level++) {
    final position = (id >>> (61 - 2 * level)) & 3;
    final ij = _s2PositionToIj[orientation][position];
    i = (i << 1) | (ij >> 1);
    j = (j << 1) | (ij & 1);
    orientation ^= _s2PositionToOrientation[position];
  }
  double uv(int k) {
    final s = (k + 0.5) / (1 << 30);
    return s >= 0.5 ? (4 * s * s - 1) / 3 : (1 - 4 * (1 - s) * (1 - s)) / 3;
  }

  final u = uv(i);
  final v = uv(j);
  final (x, y, z) = switch (face) {
    0 => (1.0, u, v),
    1 => (-u, 1.0, v),
    2 => (-u, -v, 1.0),
    3 => (-1.0, -v, -u),
    4 => (v, -1.0, -u),
    _ => (v, u, -1.0),
  };
  return MockPoint.tryCreate(
    math.atan2(z, math.sqrt(x * x + y * y)) * 180 / math.pi,
    math.atan2(y, x) * 180 / math.pi,
  );
}

const int _s2Swap = 1;
const int _s2Invert = 2;
const List<List<int>> _s2PositionToIj = [
  [0, 1, 3, 2],
  [0, 2, 3, 1],
  [3, 2, 0, 1],
  [3, 1, 0, 2],
];
const List<int> _s2PositionToOrientation = [_s2Swap, 0, 0, _s2Invert | _s2Swap];

final RegExp _featureIdPattern = RegExp(
  r'(?:!1s|ftid=)0x([0-9a-fA-F]{1,16}):0x[0-9a-fA-F]+',
);

/// Google's encoded polyline format, as the Directions and Routes APIs return
/// it. [precision] is 5 for those, 6 for OSRM's `polyline6`.
List<MockPoint> decodePolyline(String encoded, {int precision = 5}) {
  final factor = math.pow(10, precision).toDouble();
  final points = <MockPoint>[];
  var index = 0;
  var lat = 0;
  var lng = 0;
  int? next() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (index >= encoded.length) return null;
      final byte = encoded.codeUnitAt(index++) - 63;
      if (byte < 0 || byte > 63 || shift > 30) return null;
      result |= (byte & 0x1f) << shift;
      shift += 5;
      if (byte < 0x20) break;
    }
    return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
  }

  while (index < encoded.length) {
    final dLat = next();
    final dLng = next();
    if (dLat == null || dLng == null) return const [];
    lat += dLat;
    lng += dLng;
    final point = MockPoint.tryCreate(lat / factor, lng / factor);
    if (point == null) return const [];
    points.add(point);
  }
  return points;
}

MockPoint? _pair(String text) => _decimal(text) ?? _dms(text);

MockPoint? _decimal(String text) {
  final match = _decimalPattern.firstMatch(text.trim());
  if (match == null) return null;
  var lat = double.parse(match[1]!);
  var lng = double.parse(match[3]!);
  if (match[2]?.toUpperCase() == 'S') lat = -lat;
  if (match[4]?.toUpperCase() == 'W') lng = -lng;
  return MockPoint.tryCreate(lat, lng);
}

MockPoint? _dms(String text) {
  final match = _dmsPattern.firstMatch(text.trim());
  if (match == null) return null;
  double part(int at) =>
      double.parse(match[at]!) +
      double.parse(match[at + 1]!) / 60 +
      double.parse(match[at + 2]!) / 3600;
  var lat = part(1);
  var lng = part(5);
  if (match[4]!.toUpperCase() == 'S') lat = -lat;
  if (match[8]!.toUpperCase() == 'W') lng = -lng;
  return MockPoint.tryCreate(lat, lng);
}

final RegExp _decimalPattern = RegExp(
  r'^\(?\s*([-+]?\d{1,3}\.\d+)\s*°?\s*([NS])?\s*[,\s]\s*([-+]?\d{1,3}\.\d+)\s*°?\s*([EW])?\s*\)?$',
  caseSensitive: false,
);

final RegExp _dmsPattern = RegExp(
  r'''^(\d{1,3})°\s*(\d{1,2})['′]\s*(\d{1,2}(?:\.\d+)?)["″]?\s*([NS])[\s,]*(\d{1,3})°\s*(\d{1,2})['′]\s*(\d{1,2}(?:\.\d+)?)["″]?\s*([EW])$''',
  caseSensitive: false,
);

final RegExp _pinPattern = RegExp(r'!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)');

final RegExp _centrePattern = RegExp(r'@(-?\d+\.\d+),(-?\d+\.\d+)');

final RegExp _dirStopPattern = RegExp(
  r'!1d(-?\d+(?:\.\d+)?)!2d(-?\d+(?:\.\d+)?)',
);

const List<String> _pointParams = [
  'q',
  'query',
  'll',
  'coordinate',
  'sll',
  'center',
  'destination',
  'daddr',
];
