import 'package:flutter_dev_setup/flutter_dev_setup.dart';
import 'package:flutter_test/flutter_test.dart';

// Where https://maps.app.goo.gl/ezw3UCAcjnTcqiM18 redirects: a shared place.
const placeLink =
    'https://www.google.com/maps/place/Banda,+Uttar+Pradesh+210001/'
    '@25.4779879,80.3445196,13z/data=!3m1!4b1!4m6!3m5!1s0x399cceefe1f614ff:'
    '0x53644b0b29880d03!8m2!3d25.4762689!4d80.3395498!16zL20vMDNjajF6'
    '?entry=tts&g_ep=EgoyMDI2MTAyMC4wIPu8ASoASAFQAw%3D%3D';

// Where https://maps.app.goo.gl/3y5NqC3ijWVg9HjAA redirects: a shared route.
const routeLink =
    'https://www.google.com/maps/dir/Kanpur,+Uttar+Pradesh/'
    'Banda,+Uttar+Pradesh+210001/@25.963197,80.0412881,10z/data=!3m1!4b1!4m14'
    '!4m13!1m5!1m1!1s0x399c4770b127c46f:0x1778302a9fbe7b41!2m2!1d80.3318736'
    '!2d26.449923!1m5!1m1!1s0x399cceefe1f614ff:0x53644b0b29880d03!2m2'
    '!1d80.3395498!2d25.4762689!3e2?entry=tts';

void main() {
  group('parsePoints', () {
    test('reads decimal degrees as Google Maps copies them', () {
      expect(parsePoint('25.4775, 80.3349'), const MockPoint(25.4775, 80.3349));
      expect(parsePoint('25.4775 80.3349'), const MockPoint(25.4775, 80.3349));
      expect(
        parsePoint('(-33.8688,151.2093)'),
        const MockPoint(-33.8688, 151.2093),
      );
    });

    test('applies hemisphere letters', () {
      expect(
        parsePoint('33.8688° S, 151.2093° E'),
        const MockPoint(-33.8688, 151.2093),
      );
      expect(
        parsePoint('40.7128N 74.0060W'),
        const MockPoint(40.7128, -74.006),
      );
    });

    test('reads degrees, minutes and seconds', () {
      final point = parsePoint('''25°28'39.0"N 80°20'05.6"E''')!;
      expect(point.latitude, closeTo(25.4775, 1e-4));
      expect(point.longitude, closeTo(80.3349, 1e-4));
    });

    test('reads one point per line, or separated by ; or |', () {
      expect(parsePoints('25.1, 80.1\n25.2, 80.2\n\n25.3, 80.3'), hasLength(3));
      expect(parsePoints('25.1,80.1; 25.2,80.2 | 25.3,80.3'), hasLength(3));
    });

    test('is empty when any part is not a point', () {
      expect(parsePoints('25.1, 80.1\nBanda'), isEmpty);
      expect(parsePoints('Banda railway station'), isEmpty);
      expect(parsePoints('sector 15 22'), isEmpty);
      expect(parsePoints('95.0, 80.0'), isEmpty);
      expect(parsePoints(''), isEmpty);
    });

    test('reads a geo: URI', () {
      expect(parsePoint('geo:25.4775,80.3349?z=17'), isNotNull);
    });
  });

  group('map links', () {
    test('a place link gives the pin, not the middle of the map', () {
      expect(pointsInLink(placeLink), [
        const MockPoint(25.4762689, 80.3395498),
      ]);
      expect(searchTextInLink(placeLink), 'Banda, Uttar Pradesh 210001');
    });

    test('a search link with coordinates gives them', () {
      expect(
        parsePoint('https://www.google.com/maps/search/25.4775,+80.3349'),
        [const MockPoint(25.4775, 80.3349)].single,
      );
      expect(
        parsePoint('https://maps.google.com/?q=25.4775,80.3349'),
        const MockPoint(25.4775, 80.3349),
      );
    });

    test('falls back to the middle of the map', () {
      expect(
        parsePoint('https://www.google.com/maps/@25.4779879,80.3445196,13z'),
        const MockPoint(25.4779879, 80.3445196),
      );
    });

    test('a link that only names a place gives its name to search', () {
      const link = 'https://maps.google.com/?q=Banda+Railway+Station&ftid=0x1';
      expect(pointsInLink(link), isEmpty);
      expect(searchTextInLink(link), 'Banda Railway Station');
    });

    test('a shared route gives its named stops in order', () {
      expect(stopsInLink(routeLink), [
        (
          name: 'Kanpur, Uttar Pradesh',
          point: const MockPoint(26.449923, 80.3318736),
        ),
        (
          name: 'Banda, Uttar Pradesh 210001',
          point: const MockPoint(25.4762689, 80.3395498),
        ),
      ]);
      expect(pointsInLink(routeLink), hasLength(2));
    });

    test('a route with stops written as coordinates keeps them', () {
      const link =
          'https://www.google.com/maps/dir/25.4775,80.3349/25.4890,80.3420/'
          '@25.48,80.33,15z';
      expect(stopsInLink(link), [
        (name: null, point: const MockPoint(25.4775, 80.3349)),
        (name: null, point: const MockPoint(25.489, 80.342)),
      ]);
    });

    test('a route mixing names and coordinates lines them up', () {
      const link =
          'https://www.google.com/maps/dir/25.4775,80.3349/Banda/'
          'data=!4m6!4m5!1m0!1m3!2m2!1d80.3395498!2d25.4762689';
      expect(stopsInLink(link), [
        (name: null, point: const MockPoint(25.4775, 80.3349)),
        (name: 'Banda', point: const MockPoint(25.4762689, 80.3395498)),
      ]);
    });

    test('reads Apple Maps links', () {
      const shared =
          'https://maps.apple.com/?address=Station%20Road,%20Banda'
          '&auid=123&ll=25.4775,80.3349&lsp=9902&q=Banda%20Station';
      expect(pointsInLink(shared), [const MockPoint(25.4775, 80.3349)]);
      expect(searchTextInLink(shared), 'Banda Station');

      const place =
          'https://maps.apple.com/place?coordinate=25.4762,80.3395'
          '&name=Banda&address=Banda,%20Uttar%20Pradesh';
      expect(pointsInLink(place), [const MockPoint(25.4762, 80.3395)]);
      expect(searchTextInLink(place), 'Banda');
      expect(MapsLinks.isShort('https://maps.apple/p/AbC.12'), isTrue);
    });

    test('a malformed link reads as nothing rather than throwing', () {
      expect(pointsInLink('https://maps.google.com/?q=%E0%A4'), isEmpty);
      expect(stopsInLink('https://maps.google.com/dir/%E0%A4'), isEmpty);
    });

    test('knows the short-link hosts', () {
      expect(
        MapsLinks.isShort('https://maps.app.goo.gl/ezw3UCAcjnTcqiM18'),
        isTrue,
      );
      expect(MapsLinks.isShort(placeLink), isFalse);
    });
  });

  group('feature ids', () {
    test('decode to the S2 cell s2sphere gives', () {
      final cases = {
        0x399ccec35eaed679: (25.473340, 80.348835),
        0x399cceefe1f614ff: (25.472290, 80.332512),
        0x399c4770b127c46f: (26.455335, 80.327396),
      };
      cases.forEach((id, expected) {
        final point = s2CellCentre(id)!;
        expect(point.latitude, closeTo(expected.$1, 1e-5));
        expect(point.longitude, closeTo(expected.$2, 1e-5));
      });
    });

    test("read the place's area from a link with no coordinates", () {
      // The Google Maps app's share link for Ladaka Purwa, once resolved.
      const link =
          'https://www.google.com/maps/place/Ladaka+Purwa,+Banda,+Uttar+'
          'Pradesh+210001,+India/data=!4m2!3m1!1s0x399ccec35eaed679:'
          '0x7e4016436e3c2249!18m1!1e1?entry=gps';
      expect(pointsInLink(link), isEmpty);
      expect(
        searchTextInLink(link),
        'Ladaka Purwa, Banda, Uttar Pradesh 210001, India',
      );
      final area = approximatePointInLink(link)!;
      expect(
        area.distanceTo(const MockPoint(25.4779779, 80.3575128)),
        lessThan(1500),
      );
      expect(
        approximatePointInLink(
          'https://maps.google.com/?q=x&ftid=0x399ccec35eaed679:0x1',
        ),
        isNotNull,
      );
    });

    test('ignore ids that are not leaf cells', () {
      expect(s2CellCentre(0x399ccec35eaed678), isNull);
      expect(s2CellCentre(-1), isNull);
      expect(
        approximatePointInLink('https://www.google.com/maps/place/x'),
        isNull,
      );
    });
  });

  group('polylines', () {
    test("decodes Google's reference polyline", () {
      final points = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
      expect(points, const [
        MockPoint(38.5, -120.2),
        MockPoint(40.7, -120.95),
        MockPoint(43.252, -126.453),
      ]);
    });

    test('rejects text that is not a polyline', () {
      expect(decodePolyline('_p~iF~ps|U_'), isEmpty);
      expect(decodePolyline('hello world'), isEmpty);
    });

    test('routePoints takes coordinates, a route link, or a polyline', () {
      expect(routePoints('25.1, 80.1\n25.2, 80.2'), hasLength(2));
      expect(routePoints(routeLink), hasLength(2));
      expect(routePoints('_p~iF~ps|U_ulLnnqC_mqNvxq`@'), hasLength(3));
      expect(routePoints('Banda station'), isEmpty);
    });
  });

  group('geometry', () {
    test('measures great-circle distance', () {
      const kanpur = MockPoint(26.449923, 80.3318736);
      const banda = MockPoint(25.4762689, 80.3395498);
      expect(kanpur.distanceTo(banda), closeTo(108270, 500));
    });

    test('measures bearing clockwise from north', () {
      const origin = MockPoint(0, 0);
      expect(origin.bearingTo(const MockPoint(1, 0)), closeTo(0, 1e-9));
      expect(origin.bearingTo(const MockPoint(0, 1)), closeTo(90, 1e-9));
      expect(origin.bearingTo(const MockPoint(-1, 0)), closeTo(180, 1e-9));
      expect(origin.bearingTo(const MockPoint(0, -1)), closeTo(270, 1e-9));
    });

    test('round-trips through JSON and rejects bad values', () {
      const point = MockPoint(25.4775, 80.3349);
      expect(MockPoint.fromJson(point.toJson()), point);
      expect(MockPoint.fromJson([91, 0]), isNull);
      expect(MockPoint.fromJson(['25', '80']), isNull);
      expect(MockPoint.fromJson({'lat': 25}), isNull);
    });
  });
}
