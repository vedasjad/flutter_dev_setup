import 'dart:convert';

import 'package:flutter_dev_setup/flutter_dev_setup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Map<String, Object?>> storedPins() async => jsonDecode(
  (await SharedPreferences.getInstance()).getString('devServerPins')!,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an app prefix reproduces existing key names exactly', () {
    final store = DevSetupStore(keyPrefix: 'dev');
    expect(
      [
        store.baseUrlKey,
        store.suffixKey,
        store.customKey,
        store.labelsKey,
        store.pinsKey,
        store.rememberedHostKey,
        store.rememberedOctetKey,
      ],
      [
        'devBaseUrl',
        'devBaseUrlSuffix',
        'devCustomServers',
        'devServerLabels',
        'devServerPins',
        'devDiscoveredHost',
        'devDiscoveredOctet',
      ],
    );
  });

  test('round-trips the committed URL for bootstrap', () async {
    await DevSetupStore(
      keyPrefix: 'dev',
    ).setBaseUrl('http://10.0.0.4:5001/api/v1/', suffix: '/api/v1/');
    expect(
      await DevSetup.savedBaseUrl(keyPrefix: 'dev'),
      'http://10.0.0.4:5001/api/v1/',
    );
    expect(await DevSetup.savedBaseUrl(), isNull);
  });

  test(
    'normalises and de-duplicates saved addresses written earlier',
    () async {
      SharedPreferences.setMockInitialValues({
        'devCustomServers': [
          'https://box.example.com',
          'https://box.example.com:443/',
          'http://10.0.0.4:5001',
          'not an address',
        ],
      });
      final store = DevSetupStore(
        keyPrefix: 'dev',
        config: const DiscoveryConfig(ports: [5001]),
      );
      expect(await store.customOrigins(), [
        'https://box.example.com:443',
        'http://10.0.0.4:5001',
      ]);
    },
  );

  test('keeps one saved address per host and port', () async {
    SharedPreferences.setMockInitialValues({
      'devCustomServers': [
        'http://192.168.0.5:8443',
        'https://192.168.0.5:8443',
      ],
    });
    final store = DevSetupStore(keyPrefix: 'dev');
    expect(await store.customOrigins(), ['http://192.168.0.5:8443']);
  });

  test('reads a key that holds another type as unset', () async {
    SharedPreferences.setMockInitialValues({
      'devBaseUrl': 7,
      'devBaseUrlSuffix': true,
      'devCustomServers': '["http://10.0.0.4:5001"]',
      'devServerLabels': ['10.0.0.4'],
      'devServerPins': 3,
      'devDiscoveredHost': ['10.0.0.4'],
      'devDiscoveredOctet': '4',
    });
    final store = DevSetupStore(keyPrefix: 'dev');
    expect(await store.baseUrl(), isNull);
    expect(await store.suffix(), isNull);
    expect(await store.customOrigins(), isEmpty);
    expect(await store.labels(), isEmpty);
    expect(await store.pins(), isEmpty);
    expect(await store.rememberedHost(), isNull);
    expect(await store.rememberedOctet(), isNull);
    expect(await DevSetup.savedBaseUrl(keyPrefix: 'dev'), isNull);
  });

  test('round-trips labels and pins, and survives corrupt data', () async {
    final store = DevSetupStore(keyPrefix: 'dev');
    await store.setLabels({'10.0.0.4': 'mine'});
    await store.setPins({
      '10.0.0.': '10.0.0.4',
      DevSetupStore.globalPinKey: 'box',
    });
    expect(await store.labels(), {'10.0.0.4': 'mine'});
    expect((await store.pins())[DevSetupStore.globalPinKey], 'box');

    SharedPreferences.setMockInitialValues({'devServerLabels': '{not json'});
    expect(await DevSetupStore(keyPrefix: 'dev').labels(), isEmpty);
  });

  test('remembers the last host and its octet', () async {
    final store = DevSetupStore(keyPrefix: 'dev');
    await store.setRemembered('192.168.0.111');
    expect(await store.rememberedHost(), '192.168.0.111');
    expect(await store.rememberedOctet(), 111);
  });

  test('keeps a saved IPv6 literal in brackets', () async {
    SharedPreferences.setMockInitialValues({
      'devCustomServers': [
        'http://[fd7a:115c::5]',
        'http://[fd7a:115c::5]:5001/',
        'http://[FD7A:115C:0:0:0:0:0:5]:5001',
      ],
    });
    final store = DevSetupStore(
      keyPrefix: 'dev',
      config: const DiscoveryConfig(ports: [5001]),
    );
    expect(await store.customOrigins(), ['http://[fd7a:115c::5]:5001']);
  });

  test('skips a label whose value is not a string', () async {
    SharedPreferences.setMockInitialValues({
      'devServerLabels': '{"10.0.0.4":null,"10.0.0.5":7,"10.0.0.6":"mine"}',
    });
    expect(await DevSetupStore(keyPrefix: 'dev').labels(), {
      '10.0.0.6': 'mine',
    });
  });

  // An older screen keyed pins by the phone's subnet, not the server's.
  group("pins keyed by the phone's subnet", () {
    Future<Map<String, String>> pinsStoredAs(Map<String, Object?> stored) {
      SharedPreferences.setMockInitialValues({
        'devServerPins': jsonEncode(stored),
      });
      return DevSetupStore(keyPrefix: 'dev').pins();
    }

    test('a tunnel hostname moves to the global key', () async {
      expect(await pinsStoredAs({'192.168.1.': 'abc.ngrok.app'}), {
        DevSetupStore.globalPinKey: 'abc.ngrok.app',
      });
    });

    test('a Tailscale address moves to the global key', () async {
      expect(await pinsStoredAs({'192.168.1.': '100.101.102.103'}), {
        DevSetupStore.globalPinKey: '100.101.102.103',
      });
    });

    test('a LAN address moves to its own subnet', () async {
      expect(await pinsStoredAs({'192.168.1.': '10.0.0.5'}), {
        '10.0.0.': '10.0.0.5',
      });
    });

    test('a LAN address on the same subnet stays where it is', () async {
      expect(await pinsStoredAs({'192.168.1.': '192.168.1.40'}), {
        '192.168.1.': '192.168.1.40',
      });
    });

    test('never replace a pin already under the right key', () async {
      const right = {
        DevSetupStore.globalPinKey: 'box.tailnet.example',
        '10.0.0.': '10.0.0.9',
      };
      const moved = {'192.168.1.': 'abc.ngrok.app', '172.16.0.': '10.0.0.5'};
      expect(await pinsStoredAs({...moved, ...right}), right);
      expect(await pinsStoredAs({...right, ...moved}), right);
    });

    test('one that is not a host claims no key', () async {
      for (final junk in <Object?>[
        null,
        '',
        ' ',
        5,
        false,
        '192.168.1.40:5001',
        'http://abc.ngrok.app',
      ]) {
        expect(
          await pinsStoredAs({
            '192.168.1.': junk,
            '192.168.0.': 'abc.ngrok.app',
          }),
          {DevSetupStore.globalPinKey: 'abc.ngrok.app'},
          reason: jsonEncode(junk),
        );
      }
    });

    test('settle after one pass, read or written', () async {
      final once = await pinsStoredAs({
        '192.168.1.': 'abc.ngrok.app',
        '192.168.0.': 'xyz.ngrok.app',
        '172.16.0.': '10.0.0.5',
        '192.168.2.': '192.168.2.7',
      });
      expect(once, {
        DevSetupStore.globalPinKey: 'abc.ngrok.app',
        '10.0.0.': '10.0.0.5',
        '192.168.2.': '192.168.2.7',
      });

      final store = DevSetupStore(keyPrefix: 'dev');
      expect(await store.pins(), once);
      await store.setPins(once);
      expect(await storedPins(), once);
      expect(await store.pins(), once);
    });

    test('are written back under the right keys only', () async {
      final store = DevSetupStore(keyPrefix: 'dev');
      await store.setPins({
        '192.168.1.': 'abc.ngrok.app',
        '172.16.0.': '10.0.0.5',
      });
      expect(await storedPins(), {
        DevSetupStore.globalPinKey: 'abc.ngrok.app',
        '10.0.0.': '10.0.0.5',
      });

      await store.setPins({'192.168.1.': '100.101.102.103'});
      expect(await storedPins(), {
        DevSetupStore.globalPinKey: '100.101.102.103',
      });
    });
  });
}
