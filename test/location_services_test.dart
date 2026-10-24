import 'dart:convert';
import 'dart:io';

import 'package:flutter_dev_setup/flutter_dev_setup.dart';
import 'package:flutter_dev_setup/src/location_services.dart' show requestJson;
import 'package:flutter_test/flutter_test.dart';

const near = MockPoint(25.4762689, 80.3395498);

/// A local server answering every request with [respond], recording what
/// it was asked.
class FakeService {
  FakeService._(this._server);

  final HttpServer _server;
  final List<HttpRequest> requests = [];
  final List<String> bodies = [];
  late Future<void> Function(HttpRequest request) respond;

  String get origin => 'http://127.0.0.1:${_server.port}';

  static Future<FakeService> start() async {
    final service = FakeService._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    service._server.listen((request) async {
      service.requests.add(request);
      service.bodies.add(await utf8.decoder.bind(request).join());
      await service.respond(request);
    });
    return service;
  }

  void json(Object body, {int status = 200}) {
    respond = (request) async {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    };
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late FakeService service;

  setUp(() async {
    service = await FakeService.start();
    addTearDown(service.close);
  });

  group('NominatimPlaceSearch', () {
    test('asks near the point, names itself, and reads the places', () async {
      service.json([
        {
          'name': 'Banda',
          'display_name': 'Banda, Station Road, Banda, Uttar Pradesh, India',
          'lat': '25.4775200',
          'lon': '80.3349200',
        },
        {
          'name': '',
          'display_name': 'Somewhere, India',
          'lat': 'x',
          'lon': '1',
        },
      ]);
      final places = await NominatimPlaceSearch(
        baseUrl: service.origin,
        countryCodes: const ['in'],
      ).search('banda station', near: near);

      final request = service.requests.single;
      expect(request.uri.queryParameters['q'], 'banda station');
      expect(request.uri.queryParameters['countrycodes'], 'in');
      expect(request.uri.queryParameters['viewbox'], isNotNull);
      expect(request.headers.value('user-agent'), defaultLookupUserAgent);
      expect(places.single.name, 'Banda');
      expect(places.single.detail, 'Station Road, Banda, Uttar Pradesh, India');
      expect(places.single.point, const MockPoint(25.47752, 80.33492));
    });
  });

  group('PhotonPlaceSearch', () {
    test('looks only in a box around the point', () async {
      service.json({
        'features': [
          {
            'geometry': {
              'coordinates': [80.34, 25.47],
            },
            'properties': {
              'name': 'VNMPS SCHOOL',
              'city': 'Banda',
              'state': 'Uttar Pradesh',
              'country': 'India',
            },
          },
          {'geometry': null, 'properties': {}},
        ],
      });
      final places = await PhotonPlaceSearch(
        baseUrl: service.origin,
      ).search('banda school', near: near);

      final bbox = service.requests.single.uri.queryParameters['bbox']!;
      expect(bbox.split(',').map(double.parse), [
        closeTo(79.8395, 1e-3),
        closeTo(24.9763, 1e-3),
        closeTo(80.8395, 1e-3),
        closeTo(25.9763, 1e-3),
      ]);
      expect(places.single.name, 'VNMPS SCHOOL');
      expect(places.single.detail, 'Banda, Uttar Pradesh, India');
    });

    test('without a bound it ranks by distance instead', () async {
      service.json({'features': []});
      await PhotonPlaceSearch(
        baseUrl: service.origin,
        boundDegrees: null,
      ).search('banda', near: near);
      final query = service.requests.single.uri.queryParameters;
      expect(query['bbox'], isNull);
      expect(query['lat'], '25.4762689');
    });
  });

  group('CombinedPlaceSearch', () {
    PlaceSearch fixed(List<PlaceResult> results) =>
        PlaceSearch.from((query, near) async => results);
    PlaceSearch failing(String message) => PlaceSearch.from(
      (query, near) async => throw LocationLookupException(message),
    );

    test('leads with the first search, then the rest nearest first', () async {
      final results = await CombinedPlaceSearch([
        fixed(const [PlaceResult('Local', point: MockPoint(25.48, 80.34))]),
        fixed(const [
          PlaceResult('Far', point: MockPoint(5.55, 95.32)),
          PlaceResult('Near', point: MockPoint(25.9, 80.8)),
          PlaceResult('local', point: MockPoint(25.4801, 80.3401)),
        ]),
      ]).search('x', near: near);
      expect(results.map((r) => r.name), ['Local', 'Near', 'Far']);
    });

    test('leaves a failed search out, and fails only when all do', () async {
      final some = await CombinedPlaceSearch([
        failing('down'),
        fixed(const [PlaceResult('Ok', point: near)]),
      ]).search('x', near: near);
      expect(some.single.name, 'Ok');

      await expectLater(
        CombinedPlaceSearch([
          failing('first'),
          failing('second'),
        ]).search('x', near: near),
        throwsA(
          isA<LocationLookupException>().having(
            (e) => e.message,
            'message',
            'first',
          ),
        ),
      );
    });
  });

  group('OsrmRouteFinder', () {
    test('asks for the full road path and reads it', () async {
      service.json({
        'code': 'Ok',
        'routes': [
          {
            'geometry': {
              'coordinates': [
                [80.3318, 26.4499],
                [80.335, 26.0],
                [80.3395, 25.4762],
              ],
            },
          },
        ],
      });
      final points = await OsrmRouteFinder(
        baseUrl: service.origin,
      ).route(const [MockPoint(26.4499, 80.3318), MockPoint(25.4762, 80.3395)]);
      final uri = service.requests.single.uri;
      expect(uri.path, '/route/v1/driving/80.3318,26.4499;80.3395,25.4762');
      expect(uri.queryParameters['overview'], 'full');
      expect(points, hasLength(3));
      expect(points.first, const MockPoint(26.4499, 80.3318));
    });

    test("passes on the server's reason when there is no route", () async {
      service.json({'code': 'NoRoute', 'message': 'Impossible route'});
      await expectLater(
        OsrmRouteFinder(baseUrl: service.origin).route(const [near, near]),
        throwsA(
          isA<LocationLookupException>().having(
            (e) => e.message,
            'message',
            'Impossible route',
          ),
        ),
      );
    });
  });

  group('requestJson', () {
    test("turns a non-2xx reply into the service's own message", () async {
      service.json({
        'error': {'message': 'This API project is not authorized'},
      }, status: 403);
      await expectLater(
        requestJson(Uri.parse(service.origin)),
        throwsA(
          isA<LocationLookupException>().having(
            (e) => e.message,
            'message',
            'This API project is not authorized',
          ),
        ),
      );
    });

    test('times out', () async {
      service.respond = (request) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        await request.response.close();
      };
      await expectLater(
        requestJson(
          Uri.parse(service.origin),
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<LocationLookupException>()),
      );
    });

    test('sends a JSON body for a POST', () async {
      service.json({'ok': true});
      await requestJson(
        Uri.parse(service.origin),
        method: 'POST',
        body: {'textQuery': 'banda'},
      );
      expect(jsonDecode(service.bodies.single), {'textQuery': 'banda'});
      expect(
        service.requests.single.headers.contentType?.mimeType,
        'application/json',
      );
    });
  });

  group('MapsLinks.resolve', () {
    test('follows redirects to the first full map link', () async {
      service.respond = (request) async {
        final next = switch (request.uri.path) {
          '/short' => '/hop',
          '/hop' =>
            'https://www.google.com/maps/place/Banda/@25.4,80.3,13z/data=!3d25.47!4d80.33',
          _ => null,
        };
        request.response.statusCode = next == null ? 200 : 302;
        if (next != null) request.response.headers.set('location', next);
        await request.response.close();
      };
      final resolved = await MapsLinks.resolve('${service.origin}/short');
      expect(resolved, startsWith('https://www.google.com/maps/place/Banda'));
    });

    test('is null for a link that does not redirect', () async {
      service.respond = (request) async => request.response.close();
      expect(await MapsLinks.resolve('${service.origin}/plain'), isNull);
    });
  });
}
