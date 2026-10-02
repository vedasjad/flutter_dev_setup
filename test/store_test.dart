import 'package:flutter_dev_setup/flutter_dev_setup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}
