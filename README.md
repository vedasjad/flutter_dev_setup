# flutter_dev_setup

A developer setup screen for Flutter apps. It finds dev servers on the local network, lets a developer switch the API base URL at runtime, and keeps that choice across launches.

## The problem

An emulator reaches the dev server on your laptop through a fixed alias: `10.0.2.2` on Android, `127.0.0.1` on the iOS simulator. A physical phone has no such alias. The server runs on the laptop, so the phone's own IP is never the right address. The laptop's address also changes with every network and DHCP lease, so a hard-coded IP means a rebuild every time it moves.

This package scans the phone's network for servers that pass your health check and lists them. A developer can switch between them, the default URL, or an address they typed, without rebuilding. The choice is saved, and the app restores it on the next launch.

## Install

The package isn't on pub.dev yet, so depend on it from Git:

```yaml
dependencies:
  flutter_dev_setup:
    git:
      url: https://github.com/vedasjad/flutter_dev_setup.git
      ref: v0.1.0
```

It needs Dart 3.8 and Flutter 3.32 or later. You'll also need the [platform setup](#platform-setup) below.

## Quick start

These snippets come from the [example app](example/lib/main.dart). In the example, a `ValueNotifier` stands in for your HTTP client's configuration. With dio, for instance, you would set `dio.options.baseUrl` instead.

### 1. Restore the saved URL before the first request

```dart
const defaultBaseUrl = 'https://example.com/api/v1/';

final apiBaseUrl = ValueNotifier<String>(defaultBaseUrl);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    final saved = await DevSetup.savedBaseUrl();
    if (saved != null && await DevSetup.isReachable(saved)) {
      apiBaseUrl.value = saved;
    }
  }
  runApp(const ExampleApp());
}
```

Do this in `main()`, for two reasons. First, an app's services usually start making requests as it boots (a token refresh, remote config, analytics), before the setup screen is built. Second, the screen loads the saved URL into its fields but doesn't call `onBaseUrlChanged` until a choice is committed. `savedBaseUrl()` returns the full URL, suffix included, or null if nothing was ever committed.

The `isReachable` check is optional. It runs the same health check as the screen, with a 1.5-second timeout by default. If the saved address has gone stale (the laptop changed networks, or the server isn't running), the app falls back to the default instead of failing every request it makes at launch. Leave the check out if you'd rather those requests fail loudly.

### 2. Show the screen

```dart
class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_dev_setup example',
      home: kDebugMode
          ? DevSetupScreen(
              defaultBaseUrl: defaultBaseUrl,
              onBaseUrlChanged: (url) => apiBaseUrl.value = url,
              onProceed: (context) => Navigator.of(context).pushReplacement(
                MaterialPageRoute<void>(builder: (_) => const HomePage()),
              ),
            )
          : const HomePage(),
    );
  }
}
```

- `defaultBaseUrl` is the full URL that the Default and Reset buttons return to. `defaultSuffix` (default `/api/v1/`) is the API path at its end, which the screen shows in its own field. The two must agree: if your API lives at the root, pass `defaultSuffix: '/'`. Otherwise Default and Reset commit `https://host/api/v1/`.
- `onBaseUrlChanged` receives the full URL each time a choice is committed, never while the developer is typing.
- `onProceed` runs after the Proceed button commits the current URL, so navigate onward from there. Proceed only becomes enabled once the current URL passes the health check.
- `enableDiscovery: false` turns scanning off. Saved addresses still work.

Show the screen only in builds meant for developers. The example uses `kDebugMode`, for both the screen and the restore.

## Your dev server

- Listen on all interfaces (`0.0.0.0`), not `localhost`. The phone is a different machine.
- Every server you use, the default one included, must answer `healthPath` with a response that `isHealthy` accepts (any 2xx by default). Otherwise Proceed stays disabled. The default `healthPath` is `/`, which many APIs answer with a 404, so point it at a real health endpoint.
- The check goes to the port your HTTP client will use. A URL without a port, in `defaultBaseUrl` or typed into the URL field, is checked on 80 for `http://` and 443 for `https://`.
- Optionally, send an `x-dev-host` response header with the machine's name. The server list then shows that name instead of an IP.

## Configuration

`DiscoveryConfig` decides what counts as a server and how hard to look for one:

```dart
bool isOurApi(int status, String body) =>
    status == 200 && body.contains('"status":"ok"');

const discovery = DiscoveryConfig(
  ports: [8080, 3000],
  healthPath: '/health',
  isHealthy: isOurApi,
);
```

Pass it to the screen as `discovery:`. Also pass the same object to `DevSetup.isReachable(url, config: discovery)` and to any `DevSetupStore` you create, because neither picks it up from the screen.

| Field | Default | Meaning |
| --- | --- | --- |
| `ports` | `[8080, 3000, 5000, 8000]` | The first port is swept across the subnet. The rest are tried only on hosts already known to be up. An `http://` address saved with + and no port gets the first. |
| `healthPath` | `/` | Requested at the server's root, whatever path the base URL has. A missing leading `/` is added. |
| `isHealthy` | any 2xx | Decides from the status code and body whether the server is yours. It sees at most the first megabyte of the body. |
| `hostHeader` | `x-dev-host` | Response header a server can use to name itself. |
| `leaseBandStart`, `leaseBandEnd` | 100, 120 | Probed before the rest of the subnet, since most routers hand out addresses from .100 up. |
| `connectTimeout` | 600 ms | Time allowed for each TCP connection attempt. |
| `verifyTimeout` | 4 s | Time allowed for the health response, once a host has accepted the connection. |
| `reverseLookupTimeout` | 400 ms | Time allowed for a reverse DNS lookup on servers that don't name themselves. |
| `concurrency` | 48 | Number of probes in flight at once. |

The two timeouts differ on purpose:

- A sweep pays the connect timeout once for every dead address on the subnet, which is most of them, so it stays short.
- Only the few hosts that accepted a connection pay the verify timeout. It can therefore be long enough to wait for a laptop whose Wi-Fi is waking from power saving.

Concurrency is capped because probing a host the phone hasn't contacted before needs an ARP lookup, and the kernel's queue of unresolved lookups is small. A larger burst drops packets, and live hosts get reported as dead.

## Theming

Most of the screen's colours come from a `DevSetupTheme`, which defaults to a light palette, rather than from your app's `ThemeData`. A few details Flutter draws itself still follow `ThemeData`, such as text selection handles and highlights, the snack bar shown after copying the URL, and the Invalid URL alert. Pass your own colours, for example a dark variant:

```dart
const darkSetupTheme = DevSetupTheme(
  primary: Color(0xFF818CF8),
  onPrimary: Color(0xFF0B0D12),
  background: Color(0xFF0B0D12),
  surface: Color(0xFF151821),
  surfaceMuted: Color(0xFF1B1F2A),
  border: Color(0xFF262B37),
  fieldBorder: Color(0xFF2E3442),
  track: Color(0xFF1B1F2A),
  textPrimary: Color(0xFFE6E8EE),
  textSecondary: Color(0xFFA3A9B7),
  textTertiary: Color(0xFF6B7280),
  fieldTextStyle: TextStyle(
    fontFamily: 'Inter',
    fontSize: 14,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.2,
    color: Color(0xFFE6E8EE),
  ),
);
```

`fieldTextStyle` styles the URL field, the scheme picker next to it, the suffix field and the text fields in the dialogs. The screen merges it over your theme's `textTheme.bodyLarge` and gives the same result to the URL field and the picker, so the two always match. A font set app-wide with `ThemeData(fontFamily: ...)` is used without naming it here. The default sets size, weight, letter spacing, height and colour (`textPrimary`). A `fieldTextStyle` you pass replaces that default, so anything you leave out, colour included, comes from `bodyLarge` rather than from `DevSetupTheme`.

Status colours (`success`, `warning`, `idle`, `error`) are used as given for dots, tints and borders. The text of the latency and saved chips and of the status headline is pulled from its status colour toward `textPrimary` until it reaches a 4.5:1 contrast ratio on what it sits on.

## Localisation

The screen's text comes from `DevSetupStrings`. Text that includes values (scan progress, servers found, nothing found, latency, the copied URL) is a function:

```dart
final spanishStrings = DevSetupStrings(
  title: 'Configuración de desarrollo',
  localIp: 'IP local',
  useDefault: 'Predeterminada',
  proceed: 'Continuar',
  reset: 'Restablecer',
  foundServers: (count, label) =>
      count == 1 ? '1 servidor en $label' : '$count servidores en $label',
);
```

Pass it to the screen as `strings:`. The `label` argument names the range that was searched, such as `192.168.1.0/24`. On an emulator it is the fixed English text `emulator host`.

## Storage

`DevSetupStore` keeps everything in `SharedPreferences`. Each key is `keyPrefix` followed by a fixed name: `BaseUrl`, `BaseUrlSuffix`, `CustomServers`, `ServerLabels`, `ServerPins`, `DiscoveredHost` or `DiscoveredOctet`. The prefix defaults to `devSetup`. Pass your own prefix to reuse the key names an existing setup already has. For example, `dev` gives `devBaseUrl`.

```dart
final devStore = DevSetupStore(keyPrefix: 'dev', config: discovery);
```

Pass it to the screen as `store:`. At startup, read it back with the same prefix: `DevSetup.savedBaseUrl(keyPrefix: 'dev')`. A key that already holds a value of another type reads as unset rather than failing.

## How discovery works

On an emulator or simulator (detected with `device_info_plus`), the scanner tries every configured port on the alias for the host machine: `10.0.2.2` on Android, `127.0.0.1` on iOS. If nothing answers, the alias is listed anyway, because it is the right address even before the server starts. A scan the developer starts selects it.

On a physical device, the scanner takes the phone's Wi-Fi or Ethernet IPv4 address, skipping interfaces it recognises by name as VPN, cellular, hotspot or peer-to-peer. If there is no Wi-Fi or Ethernet address, it falls back to any other interface with a private address. It then sweeps that /24 in three phases, finishing each before starting the next:

1. Known hosts: the server used last, the host in the URL field, and the last server's final octet on the current subnet.
2. The lease band, .100 to .120 by default.
3. The rest of the subnet, working outward from the phone's own address.

Each candidate goes through two stages:

1. A TCP connection to the first port separates dead hosts from live ones. A connection that is refused immediately still proves the host is up.
2. A host with that port open gets an HTTP `GET` of `healthPath`. It counts as a server only if `isHealthy` accepts the response; an open port alone never counts.

Hosts that are up but have no server on the first port are then tried on the remaining ports.

Each server is named in this order:

1. The `x-dev-host` header it sends. If the header is repeated or holds a comma-separated list, the first value wins.
2. A reverse DNS lookup of its IP.
3. Its IP.

Suffixes such as `.local` and `.lan` are removed from either name. A name the developer gives a server overrides all of these and is stored only on that device.

## Saved addresses: VPNs and tunnels

The scan only covers the /24 the phone is on. It can't find a laptop on a VPN or tunnel (for example, Tailscale running on both machines), on another subnet, or in the cloud. Add those with the + button. A hostname works as well as an IP.

- Saved addresses are stored as `scheme://host:port`, so one address typed two ways is a single entry. A bare `http://` address gets the first configured port, a bare `https://` one gets 443, and an explicit port, `:80` included, is kept. Saving a host and port again under the other scheme switches the saved entry in place.
- They stay in the list until the developer removes them with Forget in the server's name dialog.
- They are re-checked on every scan, and a check that finishes after the sweep still updates the list. Until a saved address answers, it is marked "saved".

Each /24 in a private range (10/8, 172.16/12 or 192.168/16) can have one pinned server, so home and office keep separate pins. Every other address, such as a hostname or a Tailscale IP, shares a single pin that applies on every network.

## Platform setup

### Android

The package's probes use `dart:io` sockets, which Android's cleartext policy doesn't cover. Your app's HTTP stack may be covered, though. Anything built on the platform's networking (OkHttp-based clients, web views, media players) refuses `http://` in apps that target Android 9 (API 28) or later, unless cleartext traffic is allowed. Allow it for debug builds only, in `android/app/src/debug/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET"/>
    <application android:usesCleartextTraffic="true" />
</manifest>
```

### iOS

On a physical device with iOS 14 or later, the first connection to the local network triggers the Local Network permission prompt. iOS may refuse that first attempt before the developer answers, so if the first scan finds nothing, scan again once access is granted. `NSLocalNetworkUsageDescription` supplies the prompt's text.

App Transport Security (ATS) doesn't cover `dart:io` either. It does cover HTTP clients built on `URLSession`, and web views. From iOS 17, ATS no longer lets them connect to IP addresses by default. Setting `NSAllowsLocalNetworking` lets them reach IP addresses, `.local` names and unqualified hostnames.

Add both keys to `ios/Runner/Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Finds development servers on your local network.</string>
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

The simulator never asks for local network access.

### Network limits

Discovery is IPv4 only, and a saved address can't be an IPv6 literal. For an IPv6-only server, save a hostname instead. The scan covers exactly the phone's own /24 in a private range (10/8, 172.16/12 or 192.168/16), even when the network is larger. Some guest and office Wi-Fi networks isolate devices from each other, which blocks this traffic completely. If the laptop's firewall silently drops connection attempts instead of refusing them, the laptop looks dead and its other ports are never tried.

- For a server outside the /24, or behind a firewall like that, save its address.
- On a network that isolates devices, reach the server through a tunnel.

## Testing

The network code sits behind the `DevServerScanner` interface, and `DevSetupController` is a plain `ChangeNotifier`. That means the screen's logic can be unit-tested without sockets or widgets. Call `init(startBackgroundWork: false)` to skip the periodic health check and the automatic scan. The controller stores its state through `shared_preferences`, so add that package to `dev_dependencies` and mock it:

```dart
import 'package:flutter_dev_setup/flutter_dev_setup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeScanner implements DevServerScanner {
  @override
  Future<ScanSummary> scan({
    String? currentHost,
    String? rememberedHost,
    int? rememberedOctet,
    required void Function(DevServer server) onFound,
    void Function(String subnetBase)? onSubnet,
    void Function(int probed, int total, String label)? onProgress,
  }) async {
    onFound(const DevServer(host: '192.168.1.20', port: 8080, latencyMs: 12));
    return const ScanSummary(ScanOutcome.found, label: '192.168.1.0/24');
  }

  @override
  Future<DevServer?> verifyOrigin(String origin) async => null;

  @override
  void cancel() {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('only a scan the developer starts selects a server', () async {
    final committed = <String>[];
    final controller = DevSetupController(
      defaultBaseUrl: 'https://example.com/api/v1/',
      onBaseUrlChanged: committed.add,
      scannerFactory: FakeScanner.new,
    );
    addTearDown(controller.dispose);
    await controller.init(startBackgroundWork: false);

    await controller.scan(manual: false);
    expect(committed, isEmpty);

    await controller.scan();
    expect(committed, ['http://192.168.1.20:8080/api/v1/']);
  });
}
```

For a widget test, pass the same controller to `DevSetupScreen(controller: ...)`. The screen then leaves calling `init()` and `dispose()` to you. `defaultBaseUrl`, `onBaseUrlChanged` and `onProceed` are still required. With a controller, only `onProceed`, `theme` and `strings` are used; the controller's own settings replace `defaultBaseUrl`, `defaultSuffix`, `onBaseUrlChanged`, `discovery`, `store` and `enableDiscovery`. To test with real sockets, `DevServerDiscovery` accepts `isEmulator` and `lanAddress` overrides, so a sweep can run against the loopback address.

## Behaviour guarantees

- The scan that runs when the screen opens only lists servers. It never changes the committed URL.
- A scan the developer starts (with Local IP, the refresh button or Scan again) selects the pinned server if it found it, or the only server if it found exactly one. If it found several, the developer chooses. If the developer picks a server or edits the URL while it runs, it selects nothing.
- Typing in the URL or suffix field never commits anything. A URL is committed when the developer taps a server, Default, Reset or Proceed, or adds an address, or when a scan they started selects a server.
- Selecting, pinning and renaming never reorder the list. Saved addresses come first, in the order they were added, and keep their place as they come online. Discovered servers are ranked as they arrive (pinned first, then last used, then named, then fastest) and don't move again until the next scan.
- An address that is both saved and discovered appears once. Rows are matched by host and port, so a server saved under a hostname and found on the LAN by its IP is listed twice.
- The screen's health check uses the discovery probe, not your HTTP client, so an interceptor can't make the check disagree with the server list. It pauses while another route covers the screen or the app is in the background.

## License

MIT. See [LICENSE](LICENSE).
