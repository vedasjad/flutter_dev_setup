import 'dart:async';

import 'package:flutter_dev_setup/flutter_dev_setup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

final t0 = DateTime.utc(2026, 10, 24, 12);

// 1 km due north along a meridian, split in two.
final north = MockRoute(const [
  MockPoint(0, 0),
  MockPoint(0.0044966, 0),
  MockPoint(0.0089932, 0),
]);

// 36 km/h is 10 m/s, so seconds × 10 = metres.
MockLocationState playing({MockRouteEnd end = MockRouteEnd.stop}) =>
    const MockLocationState(
      speedKmh: 36,
    ).withRouteEnd(end, t0).withRoute(north, now: t0);

DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

void main() {
  group('MockRoute', () {
    test('measures its length and interpolates along it', () {
      expect(north.lengthMeters, closeTo(1000, 1));
      final (:point, :heading) = north.at(250);
      expect(point.latitude, closeTo(0.0022483, 1e-6));
      expect(heading, closeTo(0, 1e-6));
      expect(north.at(-5).point, north.points.first);
      expect(north.at(5000).point, north.points.last);
    });

    test('a single point stays put', () {
      final route = MockRoute(const [MockPoint(1, 2)]);
      expect(route.lengthMeters, 0);
      expect(route.at(10).point, const MockPoint(1, 2));
    });

    test('keeps the heading through a repeated point', () {
      final route = MockRoute(const [
        MockPoint(0, 0),
        MockPoint(0, 0.001),
        MockPoint(0, 0.001),
        MockPoint(0, 0.002),
      ]);
      expect(route.at(route.lengthMeters / 2).heading, closeTo(90, 1e-6));
    });
  });

  group('MockLocationState', () {
    test('is off by default and reports nothing', () {
      const state = MockLocationState();
      expect(state.isActive, isFalse);
      expect(state.positionAt(t0), isNull);
    });

    test('a point reports itself, still', () {
      final state = const MockLocationState().withPoint(
        const MockPoint(25.47, 80.33),
        name: 'Office',
      );
      final position = state.positionAt(t0)!;
      expect(position.point, const MockPoint(25.47, 80.33));
      expect(position.speed, 0);
      expect(state.pointName, 'Office');
    });

    test('keeps the point while switched off, and brings it back', () {
      final state = const MockLocationState()
          .withPoint(const MockPoint(25.47, 80.33))
          .withMode(MockMode.off, t0);
      expect(state.positionAt(t0), isNull);
      expect(state.withMode(MockMode.point, t0).positionAt(t0), isNotNull);
    });

    test('a route moves at its speed from the clock alone', () {
      final state = playing();
      expect(state.progressAt(at(30))!.along, closeTo(300, 1e-6));
      final position = state.positionAt(at(30))!;
      expect(position.latitude, closeTo(0.0026980, 1e-6));
      expect(position.speed, closeTo(10, 1e-9));
      expect(position.heading, closeTo(0, 1e-6));
    });

    test('stops at the end and reports itself finished', () {
      final state = playing();
      final progress = state.progressAt(at(150))!;
      expect(progress.finished, isTrue);
      expect(progress.along, closeTo(1000, 1));
      expect(state.positionAt(at(150))!.speed, 0);
    });

    test('a loop starts over', () {
      final state = playing(end: MockRouteEnd.loop);
      expect(state.progressAt(at(130))!.along, closeTo(300, 1));
      expect(state.progressAt(at(130))!.finished, isFalse);
    });

    test('back and forth turns round and faces the other way', () {
      final state = playing(end: MockRouteEnd.reverse);
      final progress = state.progressAt(at(130))!;
      expect(progress.reversed, isTrue);
      expect(progress.along, closeTo(700, 1));
      expect(state.positionAt(at(130))!.heading, closeTo(180, 1e-6));
      expect(state.progressAt(at(230))!.reversed, isFalse);
    });

    test('pausing holds the spot and playing carries on from it', () {
      final paused = playing().pause(at(20));
      expect(paused.playing, isFalse);
      expect(paused.progressAt(at(500))!.along, closeTo(200, 1e-6));
      expect(paused.positionAt(at(500))!.speed, 0);
      final resumed = paused.play(at(500));
      expect(resumed.progressAt(at(510))!.along, closeTo(300, 1e-6));
    });

    test('playing a finished route starts it again', () {
      final finished = playing();
      final replayed = finished.play(at(200));
      expect(replayed.progressAt(at(210))!.along, closeTo(100, 1e-6));
    });

    test('a new speed carries on from the same spot', () {
      final faster = playing().withSpeed(72, at(20));
      expect(faster.progressAt(at(20))!.along, closeTo(200, 1e-6));
      expect(faster.progressAt(at(30))!.along, closeTo(400, 1e-6));
    });

    test('a new speed keeps going the same way on the way back', () {
      final state = playing(end: MockRouteEnd.reverse).withSpeed(18, at(130));
      final progress = state.progressAt(at(140))!;
      expect(progress.reversed, isTrue);
      expect(progress.along, closeTo(650, 1));
    });

    test('a new route starts from its first point, playing', () {
      final state = playing().pause(at(50)).withRoute(north, now: at(60));
      expect(state.playing, isTrue);
      expect(state.progressAt(at(60))!.along, 0);
    });

    test('stops while another mode is in use and carries on after', () {
      final away = playing().withMode(MockMode.point, at(20));
      expect(away.playing, isFalse);
      expect(away.parked, isTrue);
      final back = MockLocationState.fromJson(
        away.toJson(),
      ).withMode(MockMode.route, at(500));
      expect(back.playing, isTrue);
      expect(back.parked, isFalse);
      expect(back.progressAt(at(510))!.along, closeTo(300, 1e-6));
    });

    test('a route paused by hand stays paused after another mode', () {
      final state = playing()
          .pause(at(20))
          .withMode(MockMode.off, at(30))
          .withMode(MockMode.route, at(90));
      expect(state.playing, isFalse);
      expect(state.progressAt(at(500))!.along, closeTo(200, 1e-6));
    });

    test('round-trips through JSON', () {
      final state = playing(end: MockRouteEnd.reverse)
          .withStops(const [
            MockPlace('A', MockPoint(0, 0)),
            MockPlace('B', MockPoint(0.0089932, 0), detail: 'north'),
          ])
          .pause(at(42));
      final copy = MockLocationState.fromJson(state.toJson());
      expect(copy.mode, MockMode.route);
      expect(copy.routeEnd, MockRouteEnd.reverse);
      expect(copy.speedKmh, 36);
      expect(copy.stops, state.stops);
      expect(copy.route!.points, north.points);
      expect(copy.playing, isFalse);
      expect(copy.progressAt(at(999))!.along, closeTo(420, 1e-6));
    });

    test('reads malformed JSON as off, keeping what it can', () {
      expect(MockLocationState.fromJson('nope').mode, MockMode.off);
      final state = MockLocationState.fromJson({
        'mode': 'teleport',
        'point': [25.4, 80.3],
        'speedKmh': -4,
        'route': 'x',
        'stops': [
          {
            'name': 'ok',
            'point': [1, 2],
          },
          {'name': 3},
        ],
      });
      expect(state.mode, MockMode.off);
      expect(state.point, const MockPoint(25.4, 80.3));
      expect(state.speedKmh, MockLocationState.defaultSpeedKmh);
      expect(state.route, isNull);
      expect(state.stops, hasLength(1));
    });
  });

  group('MockLocationStore', () {
    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    test('names its keys after the prefix', () {
      const store = MockLocationStore(keyPrefix: 'dev');
      expect(store.stateKey, 'devMockLocation');
      expect(store.placesKey, 'devMockPlaces');
    });

    test('round-trips the state and the places', () async {
      const store = MockLocationStore(keyPrefix: 'dev');
      expect((await store.state()).mode, MockMode.off);
      expect(await store.places(), isEmpty);

      await store.setState(
        const MockLocationState().withPoint(const MockPoint(25.4, 80.3)),
      );
      await store.setPlaces(const [MockPlace('Home', MockPoint(25.4, 80.3))]);

      expect((await store.state()).point, const MockPoint(25.4, 80.3));
      expect(await store.places(), const [
        MockPlace('Home', MockPoint(25.4, 80.3)),
      ]);
      expect(
        (await const MockLocationStore(keyPrefix: 'other').state()).mode,
        MockMode.off,
      );
    });

    test('reads a value of another type as unset', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({'devSetupMockLocation': 7});
      expect((await const MockLocationStore().state()).mode, MockMode.off);
    });
  });

  group('MockLocation', () {
    const store = MockLocationStore();
    const fix = MockPoint(25.4762689, 80.3395498);

    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    Future<void> mock(MockPoint? point) => store.setState(
      point == null
          ? const MockLocationState()
          : const MockLocationState().withPoint(point),
    );

    test('current is null while off and the point while on', () async {
      expect(await MockLocation.current(), isNull);
      await mock(fix);
      expect((await MockLocation.current())!.point, fix);
    });

    test('overlay passes the real stream through while off', () async {
      final real = StreamController<String>();
      final out = <String>[];
      final sub = MockLocation.overlay(
        real.stream,
        (p) => 'mock',
        interval: const Duration(milliseconds: 10),
      ).listen(out.add);
      await pumpFor(const Duration(milliseconds: 20));
      real.add('gps');
      await pumpFor(const Duration(milliseconds: 20));
      expect(out, ['gps']);
      await sub.cancel();
    });

    test('overlay swaps to the mock and back as the setting changes', () async {
      final real = StreamController<String>();
      final errors = <Object>[];
      final out = <String>[];
      final sub = MockLocation.overlay(
        real.stream,
        (p) => 'mock ${p.latitude}',
        interval: const Duration(milliseconds: 10),
      ).listen(out.add, onError: errors.add);
      await pumpFor(const Duration(milliseconds: 20));

      await mock(fix);
      await pumpFor(const Duration(milliseconds: 30));
      real
        ..add('gps while mocked')
        ..addError(StateError('no fix'));
      await pumpFor(const Duration(milliseconds: 30));
      expect(out, ['mock 25.4762689']);
      expect(errors, isEmpty);

      await mock(null);
      await pumpFor(const Duration(milliseconds: 30));
      real.add('gps again');
      await pumpFor(const Duration(milliseconds: 10));
      expect(out, ['mock 25.4762689', 'gps again']);

      await mock(fix);
      await pumpFor(const Duration(milliseconds: 30));
      expect(out.last, 'mock 25.4762689');
      await sub.cancel();
    });

    test('overlay sends a moving route on every tick', () async {
      await store.setState(
        const MockLocationState(
          speedKmh: 360,
        ).withRoute(north, now: DateTime.now()),
      );
      final out = <MockPosition>[];
      final sub = MockLocation.overlay(
        const Stream<MockPosition>.empty(),
        (p) => p,
        interval: const Duration(milliseconds: 20),
      ).listen(out.add);
      await pumpFor(const Duration(milliseconds: 110));
      await sub.cancel();
      expect(out.length, greaterThanOrEqualTo(3));
      expect(out.last.latitude, greaterThan(out.first.latitude));
    });

    test('overlay ends once the real stream has and mocking is off', () async {
      await mock(fix);
      final real = StreamController<String>();
      final done = Completer<void>();
      MockLocation.overlay(
        real.stream,
        (p) => 'mock',
        interval: const Duration(milliseconds: 10),
      ).listen(null, onDone: done.complete);
      await pumpFor(const Duration(milliseconds: 20));
      await real.close();
      await pumpFor(const Duration(milliseconds: 30));
      expect(done.isCompleted, isFalse);
      await mock(null);
      await done.future.timeout(const Duration(seconds: 1));
    });

    test(
      'a listener that leaves before the first read leaks nothing',
      () async {
        final real = StreamController<String>(
          onListen: () => fail('subscribed after the listener left'),
        );
        final sub = MockLocation.overlay(
          real.stream,
          (p) => 'mock',
        ).listen(null);
        await sub.cancel();
        await pumpFor(const Duration(milliseconds: 20));
      },
    );
  });
}

Future<void> pumpFor(Duration duration) => Future<void>.delayed(duration);
