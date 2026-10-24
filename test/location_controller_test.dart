import 'package:flutter/foundation.dart';
import 'package:flutter_dev_setup/flutter_dev_setup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'geo_test.dart' show routeLink;

const office = MockPlace('Office', MockPoint(25.4762689, 80.3395498));
const station = MockPlace(
  'Banda',
  MockPoint(25.47752, 80.33492),
  detail: 'Station Road, Banda',
);

class FakeSearch implements PlaceSearch {
  FakeSearch({this.results = const [station], this.error});

  final List<MockPlace> results;
  int located = 0;
  final Object? error;
  final List<(String, MockPoint?)> queries = [];

  @override
  Future<List<PlaceResult>> search(String query, {MockPoint? near}) async {
    queries.add((query, near));
    if (error case final error?) throw error;
    return [
      for (final place in results)
        PlaceResult(place.name, point: place.point, detail: place.detail),
    ];
  }
}

class FakeRouter implements RouteFinder {
  FakeRouter({this.error});

  final Object? error;
  final List<List<MockPoint>> calls = [];

  @override
  Future<List<MockPoint>> route(List<MockPoint> stops) async {
    calls.add(stops);
    if (error case final error?) throw error;
    return [stops.first, const MockPoint(25.5, 80.35), stops.last];
  }
}

void main() {
  late DateTime clock;
  late FakeSearch search;
  late FakeRouter router;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    clock = DateTime.utc(2026, 10, 24, 12);
    search = FakeSearch();
    router = FakeRouter();
  });

  Future<MockLocationController> make({
    List<MockPlace> places = const [office],
    PlaceSearch? placeSearch,
    RouteFinder? routeFinder,
    bool noSearch = false,
    bool noRouter = false,
  }) async {
    final controller = MockLocationController(
      config: MockLocationConfig(
        places: places,
        placeSearch: noSearch ? null : placeSearch ?? search,
        routeFinder: noRouter ? null : routeFinder ?? router,
      ),
      clock: () => clock,
    );
    addTearDown(controller.dispose);
    await controller.init();
    return controller;
  }

  Future<void> submit(MockLocationController c, String text) {
    c.queryController.text = text;
    return c.submitQuery();
  }

  group('point mode', () {
    test('typed coordinates become the point, without searching', () async {
      final c = await make();
      await c.setMode(MockMode.point);
      await submit(c, '25.4775, 80.3349');
      expect(c.state.point, const MockPoint(25.4775, 80.3349));
      expect(c.position!.point, const MockPoint(25.4775, 80.3349));
      expect(search.queries, isEmpty);
      expect(c.queryController.text, isEmpty);
      expect((await c.store.state()).point, const MockPoint(25.4775, 80.3349));
    });

    test('a place link becomes the point under its name', () async {
      final c = await make();
      await c.setMode(MockMode.point);
      await submit(
        c,
        'https://www.google.com/maps/place/Banda,+Uttar+Pradesh+210001/'
        '@25.47,80.34,13z/data=!8m2!3d25.4762689!4d80.3395498',
      );
      expect(c.state.point, office.point);
      expect(c.state.pointName, 'Banda, Uttar Pradesh 210001');
    });

    test(
      'a link naming a place by its coordinates leaves it unnamed',
      () async {
        final c = await make();
        await c.setMode(MockMode.point);
        await submit(c, 'https://maps.google.com/?q=25.4775,80.3349');
        expect(c.state.point, const MockPoint(25.4775, 80.3349));
        expect(c.state.pointName, isNull);
      },
    );

    test('anything else is searched near the point in use', () async {
      final c = await make();
      await c.setMode(MockMode.point);
      await submit(c, 'banda railway station');
      expect(search.queries, [('banda railway station', office.point)]);
      expect(c.lookupPhase, LookupPhase.results);
      expect(c.results.single.name, 'Banda');
      expect(c.results.single.point, station.point);

      await c.chooseResult(c.results.single);
      expect(c.state.point, station.point);
      expect(c.state.pointName, 'Banda');
      expect(c.results, isEmpty);
    });

    test('without a point, searches around the search centre', () async {
      final c = MockLocationController(
        config: MockLocationConfig(
          places: const [office],
          placeSearch: search,
          searchCenter: const MockPoint(26.45, 80.33),
        ),
        clock: () => clock,
      );
      addTearDown(c.dispose);
      await c.init();
      await c.setMode(MockMode.point);
      await submit(c, 'kanpur central');
      expect(search.queries.single.$2, const MockPoint(26.45, 80.33));
    });

    test('says when a search finds nothing or fails', () async {
      final empty = await make(placeSearch: FakeSearch(results: const []));
      await empty.setMode(MockMode.point);
      await submit(empty, 'nowhere');
      expect(empty.lookupPhase, LookupPhase.nothingFound);

      final broken = await make(
        placeSearch: FakeSearch(error: const LocationLookupException('down')),
      );
      await broken.setMode(MockMode.point);
      await submit(broken, 'banda');
      expect(broken.lookupPhase, LookupPhase.failed);
      expect(broken.lookupError, 'down');
    });

    test('a link with only a name is searched around its place', () async {
      const link =
          'https://www.google.com/maps/place/Ladaka+Purwa,+Banda/data=!4m2'
          '!3m1!1s0x399ccec35eaed679:0x7e4016436e3c2249';
      final c = await make(placeSearch: FakeSearch(results: const []));
      await c.setMode(MockMode.point);
      await submit(c, link);
      expect(c.lookupPhase, LookupPhase.linkNotFound);
      final (query, near) =
          (c.config.placeSearch! as FakeSearch).queries.single;
      expect(query, 'Ladaka Purwa, Banda');
      expect(near, approximatePointInLink(link));
      expect(near, isNot(office.point));
    });

    test('without a search, text that holds no point says so', () async {
      final c = await make(noSearch: true);
      await c.setMode(MockMode.point);
      await submit(c, 'banda');
      expect(c.lookupPhase, LookupPhase.noPoints);
    });

    test('several points are offered to pick from', () async {
      final c = await make();
      await c.setMode(MockMode.point);
      await submit(c, '25.1, 80.1\n25.2, 80.2');
      expect(c.lookupPhase, LookupPhase.results);
      expect(c.results, hasLength(2));
      expect(c.state.point, isNull);
    });
  });

  group('results without a point', () {
    late int lookups;
    PlaceSearch lazy() => PlaceSearch.from(
      (query, near) async => [
        PlaceResult(
          'Ladaka Purwa',
          detail: 'Banda, Uttar Pradesh',
          locate: () async {
            lookups++;
            return const MockPoint(25.4779779, 80.3575128);
          },
        ),
        PlaceResult(
          'Nowhere',
          locate: () async {
            lookups++;
            return null;
          },
        ),
      ],
    );

    setUp(() => lookups = 0);

    test('are looked up only when picked', () async {
      final c = await make(placeSearch: lazy());
      await c.setMode(MockMode.point);
      await submit(c, 'ladaka purwa');
      expect(lookups, 0);
      expect(c.results.first.point, isNull);

      await c.chooseResult(c.results.first);
      expect(lookups, 1);
      expect(c.state.point, const MockPoint(25.4779779, 80.3575128));
      expect(c.state.pointName, 'Ladaka Purwa');
    });

    test('say so when the lookup finds nothing', () async {
      final c = await make(placeSearch: lazy());
      await c.setMode(MockMode.point);
      await submit(c, 'nowhere');
      await c.chooseResult(c.results.last);
      expect(c.lookupPhase, LookupPhase.noPoints);
      expect(c.state.point, isNull);
    });

    test('become stops in route mode', () async {
      final c = await make(placeSearch: lazy());
      await c.setMode(MockMode.route);
      await submit(c, 'ladaka purwa');
      await c.chooseResult(c.results.first);
      expect(c.state.stops.single.name, 'Ladaka Purwa');
    });

    test('are looked up to be saved, and the results stay', () async {
      final c = await make(placeSearch: lazy(), places: const []);
      await c.setMode(MockMode.point);
      await submit(c, 'ladaka purwa');
      await c.saveResult('Ladaka', c.results.first);
      expect(
        c.savedPlaces.single.point,
        const MockPoint(25.4779779, 80.3575128),
      );
      expect(c.savedPlaces.single.detail, 'Banda, Uttar Pradesh');
      expect(c.results, hasLength(2));
      expect(c.lookupPhase, LookupPhase.results);
    });
  });

  test("RouteFinder.from routes with the app's own function", () async {
    final seen = <List<MockPoint>>[];
    final c = await make(
      routeFinder: RouteFinder.from((stops) async {
        seen.add(stops);
        return [stops.first, const MockPoint(25.49, 80.35), stops.last];
      }),
    );
    await c.setMode(MockMode.route);
    await c.addStop(office);
    await c.addStop(station);
    await c.buildRoute();
    expect(seen.single, [office.point, station.point]);
    expect(c.state.route!.points, hasLength(3));
  });

  group('maps apps', () {
    late List<Uri> launched;
    String? clipboard;

    Future<MockLocationController> withMaps({bool launches = true}) async {
      launched = [];
      final c = MockLocationController(
        config: MockLocationConfig(
          places: const [office],
          placeSearch: search,
          routeFinder: router,
          openUrl: (uri) async {
            launched.add(uri);
            return launches;
          },
        ),
        clock: () => clock,
        readClipboard: () async => clipboard,
      );
      addTearDown(c.dispose);
      await c.init();
      return c;
    }

    test('Google Maps searches what is typed', () async {
      final c = await withMaps();
      c.queryController.text = 'ladaka purwa';
      expect(await c.openMaps(MapsApp.google), isTrue);
      expect(launched.single.host, 'www.google.com');
      expect(launched.single.path, '/maps/search/');
      expect(launched.single.queryParameters, {
        'api': '1',
        'query': 'ladaka purwa',
      });
    });

    test(
      'with nothing typed, the map opens where the developer works',
      () async {
        final c = await withMaps();
        await c.openMaps(MapsApp.google);
        expect(
          launched.single.queryParameters['center'],
          '25.4762689,80.3395498',
        );
        expect(launched.single.queryParameters['map_action'], 'map');

        c.queryController.text = 'https://maps.app.goo.gl/abc';
        await c.openMaps(MapsApp.google);
        expect(launched.last.queryParameters['query'], isNull);
      },
    );

    test('Apple Maps searches near the point, or shows it', () async {
      final c = await withMaps();
      c.queryController.text = 'banda station';
      await c.openMaps(MapsApp.apple);
      expect(launched.single.host, 'maps.apple.com');
      expect(launched.single.queryParameters, {
        'q': 'banda station',
        'sll': '25.4762689,80.3395498',
        'z': '15',
      });
      c.queryController.clear();
      await c.openMaps(MapsApp.apple);
      expect(launched.last.queryParameters['ll'], '25.4762689,80.3395498');
    });

    test('offers Apple Maps only on Apple platforms', () async {
      final c = await withMaps();
      expect(c.mapsApps, [MapsApp.google]);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(c.mapsApps, [MapsApp.google, MapsApp.apple]);
    });

    test('says when no app opened', () async {
      final c = await withMaps(launches: false);
      expect(await c.openMaps(MapsApp.google), isFalse);
    });

    test('without an opener there is no maps button to press', () async {
      final c = await make();
      expect(c.canOpenMaps, isFalse);
      expect(await c.openMaps(MapsApp.google), isFalse);
    });

    test('pastes the copied link and looks it up', () async {
      final c = await withMaps();
      await c.setMode(MockMode.point);
      clipboard = '  25.4775, 80.3349 ';
      expect(await c.pasteLink(), isTrue);
      expect(c.state.point, const MockPoint(25.4775, 80.3349));

      clipboard = null;
      expect(await c.pasteLink(), isFalse);
      clipboard = '   ';
      expect(await c.pasteLink(), isFalse);
    });
  });

  group('saved places', () {
    test("lists the app's places first, and keeps them", () async {
      final c = await make();
      await c.setMode(MockMode.point);
      await submit(c, '25.4775, 80.3349');
      await c.savePlace('Gate');
      expect(c.places.map((p) => p.name), ['Office', 'Gate']);
      expect(c.state.pointName, 'Gate');

      await c.forgetPlace(office);
      await c.renamePlace(office, 'Renamed');
      expect(c.places.first, office);
      expect(c.isPreset(office), isTrue);
    });

    test('saving the same point again renames it', () async {
      final c = await make(places: const []);
      await c.savePlace('First', place: station);
      await c.savePlace('Second', place: station);
      expect(c.savedPlaces, [station.copyWith(name: 'Second')]);
    });

    test('renames and forgets, and survives a restart', () async {
      final c = await make(places: const []);
      await c.savePlace('Station', place: station);
      await c.renamePlace(c.savedPlaces.single, 'Banda station');
      final again = await make(places: const []);
      expect(again.savedPlaces.single.name, 'Banda station');
      expect(again.savedPlaces.single.detail, station.detail);

      await again.forgetPlace(again.savedPlaces.single);
      expect((await make(places: const [])).savedPlaces, isEmpty);
    });
  });

  group('route mode', () {
    test(
      'places and coordinates become stops; building follows roads',
      () async {
        final c = await make();
        await c.setMode(MockMode.route);
        await c.choose(office);
        await submit(c, '25.5100, 80.3600');
        expect(c.state.stops.map((s) => s.name), [
          'Office',
          '25.510000, 80.360000',
        ]);
        expect(c.canBuildRoute, isTrue);

        await c.buildRoute();
        expect(router.calls.single, [
          office.point,
          const MockPoint(25.51, 80.36),
        ]);
        expect(c.state.route!.points, hasLength(3));
        expect(c.state.playing, isTrue);
        expect(c.position!.point, office.point);
      },
    );

    test(
      'a failed road route keeps the old one and offers straight lines',
      () async {
        final c = await make(
          routeFinder: FakeRouter(error: const LocationLookupException('busy')),
        );
        await c.setMode(MockMode.route);
        await c.addStop(office);
        await c.addStop(station);
        await c.buildRoute();
        expect(c.routeError, 'busy');
        expect(c.state.route, isNull);

        await c.buildRoute(straight: true);
        expect(c.routeError, isNull);
        expect(c.state.route!.points, [office.point, station.point]);
      },
    );

    test('without a route finder every route is straight', () async {
      final c = await make(noRouter: true);
      await c.setMode(MockMode.route);
      await c.addStop(office);
      await c.addStop(station);
      await c.buildRoute();
      expect(c.state.route!.points, [office.point, station.point]);
    });

    test(
      'a directions link replaces the stops and builds, from any mode',
      () async {
        final c = await make();
        await c.setMode(MockMode.point);
        await submit(c, routeLink);
        expect(c.state.mode, MockMode.route);
        expect(c.state.stops.map((s) => s.name), [
          'Kanpur, Uttar Pradesh',
          'Banda, Uttar Pradesh 210001',
        ]);
        expect(router.calls, hasLength(1));
        expect(c.state.route, isNotNull);
      },
    );

    test('removes and reorders stops', () async {
      final c = await make();
      await c.setMode(MockMode.route);
      for (final place in [
        office,
        station,
        const MockPlace('C', MockPoint(1, 1)),
      ]) {
        await c.addStop(place);
      }
      await c.reorderStop(2, 0);
      expect(c.state.stops.map((s) => s.name), ['C', 'Office', 'Banda']);
      await c.removeStop(1);
      expect(c.state.stops.map((s) => s.name), ['C', 'Banda']);
      await c.clearStops();
      expect(c.canBuildRoute, isFalse);
    });

    test('a pasted polyline becomes the route', () async {
      final c = await make();
      await c.setMode(MockMode.route);
      await c.addStop(office);
      expect(await c.pasteRoute('_p~iF~ps|U_ulLnnqC_mqNvxq`@'), isTrue);
      expect(c.state.route!.points, hasLength(3));
      expect(c.state.stops, isEmpty);
      expect(await c.pasteRoute('not a route'), isFalse);
    });

    test('plays, pauses, restarts and changes speed on the clock', () async {
      final c = await make(noRouter: true);
      await c.setMode(MockMode.route);
      await c.addStop(const MockPlace('A', MockPoint(0, 0)));
      await c.addStop(const MockPlace('B', MockPoint(0.0089932, 0)));
      await c.buildRoute();
      await c.setSpeed(36);

      clock = clock.add(const Duration(seconds: 10));
      expect(c.progress!.along, closeTo(100, 1));
      await c.pause();
      clock = clock.add(const Duration(minutes: 5));
      expect(c.progress!.along, closeTo(100, 1));
      await c.play();
      clock = clock.add(const Duration(seconds: 10));
      expect(c.progress!.along, closeTo(200, 1));
      await c.restart();
      expect(c.progress!.along, 0);

      await c.setSpeed(-1);
      await c.setSpeed(double.nan);
      expect(c.state.speedKmh, 36);
    });

    test('carries on where it was after a restart of the app', () async {
      final c = await make(noRouter: true);
      await c.setMode(MockMode.route);
      await c.addStop(const MockPlace('A', MockPoint(0, 0)));
      await c.addStop(const MockPlace('B', MockPoint(0.0089932, 0)));
      await c.buildRoute();
      await c.setSpeed(36);
      clock = clock.add(const Duration(seconds: 30));

      final again = await make(noRouter: true);
      expect(again.progress!.along, closeTo(300, 1));
      expect(again.state.stops, hasLength(2));
    });
  });
}
