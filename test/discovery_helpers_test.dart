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
