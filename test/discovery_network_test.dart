import 'dart:io';

import 'package:flutter_dev_setup/flutter_dev_setup.dart';
import 'package:flutter_test/flutter_test.dart';

// Real sockets on loopback. Kept free of the widget binding, which would
// replace HttpClient with a stub.

Future<HttpServer> serve(void Function(HttpRequest request) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  return server;
}

DiscoveryConfig configFor(int port) => DiscoveryConfig(
  ports: [port],
  healthPath: '/api/ping',
  isHealthy: (status, body) => status == 200 && body.contains('Success'),
  connectTimeout: const Duration(milliseconds: 300),
  verifyTimeout: const Duration(seconds: 2),
  concurrency: 128,
);

void main() {
  late HttpServer server;
  late int port;

  setUp(() async {
    server = await serve((request) {
      if (request.uri.path != '/api/ping') {
        request.response.statusCode = 404;
      } else {
        request.response.headers
          ..add('x-dev-host', 'dev-laptop')
          ..add('x-dev-host', 'dev-laptop-2');
        request.response.write('Success');
      }
      request.response.close();
    });
    port = server.port;
  });

  tearDown(() => server.close(force: true));

  test(
    'verify returns the server with its latency and advertised name',
    () async {
      final found = await DevServerDiscovery(
        config: configFor(port),
      ).verify('127.0.0.1', port);
      expect(found, isNotNull);
      expect(found!.reachable, isTrue);
      // dart:io folds the repeated header into one comma-joined value.
      expect(found.hostname, 'dev-laptop');
    },
  );

  // Regression: `headers.value` throws on a header sent as several lines, and
  // that rejected a healthy server.
  test('a name header repeated on separate lines does not reject it', () async {
    final split = await serve((request) {
      request.response.headers
        ..noFolding('x-dev-host')
        ..add('x-dev-host', 'build-box')
        ..add('x-dev-host', 'build-box-2');
      request.response.write('Success');
      request.response.close();
    });
    addTearDown(() => split.close(force: true));

    final found = await DevServerDiscovery(
      config: configFor(split.port),
    ).verify('127.0.0.1', split.port);

    expect(found?.hostname, 'build-box');
  });

  test('a health path without a leading slash still matches', () async {
    final config = DiscoveryConfig(
      ports: [port],
      healthPath: 'api/ping',
      isHealthy: (status, body) => body.contains('Success'),
    );
    expect(
      await DevServerDiscovery(config: config).verify('127.0.0.1', port),
      isNotNull,
    );
  });

  test('accepts a body that is not valid UTF-8', () async {
    final latin1 = await serve((request) {
      request.response.add([0x63, 0x61, 0x66, 0xE9]);
      request.response.close();
    });
    addTearDown(() => latin1.close(force: true));

    final found = await DevServerDiscovery(
      config: DiscoveryConfig(ports: [latin1.port]),
    ).verify('127.0.0.1', latin1.port);

    expect(found, isNotNull);
  });

  test('hands isHealthy at most the first megabyte of the body', () async {
    final huge = await serve((request) {
      final chunk = List<int>.filled(64 * 1024, 0x61);
      for (var i = 0; i < 64; i++) {
        request.response.add(chunk);
      }
      request.response.close().ignore();
    });
    addTearDown(() => huge.close(force: true));
    int? seen;

    final found = await DevServerDiscovery(
      config: DiscoveryConfig(
        ports: [huge.port],
        isHealthy: (status, body) {
          seen = body.length;
          return true;
        },
      ),
    ).verify('127.0.0.1', huge.port);

    expect(found, isNotNull);
    expect(seen, 1024 * 1024);
  });

  test('verify rejects a server the health check does not accept', () async {
    final strict = DiscoveryConfig(
      ports: [port],
      healthPath: '/api/ping',
      isHealthy: (status, body) => body.contains('Something else'),
    );
    expect(
      await DevServerDiscovery(config: strict).verify('127.0.0.1', port),
      isNull,
    );
  });

  test('tcpProbe tells an open port from a refused one', () async {
    final discovery = DevServerDiscovery(config: configFor(port));
    final spare = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = spare.port;
    await spare.close();

    expect(await discovery.tcpProbe('127.0.0.1', port), PortState.open);
    expect(
      await discovery.tcpProbe('127.0.0.1', closedPort),
      PortState.refused,
    );
  });

  test('verifyOrigin takes a typed address', () async {
    final found = await DevServerDiscovery(
      config: configFor(port),
    ).verifyOrigin('http://127.0.0.1:$port');
    expect(found?.origin, 'http://127.0.0.1:$port');
  });

  test('isReachable answers for a live server and a dead one', () async {
    final config = configFor(port);
    expect(
      await DevSetup.isReachable(
        'http://127.0.0.1:$port/api/v1/',
        config: config,
      ),
      isTrue,
    );
    final spare = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = spare.port;
    await spare.close();
    expect(
      await DevSetup.isReachable('http://127.0.0.1:$deadPort/', config: config),
      isFalse,
    );
  });

  // The app sends a port-less http URL to :80, so the check must go there
  // too, not to the first dev port.
  test('isReachable checks a URL without a port on 80', () async {
    final config = configFor(port);
    expect(
      await DevSetup.isReachable('http://127.0.0.1:$port/', config: config),
      isTrue,
    );
    expect(
      await DevSetup.isReachable('http://127.0.0.1/api/v1/', config: config),
      isFalse,
    );
  });

  test('the emulator path finds a server on the host alias', () async {
    final found = <DevServer>[];
    final summary = await DevServerDiscovery(
      config: configFor(port),
      isEmulator: () async => true,
    ).scan(onFound: found.add);
    expect(summary.outcome, ScanOutcome.found);
    expect(found.single.port, port);
  });

  test('no LAN address means no network rather than an empty sweep', () async {
    final summary = await DevServerDiscovery(
      config: configFor(port),
      isEmulator: () async => false,
      lanAddress: () async => null,
    ).scan(onFound: (_) {});
    expect(summary.outcome, ScanOutcome.noNetwork);
  });

  test('a full sweep finds the server and reports progress', () async {
    final found = <DevServer>[];
    var lastProgress = 0;
    final summary =
        await DevServerDiscovery(
          config: configFor(port),
          isEmulator: () async => false,
          lanAddress: () async => '127.0.0.254',
        ).scan(
          onFound: found.add,
          onProgress: (probed, total, label) => lastProgress = probed,
        );
    expect(summary.outcome, ScanOutcome.found);
    expect(summary.label, '127.0.0.0/24');
    expect(found.map((s) => s.host), contains('127.0.0.1'));
    expect(lastProgress, 253);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('cancel stops a sweep', () async {
    final discovery = DevServerDiscovery(
      config: configFor(port),
      isEmulator: () async => false,
      lanAddress: () async => '127.0.0.254',
    );
    final scanning = discovery.scan(onFound: (_) {});
    discovery.cancel();
    expect((await scanning).outcome, ScanOutcome.cancelled);
  });
}
