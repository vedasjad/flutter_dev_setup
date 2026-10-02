import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_dev_setup/flutter_dev_setup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

List<String> endpoints(DevSetupController c) => [
  for (final e in c.servers) e.server.endpoint,
];

DevServerEntry entryFor(DevSetupController c, String endpoint) =>
    c.servers.firstWhere((e) => e.server.endpoint == endpoint);

class SlowStore extends DevSetupStore {
  SlowStore() : super(keyPrefix: 'dev', config: testConfig);

  static const delay = Duration(milliseconds: 30);

  @override
  Future<Map<String, String>> labels() async {
    await Future<void>.delayed(delay);
    return super.labels();
  }

  @override
  Future<void> setCustomOrigins(List<String> origins) async {
    await Future<void>.delayed(delay);
    await super.setCustomOrigins(origins);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('choosing a server', () {
    test('commits it to the app and to storage', () async {
      final committed = <String>[];
      final c = await buildController(
        committed: committed,
        scanner: FakeScanner(
          found: [server('192.168.0.102'), server('192.168.0.111')],
        ),
      );
      await c.scan(manual: false);

      await c.select(entryFor(c, '192.168.0.111:5001'));

      expect(committed, ['http://192.168.0.111:5001/api/v1/']);
      expect(
        await DevSetup.savedBaseUrl(keyPrefix: 'dev'),
        'http://192.168.0.111:5001/api/v1/',
      );
    });

    test('does not reorder the list', () async {
      final c = await buildController(
        scanner: FakeScanner(
          found: [
            server('192.168.0.102', ms: 40),
            server('192.168.0.111', ms: 5),
          ],
        ),
      );
      await c.scan(manual: false);
      final before = endpoints(c);

      await c.select(entryFor(c, before.last));
      await c.togglePin(entryFor(c, before.last));
      await c.rename(entryFor(c, before.last), 'mine');

      expect(endpoints(c), before);
    });

    test('typing does not commit', () async {
      final committed = <String>[];
      final c = await buildController(committed: committed);

      c.urlController.text = '10.0.0.4:5001';
      c.onUrlEdited();

      expect(committed, isEmpty);
    });

    test('switching the scheme recomposes the URL', () async {
      final c = await buildController();
      c.setScheme('http');
      expect(c.fullUrl, startsWith('http://staging.example.com'));
      c.setScheme('https');
      expect(c.fullUrl, 'https://staging.example.com/api/v1/');
    });

    test('a pasted URL hands its scheme to the picker', () async {
      final c = await buildController();

      c.urlController.text = 'http://192.168.0.5:5001';
      c.onUrlEdited();
      expect(c.scheme, 'http');
      expect(c.urlController.text, '192.168.0.5:5001');
      expect(c.fullUrl, 'http://192.168.0.5:5001/api/v1/');

      c.urlController.text = 'https://box.example.com:8443/api/v1/';
      c.onUrlEdited();
      expect(c.fullUrl, 'https://box.example.com:8443/api/v1/');
    });

    // Uri drops a port equal to the scheme default, which turned :80 into the
    // dev port and left the row unselected.
    test('keeps an explicit default port in the URL', () async {
      SharedPreferences.setMockInitialValues({
        'devCustomServers': ['http://192.168.0.5:80'],
      });
      final committed = <String>[];
      final c = await buildController(committed: committed);

      await c.select(entryFor(c, '192.168.0.5:80'));

      expect(committed, ['http://192.168.0.5:80/api/v1/']);
      expect(c.isSelected(entryFor(c, '192.168.0.5:80')), isTrue);
    });

    // An http URL with no port goes to :80, so it is not the dev-port row.
    test(
      'a typed address without a port does not select the dev-port row',
      () async {
        SharedPreferences.setMockInitialValues({
          'devCustomServers': ['http://10.0.0.4:5001'],
        });
        final c = await buildController();
        c.setScheme('http');

        c.urlController.text = '10.0.0.4';
        c.onUrlEdited();
        expect(c.isSelected(entryFor(c, '10.0.0.4:5001')), isFalse);

        c.urlController.text = '10.0.0.4:5001';
        c.onUrlEdited();
        expect(c.isSelected(entryFor(c, '10.0.0.4:5001')), isTrue);
      },
    );

    test('a pasted IPv6 URL keeps its brackets in the field', () async {
      final c = await buildController();

      c.urlController.text = 'http://[::1]:5001/api/v1/';
      c.onUrlEdited();

      expect(c.urlController.text, '[::1]:5001');
      expect(c.fullUrl, 'http://[::1]:5001/api/v1/');
      expect(c.isValid, isTrue);
    });

    test('an IPv6 server stays selected through commit and relaunch', () async {
      SharedPreferences.setMockInitialValues({
        'devCustomServers': ['http://[::1]:5001'],
      });
      final committed = <String>[];
      final c = await buildController(committed: committed);

      await c.select(entryFor(c, '[::1]:5001'));

      expect(c.urlController.text, '[::1]:5001');
      expect(committed, ['http://[::1]:5001/api/v1/']);
      expect(c.isSelected(entryFor(c, '[::1]:5001')), isTrue);
      expect(
        await DevSetup.savedBaseUrl(keyPrefix: 'dev'),
        'http://[::1]:5001/api/v1/',
      );

      final relaunched = await buildController();
      expect(relaunched.urlController.text, '[::1]:5001');
      expect(relaunched.isSelected(entryFor(relaunched, '[::1]:5001')), isTrue);
    });

    test('reset returns to the default and commits it', () async {
      final committed = <String>[];
      final c = await buildController(
        committed: committed,
        scanner: FakeScanner(found: [server('192.168.0.102')]),
      );
      await c.scan(manual: false);
      await c.select(entryFor(c, '192.168.0.102:5001'));

      await c.resetToDefault();

      expect(c.baseOrigin, 'https://staging.example.com');
      expect(committed.last, defaultUrl);
      expect(c.urlMode, isFalse);
    });

    // Without the ping timer nothing re-checks, so the old verdict must not
    // carry over to a URL nobody has checked.
    test('a new URL cannot be proceeded with until it is checked', () async {
      SharedPreferences.setMockInitialValues({
        'devCustomServers': ['http://10.0.0.4:5001'],
      });
      final c = await buildController(
        scanner: FakeScanner(
          verifyResults: {
            'https://staging.example.com:443': server('staging.example.com'),
          },
        ),
      );
      await c.checkHealth();
      expect(c.canProceed, isTrue);

      await c.select(entryFor(c, '10.0.0.4:5001'));
      expect(c.canProceed, isFalse);

      await c.resetToDefault();
      await c.checkHealth();
      c.urlController.text = 'other.example.com';
      c.onUrlEdited();
      expect(c.canProceed, isFalse);
    });
  });

  group('scanning', () {
    // Review finding 3: an automatic scan re-applied the remembered server and
    // silently undid an explicit Default.
    test('an automatic scan never changes the committed URL', () async {
      SharedPreferences.setMockInitialValues({
        'devDiscoveredHost': '192.168.0.102',
        'devServerPins': '{"192.168.0.":"192.168.0.102"}',
      });
      final committed = <String>[];
      final c = await buildController(
        committed: committed,
        scanner: FakeScanner(found: [server('192.168.0.102')]),
      );

      await c.scan(manual: false);

      expect(committed, isEmpty);
      expect(c.baseOrigin, 'https://staging.example.com');
    });

    test('the scan init starts never changes the committed URL', () async {
      SharedPreferences.setMockInitialValues({
        'devDiscoveredHost': '192.168.0.102',
        'devServerPins': '{"192.168.0.":"192.168.0.102"}',
      });
      final committed = <String>[];
      final fake = FakeScanner(found: [server('192.168.0.102')]);
      final c = DevSetupController(
        defaultBaseUrl: defaultUrl,
        onBaseUrlChanged: committed.add,
        config: testConfig,
        store: testStore(),
        scannerFactory: () => fake,
      );
      addTearDown(c.dispose);

      await c.init();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(c.scanPhase, ScanPhase.found);
      expect(endpoints(c), ['192.168.0.102:5001']);
      expect(committed, isEmpty);
      expect(c.baseOrigin, 'https://staging.example.com');
    });

    test(
      'an automatic scan lists the emulator alias without selecting it',
      () async {
        final committed = <String>[];
        final c = await buildController(
          committed: committed,
          scanner: FakeScanner(
            outcome: ScanOutcome.notFound,
            fallback: server('10.0.2.2', ms: 0),
          ),
        );

        await c.scan(manual: false);

        expect(endpoints(c), ['10.0.2.2:5001']);
        expect(committed, isEmpty);
        expect(c.baseOrigin, 'https://staging.example.com');
      },
    );

    test('a manual scan prefers the pinned server', () async {
      SharedPreferences.setMockInitialValues({
        'devServerPins': '{"192.168.0.":"192.168.0.111"}',
      });
      final c = await buildController(
        scanner: FakeScanner(
          found: [
            server('192.168.0.102', ms: 2),
            server('192.168.0.111', ms: 90),
          ],
        ),
      );

      await c.scan();

      expect(c.baseOrigin, 'http://192.168.0.111:5001');
    });

    test(
      'one scan lists pinned, remembered, named, then fastest, then by host',
      () async {
        SharedPreferences.setMockInitialValues({
          'devServerPins': '{"192.168.0.":"192.168.0.140"}',
          'devDiscoveredHost': '192.168.0.130',
          'devServerLabels': '{"192.168.0.125":"laptop"}',
        });
        final pinned = server('192.168.0.140', ms: 90);
        final remembered = server('192.168.0.130', ms: 80);
        final labelled = server('192.168.0.125', ms: 70);
        final advertised = server('192.168.0.122', ms: 60, name: 'ci-box');
        final fastest = server('192.168.0.110', ms: 5);
        final tiedLow = server('192.168.0.103', ms: 20);
        final tiedHigh = server('192.168.0.120', ms: 20);
        final c = await buildController(
          scanner: FakeScanner(
            found: [
              tiedHigh,
              fastest,
              advertised,
              tiedLow,
              remembered,
              labelled,
              pinned,
            ],
          ),
        );

        await c.scan(manual: false);

        expect(endpoints(c), [
          for (final s in [
            pinned,
            remembered,
            advertised,
            labelled,
            fastest,
            tiedLow,
            tiedHigh,
          ])
            s.endpoint,
        ]);
      },
    );

    test('a server named only by its own IP ranks as unnamed', () async {
      final c = await buildController(
        scanner: FakeScanner(
          found: [
            server('192.168.0.50', ms: 90, name: '192.168.0.50'),
            server('192.168.0.70', ms: 95, name: '192.168.0.70.'),
            server('192.168.0.60', ms: 5),
          ],
        ),
      );

      await c.scan(manual: false);

      expect(endpoints(c), [
        '192.168.0.60:5001',
        '192.168.0.50:5001',
        '192.168.0.70:5001',
      ]);
      expect(c.servers.where((e) => e.isNamed), isEmpty);
    });

    test('a manual scan with several unpinned results selects none', () async {
      final committed = <String>[];
      final c = await buildController(
        committed: committed,
        scanner: FakeScanner(
          found: [server('192.168.0.102'), server('192.168.0.111')],
        ),
      );

      await c.scan();

      expect(committed, isEmpty);
    });

    // Review finding 5: auto-select took servers.first, which could be a saved
    // address that was down.
    test(
      'a manual scan selects the server it found, not a dead saved one',
      () async {
        SharedPreferences.setMockInitialValues({
          'devCustomServers': ['http://10.9.9.9:5001'],
        });
        final c = await buildController(
          scanner: FakeScanner(found: [server('192.168.0.102')]),
        );

        await c.scan();

        expect(c.baseOrigin, 'http://192.168.0.102:5001');
      },
    );

    test(
      'a manual scan ignores a pinned saved server it no longer finds',
      () async {
        SharedPreferences.setMockInitialValues({
          'devCustomServers': ['http://192.168.0.50:5001'],
          'devServerPins': '{"192.168.0.":"192.168.0.50"}',
        });
        var round = 0;
        final scanners = [
          FakeScanner(found: [server('192.168.0.50')]),
          FakeScanner(found: [server('192.168.0.102')]),
        ];
        final c = DevSetupController(
          defaultBaseUrl: defaultUrl,
          onBaseUrlChanged: (_) {},
          config: testConfig,
          store: testStore(),
          scannerFactory: () => scanners[round],
        );
        await c.init(startBackgroundWork: false);
        await c.scan(manual: false);

        round = 1;
        await c.scan();

        expect(c.baseOrigin, 'http://192.168.0.102:5001');
        expect(c.foundCount, 1);
      },
    );

    test('a manual scan leaves a server picked while it ran', () async {
      SharedPreferences.setMockInitialValues({
        'devCustomServers': ['http://100.64.0.9:5001'],
      });
      final committed = <String>[];
      final c = await buildController(
        committed: committed,
        scanner: FakeScanner(
          found: [server('192.168.0.102')],
          scanDelay: const Duration(milliseconds: 50),
        ),
      );

      final scanning = c.scan();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await c.select(entryFor(c, '100.64.0.9:5001'));
      await scanning;

      expect(c.baseOrigin, 'http://100.64.0.9:5001');
      expect(committed, ['http://100.64.0.9:5001/api/v1/']);
    });

    test('a manual scan leaves an address typed while it ran', () async {
      final committed = <String>[];
      final c = await buildController(
        committed: committed,
        scanner: FakeScanner(
          found: [server('192.168.0.102')],
          scanDelay: const Duration(milliseconds: 50),
        ),
      );

      final scanning = c.scan();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      c.urlController.text = '10.0.0.7:9000';
      c.onUrlEdited();
      await scanning;

      expect(c.urlController.text, '10.0.0.7:9000');
      expect(committed, isEmpty);
    });

    test('a manual scan leaves a URL committed while it ran', () async {
      final committed = <String>[];
      final c = await buildController(
        committed: committed,
        scanner: FakeScanner(
          found: [server('192.168.0.102')],
          scanDelay: const Duration(milliseconds: 50),
        ),
      );

      final scanning = c.scan();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await c.commit();
      await scanning;

      expect(committed, [defaultUrl]);
    });

    test('a manual scan leaves an address being saved while it ran', () async {
      final committed = <String>[];
      final c = DevSetupController(
        defaultBaseUrl: defaultUrl,
        onBaseUrlChanged: committed.add,
        config: testConfig,
        store: SlowStore(),
        scannerFactory: () => FakeScanner(
          found: [server('192.168.0.102')],
          scanDelay: const Duration(milliseconds: 10),
        ),
      );
      await c.init(startBackgroundWork: false);

      final scanning = c.scan();
      await c.addCustom('http://10.0.0.4:5001');
      await scanning;

      expect(committed, ['http://10.0.0.4:5001/api/v1/']);
    });

    test(
      'the emulator alias is offered and selected when nothing answered',
      () async {
        SharedPreferences.setMockInitialValues({
          'devCustomServers': ['http://10.9.9.9:5001'],
        });
        final c = await buildController(
          scanner: FakeScanner(
            outcome: ScanOutcome.notFound,
            fallback: server('10.0.2.2', ms: 0),
          ),
        );

        await c.scan();

        expect(c.baseOrigin, 'http://10.0.2.2:5001');
      },
    );

    test('cancelling drops results that arrive afterwards', () async {
      final c = await buildController(
        scanner: FakeScanner(
          found: [server('192.168.0.102')],
          scanDelay: const Duration(milliseconds: 40),
        ),
      );

      final scanning = c.scan(manual: false);
      c.cancelScan();
      await scanning;

      expect(c.servers, isEmpty);
      expect(c.scanPhase, ScanPhase.cancelled);
    });

    // The scanner used to start after the cancel, and a fresh scanner wipes
    // the cancel flag, so the whole sweep ran.
    test('a scan cancelled before it starts never starts', () async {
      final fake = FakeScanner(found: [server('192.168.0.102')]);
      final c = await buildController(scanner: fake);

      final scanning = c.scan(manual: false);
      c.cancelScan();
      await scanning;

      expect(fake.scanCalls, 0);
      expect(c.scanPhase, ScanPhase.cancelled);
    });

    // A fresh scanner per scan, as the real factory gives, so cancelling one
    // does not cancel the next.
    Future<DevSetupController> slowScans({List<String>? committed}) async {
      final c = DevSetupController(
        defaultBaseUrl: defaultUrl,
        onBaseUrlChanged: (url) => committed?.add(url),
        config: testConfig,
        store: testStore(),
        scannerFactory: () => FakeScanner(
          found: [server('192.168.0.102')],
          scanDelay: const Duration(milliseconds: 30),
        ),
      );
      await c.init(startBackgroundWork: false);
      return c;
    }

    test('asking for a scan while one runs restarts it', () async {
      final committed = <String>[];
      final c = await slowScans(committed: committed);

      unawaited(c.scan(manual: false));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await c.scan();

      expect(c.scanPhase, ScanPhase.found);
      expect(endpoints(c), ['192.168.0.102:5001']);
      expect(committed, ['http://192.168.0.102:5001/api/v1/']);
    });

    test('toggleScan cancels a running scan or starts one', () async {
      final c = await slowScans();

      final scanning = c.toggleScan();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await c.toggleScan();
      await scanning;
      expect(c.scanPhase, ScanPhase.cancelled);
      expect(c.servers, isEmpty);

      await c.toggleScan();
      expect(c.scanPhase, ScanPhase.found);
    });

    test('tells the scanner every host the developer has used', () async {
      SharedPreferences.setMockInitialValues({
        'devServerPins':
            '{"192.168.0.":"192.168.0.140","*":"box.tailnet.example"}',
        'devCustomServers': [
          'http://10.1.1.1:5001',
          'https://box.tailnet.example',
          'http://192.168.0.140:5001',
        ],
        'devServerLabels': '{"192.168.0.125":"laptop","10.1.1.1":"vpn"}',
      });
      final fake = FakeScanner();
      final c = await buildController(scanner: fake);

      await c.scan(manual: false);

      expect(fake.knownHosts, [
        '192.168.0.140',
        'box.tailnet.example',
        '10.1.1.1',
        '192.168.0.125',
      ]);
    });

    test('a scanner that throws ends the scan as failed', () async {
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previous);
      final c = await buildController(
        scanner: FakeScanner(error: StateError('no interface')),
      );

      await c.scan();

      expect(c.scanPhase, ScanPhase.failed);
      expect(c.isScanning, isFalse);
      expect(reported.single.exception, isA<StateError>());
    });
  });

  group('the preferred server', () {
    const aliasUrl = 'http://10.0.2.2:5001/api/v1/';
    final alias = server('10.0.2.2', ms: 300);
    const pause = Duration(milliseconds: 40);
    const midway = Duration(milliseconds: 10);

    test(
      'a manual scan with no pins selects it the moment it answers',
      () async {
        final committed = <String>[];
        final c = await buildController(
          committed: committed,
          scanner: FakeScanner(
            preferred: alias,
            found: [server('192.168.0.101'), server('192.168.0.102')],
            preferredDelay: pause,
          ),
        );

        final scanning = c.scan();
        await Future<void>.delayed(midway);
        expect(c.isScanning, isTrue);
        expect(committed, [aliasUrl]);
        await scanning;

        expect(committed, [aliasUrl]);
        expect(c.foundCount, 3);
      },
    );

    test('waits for the scan to end when something is pinned', () async {
      SharedPreferences.setMockInitialValues({
        'devServerPins': '{"192.168.0.":"192.168.0.101"}',
      });
      final committed = <String>[];
      final c = await buildController(
        committed: committed,
        scanner: FakeScanner(
          preferred: alias,
          found: [server('192.168.0.101'), server('192.168.0.102')],
          preferredDelay: pause,
        ),
      );

      final scanning = c.scan();
      await Future<void>.delayed(midway);
      expect(committed, isEmpty);
      await scanning;

      expect(committed, ['http://192.168.0.101:5001/api/v1/']);
    });

    test(
      'is selected at the end when the pinned server never answers',
      () async {
        SharedPreferences.setMockInitialValues({
          'devServerPins': '{"192.168.1.":"192.168.1.50"}',
        });
        final committed = <String>[];
        final c = await buildController(
          committed: committed,
          scanner: FakeScanner(
            preferred: alias,
            found: [server('192.168.0.101'), server('192.168.0.102')],
            preferredDelay: pause,
          ),
        );

        final scanning = c.scan();
        await Future<void>.delayed(midway);
        expect(committed, isEmpty);
        await scanning;

        expect(committed, [aliasUrl]);
      },
    );

    test('is selected at once when it is itself pinned', () async {
      SharedPreferences.setMockInitialValues({
        'devServerPins': '{"10.0.2.":"10.0.2.2","192.168.0.":"192.168.0.101"}',
      });
      final committed = <String>[];
      final c = await buildController(
        committed: committed,
        scanner: FakeScanner(
          preferred: alias,
          found: [server('192.168.0.101')],
          preferredDelay: pause,
        ),
      );

      final scanning = c.scan();
      await Future<void>.delayed(midway);
      expect(committed, [aliasUrl]);
      await scanning;

      expect(committed, [aliasUrl]);
    });

    test('an automatic scan only lists it', () async {
      final committed = <String>[];
      final c = await buildController(
        committed: committed,
        scanner: FakeScanner(preferred: alias),
      );

      await c.scan(manual: false);

      expect(committed, isEmpty);
      expect(endpoints(c), ['10.0.2.2:5001']);
      expect(c.baseOrigin, 'https://staging.example.com');
    });

    test('a server picked before it answers is left alone', () async {
      SharedPreferences.setMockInitialValues({
        'devCustomServers': ['http://100.64.0.9:5001'],
      });
      final committed = <String>[];
      final c = await buildController(
        committed: committed,
        scanner: FakeScanner(preferred: alias, scanDelay: pause),
      );

      final scanning = c.scan();
      await Future<void>.delayed(midway);
      await c.select(entryFor(c, '100.64.0.9:5001'));
      await scanning;

      expect(committed, ['http://100.64.0.9:5001/api/v1/']);
      expect(c.baseOrigin, 'http://100.64.0.9:5001');
    });

    test('an address typed while it waits on a pin is left alone', () async {
      SharedPreferences.setMockInitialValues({
        'devServerPins': '{"192.168.1.":"192.168.1.50"}',
      });
      final committed = <String>[];
      final c = await buildController(
        committed: committed,
        scanner: FakeScanner(
          preferred: alias,
          found: [server('192.168.0.101')],
          preferredDelay: pause,
        ),
      );

      final scanning = c.scan();
      await Future<void>.delayed(midway);
      c.urlController.text = '10.0.0.7:9000';
      c.onUrlEdited();
      await scanning;

      expect(committed, isEmpty);
      expect(c.urlController.text, '10.0.0.7:9000');
    });

    test('one from a cancelled scan is never selected', () async {
      final committed = <String>[];
      final c = await buildController(
        committed: committed,
        scanner: FakeScanner(preferred: alias, scanDelay: pause),
      );

      final scanning = c.scan();
      await Future<void>.delayed(midway);
      c.cancelScan();
      await scanning;

      expect(committed, isEmpty);
      expect(c.servers, isEmpty);
    });
  });

  group('the LAN an emulator scan sweeps', () {
    Future<String?> storedLan() async {
      await Future<void>.delayed(Duration.zero);
      return testStore().lanHost();
    }

    test(
      'is a LAN server a scan found, passed first to the next scan',
      () async {
        final fake = FakeScanner(
          found: [server('10.0.2.2'), server('192.168.0.101')],
        );
        final c = await buildController(scanner: fake);

        await c.scan(manual: false);
        expect(await storedLan(), '192.168.0.101');

        await c.scan(manual: false);
        expect(fake.knownHosts?.first, '192.168.0.101');
      },
    );

    test('holds still while scans keep finding the same network', () async {
      final c = await buildController(
        scanner: FakeScanner(
          found: [server('192.168.0.101'), server('192.168.0.100')],
        ),
      );

      await c.scan(manual: false);

      expect(await storedLan(), '192.168.0.101');
    });

    test('moves when a scan finds a server on another network', () async {
      SharedPreferences.setMockInitialValues({'devLanHost': '192.168.0.101'});
      final c = await buildController(
        scanner: FakeScanner(found: [server('192.168.1.7')]),
      );

      await c.scan(manual: false);

      expect(await storedLan(), '192.168.1.7');
    });

    test('outlives choosing the emulator alias', () async {
      final committed = <String>[];
      final fake = FakeScanner(
        preferred: server('10.0.2.2'),
        found: [server('192.168.0.101')],
      );
      final c = await buildController(scanner: fake, committed: committed);

      await c.scan();
      expect(committed, ['http://10.0.2.2:5001/api/v1/']);
      await Future<void>.delayed(Duration.zero);

      final reopened = await buildController(scanner: fake);
      await reopened.scan(manual: false);

      expect(reopened.baseOrigin, 'http://10.0.2.2:5001');
      expect(fake.knownHosts?.first, '192.168.0.101');
    });

    test('is a LAN address the developer commits once it answers, never the '
        'alias or a name', () async {
      final c = await buildController(
        scanner: FakeScanner(
          verifyResults: {
            'http://192.168.0.101:5001': server('192.168.0.101'),
            'http://10.0.2.2:5001': server('10.0.2.2'),
            'http://box.tailnet.example:5001': server('box.tailnet.example'),
          },
        ),
      );
      c.setScheme('http');

      c.urlController.text = '192.168.0.101:5001';
      await c.commit();
      expect(await storedLan(), isNull);
      await c.checkHealth();
      expect(await storedLan(), '192.168.0.101');

      for (final other in ['10.0.2.2:5001', 'box.tailnet.example:5001']) {
        c.urlController.text = other;
        await c.commit();
        await c.checkHealth();
      }
      expect(await storedLan(), '192.168.0.101');
    });

    test('is a saved LAN server the developer picks once it answers', () async {
      SharedPreferences.setMockInitialValues({
        'devCustomServers': ['http://192.168.5.20:5001'],
      });
      final c = await buildController(
        scanner: FakeScanner(
          verifyResults: {'http://192.168.5.20:5001': server('192.168.5.20')},
        ),
      );

      await c.select(entryFor(c, '192.168.5.20:5001'));
      expect(await storedLan(), isNull);
      await c.checkHealth();

      expect(await storedLan(), '192.168.5.20');
    });

    test('is never replaced by an address that has not answered', () async {
      SharedPreferences.setMockInitialValues({
        'devLanHost': '192.168.4.100',
        'devCustomServers': ['http://10.1.1.57:5001'],
      });
      final c = await buildController();

      await c.addCustom('http://192.168.40.100:5001');
      await c.select(entryFor(c, '10.1.1.57:5001'));
      c.urlController.text = '172.16.9.9:5001';
      await c.commit();

      expect(await storedLan(), '192.168.4.100');
    });

    test('is a typed LAN address once it answers the health check', () async {
      final c = await buildController(
        scanner: FakeScanner(
          verifyResults: {'http://192.168.0.101:5001': server('192.168.0.101')},
        ),
      );
      c.setScheme('http');

      c.urlController.text = '192.168.0.120:5001';
      c.onUrlEdited();
      await c.checkHealth();
      expect(await storedLan(), isNull);

      c.urlController.text = '192.168.0.101:5001';
      c.onUrlEdited();
      await c.checkHealth();
      expect(await storedLan(), '192.168.0.101');
    });

    test('goes before every other host the developer has used', () async {
      SharedPreferences.setMockInitialValues({
        'devLanHost': '192.168.0.101',
        'devServerPins': '{"192.168.0.":"192.168.0.140"}',
        'devServerLabels': '{"192.168.0.101":"laptop"}',
      });
      final fake = FakeScanner();
      final c = await buildController(scanner: fake);

      await c.scan(manual: false);

      expect(fake.knownHosts, ['192.168.0.101', '192.168.0.140']);
    });
  });

  group('saved servers', () {
    // Review finding 4: verification results were dropped once the scan
    // finished, so a reachable tunnel address always showed as "saved".
    test('a check that finishes after the scan still lands', () async {
      const origin = 'http://100.64.0.10:5001';
      SharedPreferences.setMockInitialValues({
        'devCustomServers': [origin],
      });
      final c = await buildController(
        scanner: FakeScanner(
          outcome: ScanOutcome.noNetwork,
          verifyDelay: const Duration(milliseconds: 30),
          verifyResults: {origin: server('100.64.0.10', ms: 89)},
        ),
      );

      await c.scan(manual: false);
      expect(entryFor(c, '100.64.0.10:5001').server.reachable, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(entryFor(c, '100.64.0.10:5001').server.reachable, isTrue);
      expect(entryFor(c, '100.64.0.10:5001').server.latencyMs, 89);
    });

    // Review finding 7: the scan added rows without checking for one already
    // added by the saved-server check.
    test('a server both saved and discovered appears once', () async {
      const origin = 'http://192.168.0.102:5001';
      SharedPreferences.setMockInitialValues({
        'devCustomServers': [origin],
      });
      final c = await buildController(
        scanner: FakeScanner(
          found: [server('192.168.0.102')],
          verifyResults: {origin: server('192.168.0.102')},
        ),
      );

      await c.scan(manual: false);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        endpoints(c).where((e) => e == '192.168.0.102:5001'),
        hasLength(1),
      );
    });

    test(
      'saving a discovered server moves its row instead of adding one',
      () async {
        final c = await buildController(
          scanner: FakeScanner(
            found: [server('192.168.0.102'), server('192.168.0.111')],
          ),
        );
        await c.scan(manual: false);

        await c.addCustom('http://192.168.0.111:5001');

        expect(endpoints(c), ['192.168.0.111:5001', '192.168.0.102:5001']);
        expect(entryFor(c, '192.168.0.111:5001').custom, isTrue);
        expect(entryFor(c, '192.168.0.111:5001').server.reachable, isTrue);
      },
    );

    // Review finding 6: addresses were stored as typed and matched normalised,
    // so one saved without a port could never be forgotten.
    test('an address saved without a port can be forgotten', () async {
      SharedPreferences.setMockInitialValues({
        'devCustomServers': ['https://box.example.com'],
      });
      final c = await buildController();
      final entry = entryFor(c, 'box.example.com:443');
      expect(entry.custom, isTrue);

      await c.forget(entry);

      expect(c.servers, isEmpty);
      expect(await c.store.customOrigins(), isEmpty);
    });

    test('an address added without a port can be forgotten at once', () async {
      final c = await buildController();
      await c.addCustom('https://box.example.com');

      await c.forget(c.servers.single);

      expect(c.servers, isEmpty);
      expect(await c.store.customOrigins(), isEmpty);
    });

    test('a saved address is written in its normal form', () async {
      final c = await buildController();
      await c.addCustom('http://10.0.0.4');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('devCustomServers'), ['http://10.0.0.4:5001']);
    });

    test('saving the same address twice keeps one row', () async {
      final c = await buildController();
      await c.addCustom('http://10.0.0.4');
      await c.addCustom('http://10.0.0.4');

      expect(endpoints(c), ['10.0.0.4:5001']);
      expect(await c.store.customOrigins(), ['http://10.0.0.4:5001']);
    });

    test(
      'saving an address under the other scheme switches it in place',
      () async {
        SharedPreferences.setMockInitialValues({
          'devCustomServers': ['http://192.168.0.5:8443'],
        });
        final committed = <String>[];
        final c = await buildController(committed: committed);

        await c.addCustom('https://192.168.0.5:8443');

        expect(endpoints(c), ['192.168.0.5:8443']);
        expect(entryFor(c, '192.168.0.5:8443').server.scheme, 'https');
        expect(await c.store.customOrigins(), ['https://192.168.0.5:8443']);
        expect(committed, ['https://192.168.0.5:8443/api/v1/']);
      },
    );

    test('a late check under the old scheme does not undo a switch', () async {
      const old = 'http://192.168.0.5:8443';
      SharedPreferences.setMockInitialValues({
        'devCustomServers': [old],
      });
      final c = await buildController(
        scanner: FakeScanner(
          verifyDelay: const Duration(milliseconds: 30),
          verifyResults: {old: server('192.168.0.5', port: 8443)},
        ),
      );

      unawaited(c.refreshSaved());
      await c.addCustom('https://192.168.0.5:8443');
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(entryFor(c, '192.168.0.5:8443').server.scheme, 'https');
    });

    test('saving a discovered server under https keeps its name', () async {
      final c = await buildController(
        scanner: FakeScanner(found: [server('192.168.0.111', name: 'ci-box')]),
      );
      await c.scan(manual: false);

      await c.addCustom('https://192.168.0.111:5001');

      final entry = entryFor(c, '192.168.0.111:5001');
      expect(entry.server.scheme, 'https');
      expect(entry.displayName, 'ci-box');
    });

    test('a late check from an earlier save does not undo a switch', () async {
      final c = await buildController(
        scanner: FakeScanner(
          verifyDelay: const Duration(milliseconds: 30),
          verifyResults: {
            'http://192.168.0.5:8443': server('192.168.0.5', port: 8443),
          },
        ),
      );

      final first = c.addCustom('http://192.168.0.5:8443');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await c.addCustom('https://192.168.0.5:8443');
      await first;

      expect(entryFor(c, '192.168.0.5:8443').server.scheme, 'https');
    });

    test('switching the scheme of a saved address keeps the order', () async {
      SharedPreferences.setMockInitialValues({
        'devCustomServers': ['http://10.1.1.1:5001', 'http://192.168.0.5:8443'],
      });
      final c = await buildController(
        scanner: FakeScanner(found: [server('192.168.0.102')]),
      );
      await c.scan(manual: false);

      await c.addCustom('https://192.168.0.5:8443');

      expect(endpoints(c), [
        '10.1.1.1:5001',
        '192.168.0.5:8443',
        '192.168.0.102:5001',
      ]);
      expect(c.baseOrigin, 'https://192.168.0.5:8443');
    });

    test('stay in place when they become reachable', () async {
      const down = 'http://10.1.1.1:5001';
      const up = 'http://10.1.1.2:5001';
      SharedPreferences.setMockInitialValues({
        'devCustomServers': [down, up],
      });
      final c = await buildController(
        scanner: FakeScanner(
          found: [server('192.168.0.150', ms: 1)],
          verifyDelay: const Duration(milliseconds: 20),
          verifyResults: {up: server('10.1.1.2', ms: 3)},
        ),
      );

      await c.scan(manual: false);
      final before = endpoints(c);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(endpoints(c), before);
      expect(before.take(2), ['10.1.1.1:5001', '10.1.1.2:5001']);
    });

    // A reachable middle row moves under any re-sort of the saved block, in
    // either direction.
    test('the middle one stays in place when it becomes reachable', () async {
      SharedPreferences.setMockInitialValues({
        'devCustomServers': [
          'http://10.1.1.1:5001',
          'http://10.1.1.2:5001',
          'http://10.1.1.3:5001',
        ],
      });
      final c = await buildController(
        scanner: FakeScanner(
          found: [server('192.168.0.150', ms: 1)],
          verifyDelay: const Duration(milliseconds: 20),
          verifyResults: {'http://10.1.1.2:5001': server('10.1.1.2', ms: 3)},
        ),
      );

      await c.scan(manual: false);
      final before = endpoints(c);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(before.take(3), [
        '10.1.1.1:5001',
        '10.1.1.2:5001',
        '10.1.1.3:5001',
      ]);
      expect(endpoints(c), before);
      expect(entryFor(c, '10.1.1.2:5001').server.reachable, isTrue);
    });

    test('adding one stores it normalised, selects it and checks it', () async {
      final committed = <String>[];
      final c = await buildController(
        committed: committed,
        scanner: FakeScanner(
          verifyResults: {
            'https://box.example.com:443': server('box.example.com', port: 443),
          },
        ),
      );

      final stored = await c.addCustom(' https://box.example.com ');

      expect(stored, 'https://box.example.com:443');
      expect(await c.store.customOrigins(), ['https://box.example.com:443']);
      expect(committed.last, 'https://box.example.com:443/api/v1/');
      expect(entryFor(c, 'box.example.com:443').server.reachable, isTrue);
      expect(c.isSelected(entryFor(c, 'box.example.com:443')), isTrue);
    });

    test('rejects input that is not an address', () async {
      final c = await buildController();
      expect(await c.addCustom('not a url'), isNull);
      expect(c.servers, isEmpty);
    });

    test('forgetting one the scan also found keeps it as discovered', () async {
      const origin = 'http://192.168.0.102:5001';
      SharedPreferences.setMockInitialValues({
        'devCustomServers': [origin, 'http://10.9.9.9:5001'],
      });
      final c = await buildController(
        scanner: FakeScanner(
          found: [server('192.168.0.102')],
          verifyResults: {origin: server('192.168.0.102')},
        ),
      );
      await c.scan(manual: false);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await c.forget(entryFor(c, '192.168.0.102:5001'));

      expect(endpoints(c), ['10.9.9.9:5001', '192.168.0.102:5001']);
      expect(entryFor(c, '192.168.0.102:5001').custom, isFalse);
      expect(c.foundCount, 1);
      expect(await c.store.customOrigins(), ['http://10.9.9.9:5001']);
    });

    // Lower-priority finding: pins were keyed by the current subnet, so a
    // tunnel address could not be pinned off the LAN.
    test('a pin on a tunnel address holds on any network', () async {
      final c = await buildController();
      await c.addCustom('http://box.tailnet.example:5001');

      await c.togglePin(entryFor(c, 'box.tailnet.example:5001'));

      expect(entryFor(c, 'box.tailnet.example:5001').pinned, isTrue);
      expect(await c.store.pins(), {
        DevSetupStore.globalPinKey: 'box.tailnet.example',
      });
    });

    for (final (origin, endpoint) in [
      ('https://abc.ngrok.app', 'abc.ngrok.app:443'),
      ('http://100.101.102.103:5001', '100.101.102.103:5001'),
      ('http://10.0.0.5:5001', '10.0.0.5:5001'),
    ]) {
      test(
        'a pin an older screen keyed by the phone subnet still holds: $origin',
        () async {
          final host = Uri.parse(origin).host;
          SharedPreferences.setMockInitialValues({
            'devCustomServers': [origin],
            'devServerPins': '{"192.168.1.":"$host"}',
          });
          final c = await buildController();
          expect(entryFor(c, endpoint).pinned, isTrue);

          await c.togglePin(entryFor(c, endpoint));
          expect(entryFor(c, endpoint).pinned, isFalse);
          expect(await c.store.pins(), isEmpty);

          await c.togglePin(entryFor(c, endpoint));
          final relaunched = await buildController();
          expect(entryFor(relaunched, endpoint).pinned, isTrue);
        },
      );
    }

    test('a junk pin from an older screen leaves the real one held', () async {
      SharedPreferences.setMockInitialValues({
        'devCustomServers': ['https://abc.ngrok.app', 'http://10.0.0.5:5001'],
        'devServerPins': '{"192.168.1.":null,"192.168.0.":"abc.ngrok.app"}',
      });
      final c = await buildController();
      expect(entryFor(c, 'abc.ngrok.app:443').pinned, isTrue);

      await c.togglePin(entryFor(c, '10.0.0.5:5001'));
      final relaunched = await buildController();

      expect(entryFor(relaunched, 'abc.ngrok.app:443').pinned, isTrue);
      expect(entryFor(relaunched, '10.0.0.5:5001').pinned, isTrue);
    });

    test('an IPv6 literal written another way is the same server', () async {
      final c = await buildController();
      await c.addCustom('http://[::1]:5001');
      await c.togglePin(entryFor(c, '[::1]:5001'));

      await c.addCustom('http://[0:0:0:0:0:0:0:1]:5001');
      await c.addCustom('http://[0::1]');

      expect(endpoints(c), ['[::1]:5001']);
      expect(await c.store.customOrigins(), ['http://[::1]:5001']);
      expect(entryFor(c, '[::1]:5001').pinned, isTrue);
      expect(c.isSelected(entryFor(c, '[::1]:5001')), isTrue);

      c.urlController.text = '[0:0:0:0:0:0:0:1]:5001';
      c.onUrlEdited();
      expect(c.isSelected(entryFor(c, '[::1]:5001')), isTrue);
    });

    test(
      'an IPv6 literal is saved, selected and checked in brackets',
      () async {
        final committed = <String>[];
        final c = await buildController(
          committed: committed,
          scanner: FakeScanner(
            verifyResults: {'http://[::1]:5001': server('::1', ms: 4)},
          ),
        );

        final stored = await c.addCustom('http://[::1]');

        expect(stored, 'http://[::1]:5001');
        expect(await c.store.customOrigins(), ['http://[::1]:5001']);
        expect(committed, ['http://[::1]:5001/api/v1/']);
        final entry = entryFor(c, '[::1]:5001');
        expect(entry.custom, isTrue);
        expect(entry.server.reachable, isTrue);
        expect(c.isSelected(entry), isTrue);
      },
    );
  });

  group('health', () {
    test('marks the URL online when it answers and offline when not', () async {
      final c = await buildController(
        scanner: FakeScanner(
          verifyResults: {
            'https://staging.example.com:443': server('staging.example.com'),
          },
        ),
      );

      await c.checkHealth();
      expect(c.settledStatus, PingStatus.online);
      expect(c.canProceed, isTrue);

      c.urlController.text = 'down.example.com';
      c.onUrlEdited();
      await c.checkHealth();
      expect(c.settledStatus, PingStatus.offline);
      expect(c.canProceed, isFalse);
    });

    test('an empty field is idle, not offline', () async {
      final c = await buildController();
      c.urlController.clear();
      await c.checkHealth();
      expect(c.pingStatus, PingStatus.idle);
      expect(c.isValid, isFalse);
    });

    test('paused pinging skips its turns and checks again on resume', () async {
      final fake = FakeScanner();
      final c = await buildController(
        scanner: fake,
        pingInterval: const Duration(milliseconds: 10),
      );
      addTearDown(c.dispose);
      c.startPinging();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fake.verifyCalls, greaterThan(1));

      c.pausePinging();
      await Future<void>.delayed(Duration.zero);
      final paused = fake.verifyCalls;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(fake.verifyCalls, paused);

      c.resumePinging();
      expect(fake.verifyCalls, paused + 1);
    });
  });

  group('after dispose', () {
    test('an init still reading storage stops quietly', () async {
      final fake = FakeScanner();
      final c = DevSetupController(
        defaultBaseUrl: defaultUrl,
        onBaseUrlChanged: (_) {},
        config: testConfig,
        store: testStore(),
        scannerFactory: () => fake,
        pingInterval: const Duration(milliseconds: 10),
      );

      final init = c.init();
      c.dispose();
      await init;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fake.verifyCalls, 0);
      expect(fake.scanCalls, 0);
    });

    test('an init on a slow store starts no checks or scans', () async {
      final fake = FakeScanner();
      final c = DevSetupController(
        defaultBaseUrl: defaultUrl,
        onBaseUrlChanged: (_) {},
        config: testConfig,
        store: SlowStore(),
        scannerFactory: () => fake,
        pingInterval: const Duration(milliseconds: 10),
      );

      final init = c.init();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      c.dispose();
      await init;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(fake.verifyCalls, 0);
      expect(fake.scanCalls, 0);
    });

    test('a choice still being saved restarts no health checks', () async {
      SharedPreferences.setMockInitialValues({
        'devCustomServers': ['http://10.0.0.4:5001'],
      });
      final fake = FakeScanner();
      final c = await buildController(
        scanner: fake,
        pingInterval: const Duration(milliseconds: 10),
      );
      c.startPinging();

      final selecting = c.select(c.servers.single);
      c.dispose();
      await selecting;
      final calls = fake.verifyCalls;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(fake.verifyCalls, calls);
    });

    test('an address still being saved leaves the fields alone', () async {
      final c = await buildController();

      final adding = c.addCustom('http://10.0.0.4');
      c.dispose();

      expect(await adding, 'http://10.0.0.4:5001');
    });

    test('an address saved again is not checked once disposed', () async {
      SharedPreferences.setMockInitialValues({
        'devCustomServers': ['http://10.0.0.4:5001'],
      });
      final fake = FakeScanner();
      final c = await buildController(scanner: fake);

      final adding = c.addCustom('http://10.0.0.4:5001');
      c.dispose();
      await adding;

      expect(fake.verifyCalls, 0);
    });

    // testWidgets fails a test that ends with a timer still pending.
    testWidgets('no ping timer outlives the controller', (tester) async {
      SharedPreferences.setMockInitialValues({
        'devCustomServers': ['http://10.0.0.4:5001'],
      });
      final c = await buildController(pingInterval: const Duration(seconds: 1));
      c.startPinging();

      final selecting = c.select(c.servers.single);
      c.dispose();
      await tester.pump(Duration.zero);
      await selecting;
      c.startPinging();
    });

    test('scanning and checking do nothing', () async {
      final fake = FakeScanner(found: [server('192.168.0.102')]);
      final c = await buildController(scanner: fake);
      c.dispose();

      await c.scan();
      c.startPinging();
      await c.checkHealth();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fake.scanCalls, 0);
      expect(fake.verifyCalls, 0);
    });
  });

  group('restoring', () {
    test('picks up the committed URL and splits out the scheme', () async {
      SharedPreferences.setMockInitialValues({
        'devBaseUrl': 'https://100.64.0.10:8443/api/v1/',
        'devBaseUrlSuffix': '/api/v1/',
      });
      final c = await buildController();
      expect(c.scheme, 'https');
      expect(c.urlController.text, '100.64.0.10:8443');
      expect(c.fullUrl, 'https://100.64.0.10:8443/api/v1/');
    });

    test('keeps an explicit default port', () async {
      SharedPreferences.setMockInitialValues({
        'devBaseUrl': 'http://192.168.0.5:80/api/v1/',
        'devBaseUrlSuffix': '/api/v1/',
      });
      final c = await buildController();
      expect(c.urlController.text, '192.168.0.5:80');
      expect(c.fullUrl, 'http://192.168.0.5:80/api/v1/');
    });

    test('puts an IPv6 literal back in the field in brackets', () async {
      SharedPreferences.setMockInitialValues({
        'devBaseUrl': 'http://[::1]:5001/api/v1/',
        'devBaseUrlSuffix': '/api/v1/',
      });
      final c = await buildController(
        scanner: FakeScanner(
          verifyResults: {'http://[::1]:5001': server('::1')},
        ),
      );

      expect(c.urlController.text, '[::1]:5001');
      expect(c.baseOrigin, 'http://[::1]:5001');
      expect(c.fullUrl, 'http://[::1]:5001/api/v1/');
      await c.checkHealth();
      expect(c.settledStatus, PingStatus.online);
    });

    test('keeps a path prefix rather than dropping it', () async {
      SharedPreferences.setMockInitialValues({
        'devBaseUrl': 'https://example.com/svc/api/v1/',
        'devBaseUrlSuffix': '/api/v1/',
      });
      final c = await buildController();
      expect(c.fullUrl, 'https://example.com/svc/api/v1/');
    });

    test('survives a key that holds another type', () async {
      SharedPreferences.setMockInitialValues({
        'devBaseUrl': 'http://10.0.0.4:5001/api/v1/',
        'devCustomServers': '["http://10.0.0.4:5001"]',
        'devDiscoveredOctet': '4',
      });
      final c = await buildController();

      expect(c.fullUrl, 'http://10.0.0.4:5001/api/v1/');
      expect(c.servers, isEmpty);
    });
  });
}
