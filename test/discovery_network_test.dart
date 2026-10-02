import 'dart:async';
import 'dart:io';

import 'package:flutter_dev_setup/flutter_dev_setup.dart';
import 'package:flutter_test/flutter_test.dart';

// Real sockets on loopback. Kept free of the widget binding, which would
// replace HttpClient with a stub.

Future<HttpServer> serve(
  void Function(HttpRequest request) handler, {
  InternetAddress? address,
}) async {
  final server = await HttpServer.bind(
    address ?? InternetAddress.loopbackIPv4,
    0,
  );
  server.listen(handler);
  return server;
}

void answerPing(HttpRequest request) {
  if (request.uri.path != '/api/ping') {
    request.response.statusCode = 404;
  } else {
    request.response.headers
      ..add('x-dev-host', 'dev-laptop')
      ..add('x-dev-host', 'dev-laptop-2');
    request.response.write('Success');
  }
  request.response.close();
}

DiscoveryConfig configFor(int port) => DiscoveryConfig(
  ports: [port],
  healthPath: '/api/ping',
  isHealthy: (status, body) => status == 200 && body.contains('Success'),
  routerAddresses: const [],
  connectTimeout: const Duration(milliseconds: 300),
  verifyTimeout: const Duration(seconds: 2),
  concurrency: 128,
);

DiscoveryConfig emulatorConfigFor(
  int port, {
  List<String> routers = const [],
}) => DiscoveryConfig(
  ports: [port],
  healthPath: '/api/ping',
  isHealthy: (status, body) => status == 200 && body.contains('Success'),
  routerAddresses: routers,
  emulatorConnectTimeout: const Duration(milliseconds: 300),
  verifyTimeout: const Duration(seconds: 2),
  concurrency: 128,
);

/// The health check of a host machine that lists its LAN addresses, one
/// header line per entry.
void Function(HttpRequest request) answerPingListing(List<String> lan) =>
    (request) {
      request.response.headers.noFolding('x-dev-lan');
      for (final line in lan) {
        request.response.headers.add('x-dev-lan', line);
      }
      answerPing(request);
    };

/// Loopback stands in for the LAN.
bool loopbackIsLan(String ip) => ip.startsWith('127.');

/// Nothing listens there for a server bound to IPv4 loopback.
const deadAlias = '::1';

/// What an emulator scan reported, in order.
class ScanLog {
  final found = <String>[];
  final preferred = <String>[];
  final subnets = <String>[];
  final events = <String>[];
  final labels = <String>[];
  var lastProbed = 0;
  var lastTotal = 0;

  Future<ScanSummary> run(
    DevServerDiscovery discovery, {
    String? currentHost,
    String? rememberedHost,
    Iterable<String> knownHosts = const [],
  }) => discovery.scan(
    currentHost: currentHost,
    rememberedHost: rememberedHost,
    knownHosts: knownHosts,
    onFound: (server) {
      found.add(server.host);
      events.add('found ${server.host}');
    },
    onPreferred: (server) {
      preferred.add(server.host);
      events.add('preferred ${server.host}');
    },
    onSubnet: (base) {
      subnets.add(base);
      events.add('subnet $base');
    },
    onProgress: (probed, total, label) {
      if (labels.isEmpty || labels.last != label) labels.add(label);
      lastProbed = probed;
      lastTotal = total;
    },
  );
}

/// Records each TCP probe as `host:port`, with its budget, and answers it
/// without a socket: refused for the hosts in [live], dead for the rest.
class ProbeRecorder extends DevServerDiscovery {
  ProbeRecorder({
    required super.config,
    required super.isEmulator,
    required super.lanAddress,
    super.emulatorHost,
    super.isLanAddress,
    super.routerProbe,
    this.live = const {},
  });

  final Set<String> live;
  final probes = <String>[];
  final budgets = <Duration?>{};

  @override
  Future<PortState> tcpProbe(String host, int port, {Duration? timeout}) async {
    probes.add('$host:$port');
    budgets.add(timeout);
    return live.contains(host) ? PortState.refused : PortState.dead;
  }
}

Future<bool> canBind(InternetAddress address) async {
  try {
    await (await ServerSocket.bind(address, 0)).close();
    return true;
  } on SocketException {
    return false;
  }
}

Future<void> main() async {
  final hasIpv6Loopback = await canBind(InternetAddress.loopbackIPv6);
  late HttpServer server;
  late int port;

  setUp(() async {
    server = await serve(answerPing);
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

  test('a query in the health path is sent as a query', () async {
    final queried = await serve((request) {
      final probe = request.uri.queryParameters['probe'];
      request.response.statusCode =
          request.uri.path == '/api/ping' && probe == '1' ? 200 : 404;
      request.response.close();
    });
    addTearDown(() => queried.close(force: true));
    final config = DiscoveryConfig(
      ports: [queried.port],
      healthPath: '/api/ping?probe=1',
    );

    expect(
      await DevServerDiscovery(
        config: config,
      ).verify('127.0.0.1', queried.port),
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

  // The sweep's connect budget used to cap the health check's connection too,
  // so DNS, TCP and TLS to a live server from an emulator (often over a
  // second) timed out and a healthy server flickered between online and not.
  test(
    'a health check connects within verifyTimeout, not the sweep budget',
    () async {
      final made = <HttpClient>[];
      final discovery = DevServerDiscovery(
        config: DiscoveryConfig(
          ports: [port],
          healthPath: '/api/ping',
          isHealthy: (status, body) =>
              status == 200 && body.contains('Success'),
          connectTimeout: const Duration(milliseconds: 50),
          verifyTimeout: const Duration(seconds: 3),
        ),
        httpClient: () {
          final client = HttpClient();
          made.add(client);
          return client;
        },
      );

      expect(await discovery.verify('127.0.0.1', port), isNotNull);
      expect(await discovery.verifyOrigin('http://127.0.0.1:$port'), isNotNull);
      expect(made, hasLength(2));
      for (final client in made) {
        expect(client.connectionTimeout, const Duration(seconds: 3));
      }
    },
  );

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

  group(
    'on the IPv6 loopback',
    skip: hasIpv6Loopback ? false : 'this machine has no IPv6 loopback',
    () {
      late HttpServer v6;

      setUp(() async {
        v6 = await serve(answerPing, address: InternetAddress.loopbackIPv6);
      });

      tearDown(() => v6.close(force: true));

      test('verify reaches a server by its bare address', () async {
        final found = await DevServerDiscovery(
          config: configFor(v6.port),
        ).verify('::1', v6.port);

        expect(found?.host, '::1');
        expect(found?.hostname, 'dev-laptop');
        expect(found?.origin, 'http://[::1]:${v6.port}');
      });

      test('verifyOrigin takes a bracketed address', () async {
        final found = await DevServerDiscovery(
          config: configFor(v6.port),
        ).verifyOrigin('http://[::1]:${v6.port}/api/v1/');

        expect(found?.origin, 'http://[::1]:${v6.port}');
      });

      test('isReachable answers for a saved IPv6 URL', () async {
        final config = configFor(v6.port);
        expect(
          await DevSetup.isReachable(
            'http://[::1]:${v6.port}/api/v1/',
            config: config,
          ),
          isTrue,
        );

        final spare = await ServerSocket.bind(InternetAddress.loopbackIPv6, 0);
        final deadPort = spare.port;
        await spare.close();
        expect(
          await DevSetup.isReachable(
            'http://[::1]:$deadPort/api/v1/',
            config: config,
          ),
          isFalse,
        );
      });
    },
  );

  test('the emulator path finds a server on the host alias', () async {
    final found = <DevServer>[];
    final summary = await DevServerDiscovery(
      config: configFor(port),
      isEmulator: () async => true,
      lanAddress: () async => null,
    ).scan(onFound: found.add);
    expect(summary.outcome, ScanOutcome.found);
    expect(summary.label, 'emulator host');
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

  test('a router answers by accepting or refusing, never by staying '
      'silent or unreachable', () async {
    final open = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(open.close);
    open.listen((socket) => socket.destroy());
    final spare = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = spare.port;
    await spare.close();
    const timeout = Duration(milliseconds: 300);
    Future<bool> answers(List<int> ports) => DevServerDiscovery.routerAnswers(
      '127.0.0.1',
      ports: ports,
      timeout: timeout,
    );
    Future<bool> failingWith(int errorCode) => DevServerDiscovery.routerAnswers(
      '192.0.2.1',
      timeout: timeout,
      connect: (host, port, {timeout}) =>
          Future.error(SocketException('', osError: OSError('', errorCode))),
    );
    const timedOut = 110;

    expect(await answers([open.port]), isTrue);
    expect(await answers([closedPort]), isTrue);
    expect(await failingWith(timedOut), isFalse);
    for (final (hostUnreachable, netUnreachable) in [(113, 101), (65, 51)]) {
      expect(await failingWith(hostUnreachable), isFalse);
      expect(await failingWith(netUnreachable), isFalse);
    }
  });

  test('a router counts when either port 80 or port 53 answers', () async {
    final open = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(open.close);
    open.listen((socket) => socket.destroy());
    const timedOut = SocketException('', osError: OSError('', 110));
    final tried = <int>[];
    Future<bool> answeringOn(int answering) => DevServerDiscovery.routerAnswers(
      '192.0.2.1',
      timeout: const Duration(milliseconds: 300),
      connect: (host, port, {timeout}) {
        tried.add(port);
        return port == answering
            ? Socket.connect(InternetAddress.loopbackIPv4, open.port)
            : Future.error(timedOut);
      },
    );

    expect(await answeringOn(80), isTrue);
    expect(await answeringOn(53), isTrue);
    expect(tried, [80, 53, 80, 53]);
  });

  test('rejects a host that redirects to a healthy server', () async {
    final asked = <String>[];
    final target = await serve((request) {
      asked.add(request.uri.path);
      answerPing(request);
    });
    addTearDown(() => target.close(force: true));
    final redirector = await serve((request) {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set('location', 'http://127.0.0.1:${target.port}/api/ping');
      request.response.close();
    });
    addTearDown(() => redirector.close(force: true));

    final found = await DevServerDiscovery(
      config: configFor(redirector.port),
    ).verify('127.0.0.1', redirector.port);

    expect(found, isNull);
    expect(asked, isEmpty);
  });

  test('a physical device never reports a preferred server', () async {
    final found = <DevServer>[];
    final preferred = <DevServer>[];
    final summary = await DevServerDiscovery(
      config: configFor(port),
      isEmulator: () async => false,
      lanAddress: () async => '127.0.0.254',
    ).scan(onFound: found.add, onPreferred: preferred.add);
    expect(summary.outcome, ScanOutcome.found);
    expect(found.map((s) => s.host), contains('127.0.0.1'));
    expect(preferred, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a phone probes within connectTimeout and an emulator within '
      'emulatorConnectTimeout, fallback ports included', () async {
    final spare = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = spare.port;
    await spare.close();
    final config = DiscoveryConfig(
      ports: [port, deadPort],
      routerAddresses: const [],
      connectTimeout: const Duration(milliseconds: 100),
      emulatorConnectTimeout: const Duration(milliseconds: 900),
    );
    ProbeRecorder recorder({required bool emulator}) => ProbeRecorder(
      config: config,
      isEmulator: () async => emulator,
      lanAddress: () async => '192.168.77.50',
      emulatorHost: deadAlias,
      live: {'192.168.77.20'},
    );

    final phone = recorder(emulator: false);
    await phone.scan(onFound: (_) {});
    final emulator = recorder(emulator: true);
    await emulator.scan(onFound: (_) {});

    for (final (recorded, budget, length) in [
      (phone, config.connectTimeout, 254),
      (emulator, config.emulatorConnectTimeout, 255),
    ]) {
      expect(recorded.probes, hasLength(length));
      expect(recorded.probes, contains('192.168.77.20:$deadPort'));
      expect(recorded.budgets, {budget});
    }
    expect(phone.probes, isNot(contains('192.168.77.50:$port')));
    expect(emulator.probes, contains('192.168.77.50:$port'));
  });

  group('on an emulator', () {
    DevServerDiscovery emulator({
      required int port,
      required String alias,
      String? lanAddress,
      List<String> routers = const [],
      Future<bool> Function(String host)? routerProbe,
    }) => DevServerDiscovery(
      config: emulatorConfigFor(port, routers: routers),
      isEmulator: () async => true,
      lanAddress: () async => lanAddress,
      emulatorHost: alias,
      isLanAddress: loopbackIsLan,
      routerProbe: routerProbe,
    );

    test('reports the alias as found and preferred', () async {
      final log = ScanLog();
      final summary = await log.run(
        emulator(port: port, alias: '127.0.0.1', lanAddress: '10.0.2.16'),
      );
      expect(log.events, ['found 127.0.0.1', 'preferred 127.0.0.1']);
      expect(log.labels, ['emulator host']);
      expect(summary.outcome, ScanOutcome.found);
      expect(summary.label, 'emulator host');
      expect(summary.subnetBase, isNull);
      expect(summary.fallback, isNull);
    });

    test('with no LAN in sight, offers a dead alias anyway', () async {
      final log = ScanLog();
      final summary = await log.run(
        emulator(port: port, alias: deadAlias, lanAddress: '10.0.2.16'),
      );
      expect(log.events, isEmpty);
      expect(summary.outcome, ScanOutcome.notFound);
      expect(summary.label, 'emulator host');
      expect(summary.subnetBase, isNull);
      expect(summary.fallback?.endpoint, '[::1]:$port');
      expect(summary.fallback?.latencyMs, 0);
    });

    test(
      'sweeps the subnet of its own LAN address when the alias is dead',
      () async {
        final log = ScanLog();
        final summary = await log.run(
          emulator(port: port, alias: deadAlias, lanAddress: '127.0.0.254'),
        );
        expect(log.events, ['subnet 127.0.0.', 'found 127.0.0.1']);
        expect(log.labels, ['emulator host', '127.0.0.0/24']);
        expect(log.lastProbed, 254);
        expect(log.lastTotal, 254);
        expect(summary.outcome, ScanOutcome.found);
        expect(summary.label, 'emulator host and 127.0.0.0/24');
        expect(summary.subnetBase, '127.0.0.');
        expect(summary.fallback?.endpoint, '[::1]:$port');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('reports the alias as preferred before it sweeps', () async {
      final log = ScanLog();
      final summary = await log.run(
        emulator(port: port, alias: '127.0.0.1', lanAddress: '127.0.0.254'),
      );
      expect(log.events, [
        'found 127.0.0.1',
        'preferred 127.0.0.1',
        'subnet 127.0.0.',
      ]);
      expect(log.lastTotal, 253);
      expect(summary.outcome, ScanOutcome.found);
      expect(summary.label, 'emulator host and 127.0.0.0/24');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test(
      'lists the host by the address it lists as well as by the alias',
      () async {
        final host = await serve(answerPingListing(['127.0.0.1']));
        addTearDown(() => host.close(force: true));
        final log = ScanLog();

        final summary = await log.run(
          emulator(port: host.port, alias: 'localhost'),
        );

        expect(log.found, ['localhost', '127.0.0.1']);
        expect(log.subnets, ['127.0.0.']);
        expect(log.lastTotal, 254);
        expect(summary.label, 'emulator host and 127.0.0.0/24');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'sweeps at most two subnets the host lists, however the lines split',
      () async {
        final host = await serve(
          answerPingListing(['127.0.0.5, not-an-ip', '127.0.1.5', '127.0.2.5']),
        );
        addTearDown(() => host.close(force: true));
        final log = ScanLog();

        final summary = await log.run(
          emulator(port: host.port, alias: '127.0.0.1'),
        );

        expect(log.subnets, ['127.0.0.', '127.0.1.']);
        expect(log.labels, ['emulator host', '127.0.0.0/24', '127.0.1.0/24']);
        expect(log.found, ['127.0.0.1']);
        expect(summary.outcome, ScanOutcome.found);
        expect(summary.label, 'emulator host and 127.0.0.0/24, 127.0.1.0/24');
        expect(summary.subnetBase, '127.0.0.');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('ignores the list when lanAddressHeader is off', () async {
      final host = await serve(answerPingListing(['127.0.0.5']));
      addTearDown(() => host.close(force: true));
      final log = ScanLog();

      final summary = await log.run(
        DevServerDiscovery(
          config: DiscoveryConfig(
            ports: [host.port],
            healthPath: '/api/ping',
            lanAddressHeader: null,
            routerAddresses: const [],
          ),
          isEmulator: () async => true,
          lanAddress: () async => null,
          emulatorHost: '127.0.0.1',
          isLanAddress: loopbackIsLan,
        ),
      );

      expect(log.subnets, isEmpty);
      expect(summary.label, 'emulator host');
    });

    test(
      'sweeps around a host the developer used when nothing else names a LAN',
      () async {
        final log = ScanLog();
        final summary = await log.run(
          emulator(port: port, alias: deadAlias),
          knownHosts: ['box.tailnet.example', '127.0.0.9'],
        );
        expect(log.subnets, ['127.0.0.']);
        expect(log.lastTotal, 254);
        expect(log.found, ['127.0.0.1']);
        expect(summary.outcome, ScanOutcome.found);
        expect(summary.label, 'emulator host and 127.0.0.0/24');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('takes the URL field, then the last server, then other hosts used, '
        'and probes them first', () async {
      final discovery = ProbeRecorder(
        config: emulatorConfigFor(port),
        isEmulator: () async => true,
        lanAddress: () async => null,
        emulatorHost: deadAlias,
        isLanAddress: loopbackIsLan,
      );
      final log = ScanLog();

      final summary = await log.run(
        discovery,
        currentHost: '127.0.3.9',
        rememberedHost: '127.0.4.9',
        knownHosts: ['127.0.5.9', '127.0.3.7'],
      );

      expect(log.subnets, ['127.0.3.', '127.0.4.']);
      expect(discovery.probes, hasLength(508));
      expect(discovery.probes.take(3), [
        '127.0.3.9:$port',
        '127.0.3.7:$port',
        '127.0.3.100:$port',
      ]);
      expect(discovery.probes[254], '127.0.4.9:$port');
      expect(summary.label, 'emulator host and 127.0.3.0/24, 127.0.4.0/24');
    });

    test('with nothing answering anywhere, offers the alias anyway', () async {
      final spare = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = spare.port;
      await spare.close();
      final log = ScanLog();

      final summary = await log.run(
        emulator(port: deadPort, alias: deadAlias, lanAddress: '127.0.0.254'),
      );

      expect(log.found, isEmpty);
      expect(summary.outcome, ScanOutcome.notFound);
      expect(summary.label, 'emulator host and 127.0.0.0/24');
      expect(summary.subnetBase, '127.0.0.');
      expect(summary.fallback?.endpoint, '[::1]:$deadPort');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('sweeps the subnet of a router that answers when nothing else names '
        'a LAN', () async {
      final log = ScanLog();
      final summary = await log.run(
        emulator(
          port: port,
          alias: deadAlias,
          lanAddress: '10.0.2.16',
          routers: ['127.0.9.1', '127.0.0.1'],
          routerProbe: (host) async => host == '127.0.0.1',
        ),
      );
      expect(log.subnets, ['127.0.0.']);
      expect(log.found, ['127.0.0.1']);
      expect(summary.outcome, ScanOutcome.found);
      expect(summary.label, 'emulator host and 127.0.0.0/24');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test(
      'puts the routers that answer ahead of hosts the developer used',
      () async {
        final log = ScanLog();
        await log.run(
          emulator(
            port: port,
            alias: '127.0.0.1',
            routers: ['127.0.5.1', '127.0.6.1'],
            routerProbe: (host) async => host == '127.0.6.1',
          ),
          currentHost: '127.0.7.9',
        );
        expect(log.subnets, ['127.0.6.', '127.0.7.']);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('by default sweeps the LAN behind a cable modem before the '
        "modem's own network", () async {
      final discovery = ProbeRecorder(
        config: DiscoveryConfig(ports: [port]),
        isEmulator: () async => true,
        lanAddress: () async => '10.0.2.16',
        emulatorHost: deadAlias,
        routerProbe: (host) async =>
            {'192.168.100.1', '10.0.0.1'}.contains(host),
      );
      final log = ScanLog();

      await log.run(discovery);

      expect(log.subnets, ['10.0.0.', '192.168.100.']);
    });

    test('sweeps two subnets at most, however many routers answer', () async {
      final discovery = ProbeRecorder(
        config: emulatorConfigFor(
          port,
          routers: ['192.168.0.1', '192.168.1.1', '10.0.0.1'],
        ),
        isEmulator: () async => true,
        lanAddress: () async => '10.0.2.16',
        emulatorHost: deadAlias,
        routerProbe: (_) async => true,
      );
      final log = ScanLog();

      await log.run(discovery, currentHost: '172.16.0.9');

      expect(log.subnets, ['192.168.0.', '192.168.1.']);
    });

    test('ignores the routers when the host lists its LAN', () async {
      final host = await serve(answerPingListing(['127.0.0.5']));
      addTearDown(() => host.close(force: true));
      final log = ScanLog();

      await log.run(
        emulator(
          port: host.port,
          alias: '127.0.0.1',
          routers: ['127.0.6.1'],
          routerProbe: (_) async => true,
        ),
      );

      expect(log.subnets, ['127.0.0.']);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('probes no router when the device address names the LAN', () async {
      final probed = <String>[];
      final log = ScanLog();

      await log.run(
        emulator(
          port: port,
          alias: '127.0.0.1',
          lanAddress: '127.0.0.254',
          routers: ['127.0.6.1'],
          routerProbe: (host) async {
            probed.add(host);
            return true;
          },
        ),
      );

      expect(probed, isEmpty);
      expect(log.subnets, ['127.0.0.']);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('probes the routers while it checks the alias', () async {
      final aliasAsked = Completer<void>();
      final host = await serve((request) {
        if (!aliasAsked.isCompleted) aliasAsked.complete();
        answerPing(request);
      });
      addTearDown(() => host.close(force: true));
      var probedDuringCheck = false;

      await emulator(
        port: host.port,
        alias: '127.0.0.1',
        routers: ['127.0.6.1'],
        routerProbe: (_) async {
          await aliasAsked.future.timeout(
            const Duration(seconds: 2),
            onTimeout: () {},
          );
          probedDuringCheck = aliasAsked.isCompleted;
          return false;
        },
      ).scan(onFound: (_) {});

      expect(probedDuringCheck, isTrue);
    });

    test(
      'on Android ignores its own address, which is inside the emulator',
      () async {
        final probed = <String>[];
        final log = ScanLog();

        await log.run(
          DevServerDiscovery(
            config: emulatorConfigFor(port, routers: ['127.0.0.1']),
            isEmulator: () async => true,
            lanAddress: () async => '127.0.5.2',
            emulatorHost: '127.0.0.1',
            isLanAddress: loopbackIsLan,
            routerProbe: (host) async {
              probed.add(host);
              return false;
            },
            isAndroid: true,
          ),
        );

        expect(probed, ['127.0.0.1']);
        expect(log.subnets, isEmpty);
      },
    );

    test('stops within a sweep, and before the next, when cancelled', () async {
      final host = await serve(answerPingListing(['127.0.0.5', '127.0.1.5']));
      addTearDown(() => host.close(force: true));
      final discovery = emulator(port: host.port, alias: '127.0.0.1');
      final subnets = <String>[];
      var probed = 0;
      var total = 0;

      final summary = await discovery.scan(
        onFound: (_) {},
        onSubnet: subnets.add,
        onProgress: (done, all, label) {
          if (label == 'emulator host') return;
          probed = done;
          total = all;
          if (done >= 5) discovery.cancel();
        },
      );

      expect(subnets, ['127.0.0.']);
      expect(probed, lessThan(total));
      expect(summary.outcome, ScanOutcome.cancelled);
      expect(summary.subnetBase, '127.0.0.');
      expect(summary.label, 'emulator host and 127.0.0.0/24');
    });
  });
}
