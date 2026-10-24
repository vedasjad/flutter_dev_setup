import 'dart:math' as math;

import 'geo.dart';

/// A named point: one the developer saved, one the app supplies, or a search
/// result.
class MockPlace {
  const MockPlace(this.name, this.point, {this.detail});

  final String name;
  final MockPoint point;

  /// A second line, such as the address a search returned.
  final String? detail;

  MockPlace copyWith({String? name}) =>
      MockPlace(name ?? this.name, point, detail: detail);

  Map<String, Object?> toJson() => {
    'name': name,
    'point': point.toJson(),
    'detail': ?detail,
  };

  static MockPlace? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final point = MockPoint.fromJson(json['point']);
    final detail = json['detail'];
    if (name is! String || point == null) return null;
    return MockPlace(name, point, detail: detail is String ? detail : null);
  }

  @override
  bool operator ==(Object other) =>
      other is MockPlace &&
      other.name == name &&
      other.point == point &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(name, point, detail);
}

/// What a route does when it reaches its last point.
enum MockRouteEnd {
  stop,
  loop,

  /// Turns round and comes back, and keeps going back and forth.
  reverse,
}

/// A path to move along: the points of the road, not just the stops.
class MockRoute {
  MockRoute(List<MockPoint> points)
    : assert(points.isNotEmpty, 'A route needs at least one point'),
      points = List.unmodifiable(points) {
    var total = 0.0;
    _cumulative.add(0);
    for (var i = 1; i < this.points.length; i++) {
      total += this.points[i - 1].distanceTo(this.points[i]);
      _cumulative.add(total);
    }
  }

  final List<MockPoint> points;
  final List<double> _cumulative = [];

  double get lengthMeters => _cumulative.isEmpty ? 0 : _cumulative.last;

  /// The point [meters] along the route, clamped to its ends, with the
  /// direction of travel there.
  ({MockPoint point, double heading}) at(double meters) {
    if (points.length == 1) return (point: points.single, heading: 0);
    final along = meters.clamp(0.0, lengthMeters);
    var segment = 0;
    while (segment < points.length - 2 && _cumulative[segment + 1] < along) {
      segment++;
    }
    while (segment > 0 && _cumulative[segment + 1] == _cumulative[segment]) {
      segment--;
    }
    final start = points[segment];
    final end = points[segment + 1];
    final span = _cumulative[segment + 1] - _cumulative[segment];
    final t = span == 0 ? 0.0 : (along - _cumulative[segment]) / span;
    return (point: start.lerp(end, t), heading: start.bearingTo(end));
  }

  List<List<double>> toJson() => [for (final p in points) p.toJson()];

  static MockRoute? fromJson(Object? json) {
    if (json is! List) return null;
    final points = [for (final p in json) ?MockPoint.fromJson(p)];
    return points.isEmpty ? null : MockRoute(points);
  }
}

enum MockMode { off, point, route }

/// A fix as the app should report it.
class MockPosition {
  const MockPosition({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracy = 5,
    this.altitude = 0,
    this.heading = 0,
    this.speed = 0,
  });

  final double latitude;
  final double longitude;
  final DateTime timestamp;

  /// Metres.
  final double accuracy;
  final double altitude;

  /// Degrees clockwise from north.
  final double heading;

  /// Metres per second.
  final double speed;

  MockPoint get point => MockPoint(latitude, longitude);

  bool sameFixAs(MockPosition other) =>
      latitude == other.latitude &&
      longitude == other.longitude &&
      heading == other.heading &&
      speed == other.speed;
}

/// Where the route stands at a moment.
typedef RouteProgress = ({
  /// Metres from the first point.
  double along,
  bool finished,
  bool reversed,
});

/// Everything that decides the mocked location, as it is stored.
///
/// Playback is kept as a distance and the moment it last resumed, never as a
/// running position, so every reader — another isolate, or the app after a
/// restart — works out the same position from the clock alone.
class MockLocationState {
  const MockLocationState({
    this.mode = MockMode.off,
    this.point,
    this.pointName,
    this.stops = const [],
    this.route,
    this.speedKmh = defaultSpeedKmh,
    this.routeEnd = MockRouteEnd.loop,
    this.offsetMeters = 0,
    this.resumedAt,
    this.parked = false,
  });

  final MockMode mode;
  final MockPoint? point;

  /// The place [point] came from, when it came from one.
  final String? pointName;

  /// The stops the developer chose, which [route] was built through.
  final List<MockPlace> stops;
  final MockRoute? route;
  final double speedKmh;
  final MockRouteEnd routeEnd;

  /// Distance covered up to [resumedAt], or up to the pause.
  final double offsetMeters;

  /// When playback last started; null while paused.
  final DateTime? resumedAt;

  /// Paused by leaving route mode while it played, to carry on on return.
  final bool parked;

  static const double defaultSpeedKmh = 25;

  bool get playing => resumedAt != null;
  double get speedMps => speedKmh / 3.6;

  bool get isActive => switch (mode) {
    MockMode.off => false,
    MockMode.point => point != null,
    MockMode.route => route != null,
  };

  double _travelled(DateTime now) {
    final since = resumedAt;
    if (since == null) return offsetMeters;
    final seconds = math.max(0, now.difference(since).inMicroseconds) / 1e6;
    return offsetMeters + seconds * speedMps;
  }

  RouteProgress? progressAt(DateTime now) {
    final route = this.route;
    if (route == null) return null;
    final length = route.lengthMeters;
    final travelled = _travelled(now);
    if (length <= 0) return (along: 0, finished: false, reversed: false);
    return switch (routeEnd) {
      MockRouteEnd.stop => (
        along: math.min(travelled, length),
        finished: travelled >= length,
        reversed: false,
      ),
      MockRouteEnd.loop => (
        along: travelled % length,
        finished: false,
        reversed: false,
      ),
      MockRouteEnd.reverse => () {
        final lap = travelled % (2 * length);
        return lap <= length
            ? (along: lap, finished: false, reversed: false)
            : (along: 2 * length - lap, finished: false, reversed: true);
      }(),
    };
  }

  /// The mocked position at [now], or null when mocking is off.
  MockPosition? positionAt(DateTime now) {
    switch (mode) {
      case MockMode.off:
        return null;
      case MockMode.point:
        final point = this.point;
        if (point == null) return null;
        return MockPosition(
          latitude: point.latitude,
          longitude: point.longitude,
          timestamp: now,
        );
      case MockMode.route:
        final route = this.route;
        final progress = progressAt(now);
        if (route == null || progress == null) return null;
        final (:point, :heading) = route.at(progress.along);
        final moving = playing && !progress.finished && route.lengthMeters > 0;
        return MockPosition(
          latitude: point.latitude,
          longitude: point.longitude,
          timestamp: now,
          heading: progress.reversed ? (heading + 180) % 360 : heading,
          speed: moving ? speedMps : 0,
        );
    }
  }

  MockLocationState _copy({
    MockMode? mode,
    MockPoint? Function()? point,
    String? Function()? pointName,
    List<MockPlace>? stops,
    MockRoute? Function()? route,
    double? speedKmh,
    MockRouteEnd? routeEnd,
    double? offsetMeters,
    DateTime? Function()? resumedAt,
    bool? parked,
  }) => MockLocationState(
    mode: mode ?? this.mode,
    point: point == null ? this.point : point(),
    pointName: pointName == null ? this.pointName : pointName(),
    stops: stops ?? this.stops,
    route: route == null ? this.route : route(),
    speedKmh: speedKmh ?? this.speedKmh,
    routeEnd: routeEnd ?? this.routeEnd,
    offsetMeters: offsetMeters ?? this.offsetMeters,
    resumedAt: resumedAt == null ? this.resumedAt : resumedAt(),
    parked: parked ?? this.parked,
  );

  /// A route stops where it is while another mode is in use, and carries on
  /// from there when route mode comes back, if it was playing.
  MockLocationState withMode(MockMode mode, DateTime now) {
    if (mode == this.mode) return this;
    if (this.mode == MockMode.route && playing) {
      return pause(now)._copy(mode: mode, parked: true);
    }
    if (mode == MockMode.route && parked) {
      return _copy(mode: mode, resumedAt: () => now, parked: false);
    }
    return _copy(mode: mode);
  }

  MockLocationState withPoint(MockPoint point, {String? name}) =>
      _copy(mode: MockMode.point, point: () => point, pointName: () => name);

  MockLocationState withStops(List<MockPlace> stops) =>
      _copy(stops: List.unmodifiable(stops));

  /// A new route starts from its first point, playing.
  MockLocationState withRoute(MockRoute route, {required DateTime now}) =>
      _copy(
        mode: MockMode.route,
        route: () => route,
        offsetMeters: 0,
        resumedAt: () => now,
        parked: false,
      );

  MockLocationState play(DateTime now) {
    if (playing && !(progressAt(now)?.finished ?? false)) return this;
    final finished = progressAt(now)?.finished ?? false;
    return _copy(offsetMeters: finished ? 0 : null, resumedAt: () => now);
  }

  MockLocationState pause(DateTime now) => !playing
      ? this
      : _copy(offsetMeters: _settled(now), resumedAt: () => null);

  MockLocationState restart(DateTime now) =>
      _copy(offsetMeters: 0, resumedAt: () => now);

  /// Carries on from where the route is now, at the new speed.
  MockLocationState withSpeed(double kmh, DateTime now) => _copy(
    speedKmh: kmh,
    offsetMeters: _settled(now),
    resumedAt: () => playing ? now : null,
  );

  /// Carries on forward from where the route is now.
  MockLocationState withRouteEnd(MockRouteEnd end, DateTime now) => _copy(
    routeEnd: end,
    offsetMeters: progressAt(now)?.along ?? 0,
    resumedAt: () => playing ? now : null,
  );

  /// Travelled distance folded into one pass, so a later change of speed or
  /// end behaviour picks up from the same spot.
  double _settled(DateTime now) {
    final progress = progressAt(now);
    if (progress == null) return _travelled(now);
    final length = route!.lengthMeters;
    return progress.reversed ? 2 * length - progress.along : progress.along;
  }

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'point': ?point?.toJson(),
    'pointName': ?pointName,
    if (stops.isNotEmpty) 'stops': [for (final s in stops) s.toJson()],
    'route': ?route?.toJson(),
    'speedKmh': speedKmh,
    'routeEnd': routeEnd.name,
    'offsetMeters': offsetMeters,
    'resumedAt': ?resumedAt?.millisecondsSinceEpoch,
    if (parked) 'parked': true,
  };

  static MockLocationState fromJson(Object? json) {
    if (json is! Map) return const MockLocationState();
    T? named<T extends Enum>(List<T> values, Object? name) {
      for (final value in values) {
        if (value.name == name) return value;
      }
      return null;
    }

    final stops = json['stops'];
    final speed = json['speedKmh'];
    final offset = json['offsetMeters'];
    final resumed = json['resumedAt'];
    final pointName = json['pointName'];
    return MockLocationState(
      mode: named(MockMode.values, json['mode']) ?? MockMode.off,
      point: MockPoint.fromJson(json['point']),
      pointName: pointName is String ? pointName : null,
      stops: stops is List
          ? List.unmodifiable([for (final s in stops) ?MockPlace.fromJson(s)])
          : const [],
      route: MockRoute.fromJson(json['route']),
      speedKmh: speed is num && speed > 0 ? speed.toDouble() : defaultSpeedKmh,
      routeEnd:
          named(MockRouteEnd.values, json['routeEnd']) ?? MockRouteEnd.loop,
      offsetMeters: offset is num && offset >= 0 ? offset.toDouble() : 0,
      resumedAt: resumed is int
          ? DateTime.fromMillisecondsSinceEpoch(resumed)
          : null,
      parked: json['parked'] == true,
    );
  }
}
