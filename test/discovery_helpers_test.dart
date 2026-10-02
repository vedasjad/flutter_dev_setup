import 'package:flutter_dev_setup/flutter_dev_setup.dart';
import 'package:flutter_test/flutter_test.dart';

class RecordingDiscovery extends DevServerDiscovery {
  final checked = <String>[];

  @override
  Future<DevServer?> verify(
    String host,
    int port, {
    String scheme = 'http',
  }) async {
    checked.add('$scheme://$host:$port');
    return null;
  }
}

void main() {
  group('isPrivateIpv4', () {
    test('accepts the RFC1918 ranges', () {
      for (final ip in [
        '10.0.2.2',
        '172.16.4.9',
        '172.31.255.254',
        '192.168.1.120',
      ]) {
        expect(DevServerDiscovery.isPrivateIpv4(ip), isTrue, reason: ip);
      }
    });

    test('rejects public, link-local, CGNAT and malformed addresses', () {
      for (final ip in [
        '8.8.8.8',
        '172.32.0.1',
        '169.254.3.7',
        '100.64.0.1',
        '192.168.1',
        '192.168.1.999',
        'not-an-ip',
      ]) {
        expect(DevServerDiscovery.isPrivateIpv4(ip), isFalse, reason: ip);
      }
    });
  });

  group('interfacePriority', () {
    test('prefers wifi over other usable interfaces', () {
      expect(DevServerDiscovery.interfacePriority('wlan0'), 0);
      expect(DevServerDiscovery.interfacePriority('en0'), 0);
      expect(DevServerDiscovery.interfacePriority('eth0'), 1);
      expect(DevServerDiscovery.interfacePriority('en1'), 2);
    });

    test('skips interfaces that cannot carry the LAN', () {
      for (final name in [
        'awdl0',
        'utun3',
        'tun1',
        'rmnet_data0',
        'p2p0',
        'ap0',
        'pdp_ip0',
        'ipsec0',
        'ppp0',
        'wwan0',
        'seth_lte0',
        'clat4',
        'v4-rmnet_data0',
      ]) {
        expect(
          DevServerDiscovery.interfacePriority(name),
          isNull,
          reason: name,
        );
      }
    });
  });

  group('candidatePhases', () {
    List<List<String>> phasesFor({
      int ownOctet = 137,
      String? rememberedHost,
      String? currentHost,
      int? rememberedOctet,
    }) => DevServerDiscovery.candidatePhases(
      subnetBase: '192.168.1.',
      ownOctet: ownOctet,
      rememberedHost: rememberedHost,
      currentHost: currentHost,
      rememberedOctet: rememberedOctet,
    );

    test('puts known hosts first, in preference order', () {
      final phases = phasesFor(
        rememberedHost: '192.168.1.42',
        currentHost: '192.168.1.7',
        rememberedOctet: 99,
      );
      expect(phases.first, ['192.168.1.42', '192.168.1.7', '192.168.1.99']);
    });

    test('drops known hosts from another subnet but keeps the octet guess', () {
      final phases = phasesFor(
        rememberedHost: '10.1.2.42',
        rememberedOctet: 42,
      );
      expect(phases.first, ['192.168.1.42']);
    });

    test('probes the lease band before the rest of the subnet', () {
      final band = phasesFor()[1];
      expect(band.first, '192.168.1.100');
      expect(band.last, '192.168.1.120');
      expect(band, hasLength(21));
    });

    test('takes a custom band', () {
      final phases = DevServerDiscovery.candidatePhases(
        subnetBase: '10.0.0.',
        ownOctet: 2,
        bandStart: 50,
        bandEnd: 52,
      );
      expect(phases[1], ['10.0.0.50', '10.0.0.51', '10.0.0.52']);
    });

    test('walks outward from our own octet after the band', () {
      expect(phasesFor()[2].take(4), [
        '192.168.1.136',
        '192.168.1.138',
        '192.168.1.135',
        '192.168.1.139',
      ]);
    });

    test('covers every host exactly once, minus our own', () {
      final all = phasesFor(
        rememberedHost: '192.168.1.42',
      ).expand((phase) => phase).toList();
      expect(all.toSet(), hasLength(all.length));
      expect(all, hasLength(253));
      expect(all, isNot(contains('192.168.1.137')));
    });

    test('never proposes our own address even when remembered', () {
      final phases = phasesFor(ownOctet: 110, rememberedHost: '192.168.1.110');
      expect(phases.first, isEmpty);
      expect(phases[1], isNot(contains('192.168.1.110')));
    });

    test('with nothing to exclude, walks outward from the centre itself', () {
      final phases = DevServerDiscovery.candidatePhases(
        subnetBase: '192.168.1.',
        ownOctet: 137,
        exclude: const [],
      );
      final all = phases.expand((phase) => phase).toList();

      expect(phases[2].take(3), [
        '192.168.1.137',
        '192.168.1.136',
        '192.168.1.138',
      ]);
      expect(all, hasLength(254));
      expect(all.toSet(), hasLength(254));
    });

    test('puts known hosts first and never proposes an excluded one', () {
      final phases = DevServerDiscovery.candidatePhases(
        subnetBase: '192.168.0.',
        ownOctet: 100,
        knownHosts: ['192.168.0.101', '192.168.0.100', '10.1.1.1', 'box.lan'],
        exclude: const ['192.168.0.100', '192.168.0.57'],
      );
      final all = phases.expand((phase) => phase).toList();

      expect(phases.first, ['192.168.0.101']);
      expect(phases[2].first, '192.168.0.99');
      expect(all, isNot(contains('192.168.0.100')));
      expect(all, isNot(contains('192.168.0.57')));
      expect(all, hasLength(252));
    });

    test('counts a known host only if isLan accepts it', () {
      final byDefault = DevServerDiscovery.candidatePhases(
        subnetBase: '127.0.0.',
        ownOctet: 1,
        knownHosts: ['127.0.0.9'],
      );
      final loopbackAsLan = DevServerDiscovery.candidatePhases(
        subnetBase: '127.0.0.',
        ownOctet: 1,
        knownHosts: ['127.0.0.9'],
        isLan: (ip) => ip.startsWith('127.'),
      );

      expect(byDefault.first, isEmpty);
      expect(loopbackAsLan.first, ['127.0.0.9']);
    });
  });

  group('emulatorSubnets', () {
    List<String> basesOf(List<({String subnetBase, int centre})> subnets) => [
      for (final subnet in subnets) subnet.subnetBase,
    ];

    test('ranks the host, then the device, then hints, two at most', () {
      final subnets = DevServerDiscovery.emulatorSubnets(
        advertised: ['192.168.0.100'],
        deviceAddress: '172.16.5.9',
        hints: ['192.168.1.7', '10.9.0.4'],
      );
      expect(basesOf(subnets), ['192.168.0.', '172.16.5.']);

      expect(
        basesOf(
          DevServerDiscovery.emulatorSubnets(
            deviceAddress: '172.16.5.9',
            hints: ['192.168.1.7', '10.9.0.4'],
          ),
        ),
        ['172.16.5.', '192.168.1.'],
      );
    });

    test('takes hints in order, one subnet each', () {
      final subnets = DevServerDiscovery.emulatorSubnets(
        hints: ['192.168.1.7', '192.168.1.9', '10.9.0.4', '192.168.2.1'],
      );
      expect(basesOf(subnets), ['192.168.1.', '10.9.0.']);
      expect(subnets.first.centre, 7);
    });

    test('ignores the emulator NAT, loopback, hostnames and public '
        'addresses', () {
      final subnets = DevServerDiscovery.emulatorSubnets(
        advertised: [
          '10.0.2.2',
          '127.0.0.1',
          'dev-laptop.local',
          '8.8.8.8',
          '100.64.0.9',
          '192.168.1',
        ],
        deviceAddress: '10.0.2.16',
        hints: ['10.0.2.15', '::1', 'box.tailnet.example', '192.168.0.101'],
      );
      expect(basesOf(subnets), ['192.168.0.']);
      expect(subnets.single.centre, 101);
    });

    test('centres on the host, then the device, before any hint', () {
      final subnets = DevServerDiscovery.emulatorSubnets(
        advertised: ['192.168.0.100', '192.168.0.105'],
        deviceAddress: '192.168.0.57',
        hints: ['192.168.0.101', '192.168.0.100'],
      );
      expect(basesOf(subnets), ['192.168.0.']);
      expect(subnets.single.centre, 100);
      expect(
        DevServerDiscovery.emulatorSubnets(
          deviceAddress: '192.168.0.57',
          hints: ['192.168.0.101'],
        ).single.centre,
        57,
      );
    });

    test('centres a subnet only hints name on its first hint', () {
      final subnets = DevServerDiscovery.emulatorSubnets(
        advertised: ['192.168.0.100'],
        hints: ['192.168.1.42', '192.168.1.7', '192.168.0.9'],
      );
      expect(basesOf(subnets), ['192.168.0.', '192.168.1.']);
      expect(subnets.first.centre, 100);
      expect(subnets.last.centre, 42);
    });

    test('reads an address however it is written', () {
      final subnets = DevServerDiscovery.emulatorSubnets(
        advertised: ['192.168.000.100'],
        hints: ['192.168.0.100'],
      );
      expect(basesOf(subnets), ['192.168.0.']);
      expect(subnets.single.centre, 100);
    });

    test('takes what counts as a LAN, but never the emulator NAT', () {
      final subnets = DevServerDiscovery.emulatorSubnets(
        advertised: ['10.0.2.2'],
        deviceAddress: '127.0.0.254',
        isLan: (ip) => true,
      );
      expect(basesOf(subnets), ['127.0.0.']);
      expect(subnets.single.centre, 254);
    });

    test('finds nothing to sweep with nothing to go on', () {
      expect(DevServerDiscovery.emulatorSubnets(), isEmpty);
      expect(
        DevServerDiscovery.emulatorSubnets(deviceAddress: '10.0.2.16'),
        isEmpty,
      );
    });
  });

  test('every default router address is one an emulator sweep accepts', () {
    const routers = DiscoveryConfig.defaultRouterAddresses;
    expect(routers.toSet(), hasLength(routers.length));
    for (final router in routers) {
      expect(
        DevServerDiscovery.emulatorSubnets(hints: [router]),
        hasLength(1),
        reason: router,
      );
    }
  });

  group('classifyConnectError', () {
    const timeout = Duration(milliseconds: 1500);
    PortState classify(int? code, String os, {required int ms}) =>
        DevServerDiscovery.classifyConnectError(
          code,
          elapsed: Duration(milliseconds: ms),
          timeout: timeout,
          operatingSystem: os,
        );

    test('trusts a refusal, an unreachable network or a host reported down '
        'whatever it took', () {
      for (final (os, refused, netUnreachable, hostDown) in [
        ('android', 111, 101, 112),
        ('linux', 111, 101, 112),
        ('macos', 61, 51, 64),
        ('ios', 61, 51, 64),
        ('windows', 10061, 10051, 10064),
        ('windows', 1225, 1231, 1256),
      ]) {
        final reason = '$os $refused';
        expect(
          classify(refused, os, ms: 1400),
          PortState.refused,
          reason: reason,
        );
        expect(
          classify(netUnreachable, os, ms: 5),
          PortState.dead,
          reason: reason,
        );
        expect(classify(hostDown, os, ms: 5), PortState.dead, reason: reason);
      }
    });

    test('reads an unreachable host by how long it took', () {
      for (final (os, hostUnreachable) in [
        ('android', 113),
        ('macos', 65),
        ('windows', 10065),
        ('windows', 1232),
      ]) {
        final reason = '$os $hostUnreachable';
        expect(
          classify(hostUnreachable, os, ms: 5),
          PortState.refused,
          reason: reason,
        );
        expect(
          classify(hostUnreachable, os, ms: 1300),
          PortState.dead,
          reason: reason,
        );
      }
    });

    test('reads any other failure by how long it took', () {
      expect(classify(null, 'android', ms: 100), PortState.refused);
      expect(classify(null, 'android', ms: 1300), PortState.dead);
      expect(classify(110, 'macos', ms: 1500), PortState.dead);
      expect(classify(111, 'macos', ms: 1400), PortState.dead);
      expect(classify(61, 'linux', ms: 100), PortState.refused);
    });
  });

  group('DevServer.parse', () {
    test('keeps a hostname, scheme and explicit port', () {
      final server = DevServer.parse('https://box.tailnet.example:8443')!;
      expect(server.host, 'box.tailnet.example');
      expect(server.port, 8443);
      expect(server.scheme, 'https');
      expect(server.reachable, isFalse);
    });

    test('reads the dev port for bare http and 443 for bare https', () {
      const config = DiscoveryConfig(ports: [5001]);
      expect(DevServer.parse('http://10.0.0.4', config: config)!.port, 5001);
      expect(DevServer.parse('https://example.test')!.port, 443);
    });

    // Uri drops a port equal to the scheme default, so http://x:80 used to
    // come back as the dev port.
    test('honours an explicit default port', () {
      const config = DiscoveryConfig(ports: [5001]);
      expect(DevServer.parse('http://10.0.0.4:80', config: config)!.port, 80);
      expect(DevServer.parse('https://example.test:443')!.port, 443);
    });

    test('treats an unknown scheme as http and rejects non-addresses', () {
      expect(DevServer.parse('ftp://box.test')!.scheme, 'http');
      expect(DevServer.parse('nonsense'), isNull);
      expect(DevServer.parse(''), isNull);
    });

    test('normalises two spellings of one server to the same origin', () {
      expect(
        DevServer.normalize(' https://box.test/ '),
        DevServer.normalize('https://box.test:443'),
      );
    });
  });

  group('DevServer.fromUrl', () {
    test('reads a missing port the way an HTTP client does', () {
      expect(DevServer.fromUrl('http://10.0.0.4/api/v1/')!.port, 80);
      expect(DevServer.fromUrl('https://example.test')!.port, 443);
      expect(DevServer.fromUrl('http://10.0.0.4:5001')!.port, 5001);
      expect(DevServer.fromUrl('nonsense'), isNull);
    });
  });

  group('an IPv6 literal', () {
    test('keeps its host bare and is bracketed in origin and endpoint', () {
      final server = DevServer.parse('http://[fd7a:115c:a1e0::5]:8080')!;
      expect(server.host, 'fd7a:115c:a1e0::5');
      expect(server.port, 8080);
      expect(server.origin, 'http://[fd7a:115c:a1e0::5]:8080');
      expect(server.endpoint, '[fd7a:115c:a1e0::5]:8080');

      const built = DevServer(host: '::1', port: 5001, latencyMs: 3);
      expect(built.origin, 'http://[::1]:5001');
      expect(built.endpoint, '[::1]:5001');
    });

    test('gets the same default ports as any other host', () {
      const config = DiscoveryConfig(ports: [5001]);
      expect(
        DevServer.parse('http://[::1]', config: config)!.origin,
        'http://[::1]:5001',
      );
      expect(DevServer.parse('https://[::1]/')!.origin, 'https://[::1]:443');
      expect(
        DevServer.fromUrl('http://[::1]/api/v1/')!.origin,
        'http://[::1]:80',
      );
    });

    test('normalises to a form that reads back as the same server', () {
      final normal = DevServer.normalize(' http://[::1]:5001/ ');
      expect(normal, 'http://[::1]:5001');
      expect(DevServer.normalize(normal!), normal);
      expect(DevServer.fromUrl(normal)!.host, '::1');
    });

    test('is kept in one form however it is written', () {
      for (final written in [
        'http://[0:0:0:0:0:0:0:1]:5001',
        'http://[0::1]:5001',
        'http://[::0:1]:5001',
      ]) {
        expect(DevServer.normalize(written), 'http://[::1]:5001');
      }
      expect(
        DevServer.parse('http://[FD7A:115C:A1E0:0:0:0:0:5]:8080')!.host,
        'fd7a:115c:a1e0::5',
      );
      expect(
        DevServer.fromUrl('http://[2001:db8:0:0:1:0:0:1]/')!.host,
        '2001:db8::1:0:0:1',
      );
      expect(
        DevServer.parse('http://[fe80:0::1%25en0]:5001')!.host,
        'fe80::1%25en0',
      );
    });

    test('given already in brackets is not bracketed twice', () {
      const server = DevServer(host: '[::1]', port: 5001, latencyMs: 3);
      expect(server.origin, 'http://[::1]:5001');
    });

    test('leaves IPv4 addresses and hostnames written as before', () {
      expect(
        DevServer.normalize('https://box.example.com'),
        'https://box.example.com:443',
      );
      expect(DevServer.normalize('http://10.0.0.4:80/'), 'http://10.0.0.4:80');
      expect(
        DevServer.parse('http://10.0.0.4:5001')!.endpoint,
        '10.0.0.4:5001',
      );
      expect(
        const DevServer(host: 'box.local', port: 8080, latencyMs: 1).origin,
        'http://box.local:8080',
      );
    });
  });

  group('verifyOrigin', () {
    test('checks the port the URL will actually be sent to', () async {
      final discovery = RecordingDiscovery();
      await discovery.verifyOrigin('http://10.0.0.4/api/v1/');
      await discovery.verifyOrigin('https://example.test/');
      await discovery.verifyOrigin('http://10.0.0.4:5001');
      expect(discovery.checked, [
        'http://10.0.0.4:80',
        'https://example.test:443',
        'http://10.0.0.4:5001',
      ]);
    });
  });

  group('DiscoveryConfig', () {
    test('rejects settings that could never find anything', () {
      DiscoveryConfig withConcurrency(int n) => DiscoveryConfig(concurrency: n);
      expect(() => withConcurrency(0), throwsAssertionError);
      expect(
        () => DevServerDiscovery(config: const DiscoveryConfig(ports: [])),
        throwsAssertionError,
      );
      expect(
        () => DevSetupController(
          defaultBaseUrl: 'https://example.test/',
          onBaseUrlChanged: (_) {},
          config: const DiscoveryConfig(ports: []),
        ),
        throwsAssertionError,
      );
    });
  });

  group('explicitPortOf', () {
    test('finds a written port and ignores an absent one', () {
      expect(explicitPortOf('http://h:80/x'), 80);
      expect(explicitPortOf('http://h/x'), isNull);
      expect(explicitPortOf('http://[::1]:8080'), 8080);
      expect(explicitPortOf('http://[::1]'), isNull);
    });

    test('does not mistake a password for the port', () {
      expect(explicitPortOf('http://admin:1234@10.0.0.5/'), isNull);
      expect(explicitPortOf('http://admin:1234@10.0.0.5:8080/'), 8080);
      expect(DevServer.fromUrl('http://admin:1234@10.0.0.5/')!.port, 80);
    });
  });

  group('DevServerEntry', () {
    DevServerEntry entry({String? hostname, String? label}) => DevServerEntry(
      server: DevServer(
        host: '192.168.0.107',
        port: 5001,
        latencyMs: 10,
        hostname: hostname,
      ),
      label: label,
    );

    test('prefers a label, then a resolved hostname, then the address', () {
      expect(
        entry(label: 'Mine', hostname: 'dev-laptop.local').displayName,
        'Mine',
      );
      expect(entry(hostname: 'dev-laptop.local').displayName, 'dev-laptop');
      expect(entry().displayName, '192.168.0.107');
      expect(entry().isNamed, isFalse);
    });

    test('is named by a resolved hostname as well as by a label', () {
      expect(entry(hostname: 'dev-laptop.local').isNamed, isTrue);
      expect(entry(label: 'Mine').isNamed, isTrue);
    });
  });

  group('prettyHostname', () {
    test('strips the trailing dot and local suffixes', () {
      expect(prettyHostname('dev-laptop.local.'), 'dev-laptop');
      expect(prettyHostname('dev-laptop.lan'), 'dev-laptop');
      expect(prettyHostname('build-box'), 'build-box');
      expect(prettyHostname('.local'), '.local');
    });
  });

  group('subnet helpers', () {
    test('split an address into base and last octet', () {
      expect(DevServerDiscovery.subnetBaseOf('192.168.1.120'), '192.168.1.');
      expect(DevServerDiscovery.lastOctetOf('192.168.1.120'), 120);
      expect(DevServerDiscovery.subnetBaseOf('garbage'), isNull);
    });

    test('recognise hosts that count as local', () {
      expect(DevServerDiscovery.isLocalHost('10.0.2.2'), isTrue);
      expect(DevServerDiscovery.isLocalHost('localhost'), isTrue);
      expect(DevServerDiscovery.isLocalHost('api.example.com'), isFalse);
      expect(DevServerDiscovery.isLocalHost(null), isFalse);
    });
  });
}
