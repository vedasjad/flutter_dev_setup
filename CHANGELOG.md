# Changelog

## 0.2.0

### Breaking changes

- `DevServerScanner.scan` takes two more named parameters. `knownHosts` lists hints for where to look, best first: the remembered LAN server (`LanHost`), then the pinned, saved and named hosts. `onPreferred` is called at most once per scan, with the server a scan the developer started should select when nothing is pinned. A custom scanner must add both to its `scan` override, and may ignore them.

### Features

- An emulator or simulator no longer stops at the alias for the host machine. After checking it, the scanner sweeps up to two /24s of the LAN the host is on. It takes them from the host's own addresses, which its server can list in an `x-dev-lan` header, and then from the device's own LAN address unless it is in the Android emulator's NAT. When neither names a LAN, it uses the routers in `routerAddresses` that accept or refuse a connection on port 80 or 53, in the order listed, probed while the alias is checked. Last come the addresses the developer has used. Each sweep works like a phone's, centred on the first of those addresses in the subnet, and lists the host by its LAN address as well as by the alias.
- A LAN server the developer used or a scan found is remembered as `LanHost`, apart from the last server used, and is among the first addresses a scan takes. An emulator keeps sweeping that network after the developer selects its alias, unless networks that rank higher already fill both /24s.
- The scan's label reads `emulator host` while the alias is checked and names the subnet during each sweep. Its final label names both, as in `emulator host and 192.168.0.0/24`.
- A scan the developer starts on an emulator selects the alias the moment it answers, if nothing is pinned or the alias is itself the pinned server. Otherwise it waits for the end of the scan and selects the pinned server if it found it, or else the alias. The scan that runs when the screen opens still only lists.

### Configuration

- `DiscoveryConfig.lanAddressHeader` (default `x-dev-lan`) names the response header a server can use to list its own LAN IPv4 addresses, separated by commas or on repeated lines. `null` turns it off.
- `DiscoveryConfig.emulatorConnectTimeout` (default 1.5 s) is the sweep's TCP probe on an emulator, where every connection crosses the emulator's NAT and takes up to about a second.
- `DiscoveryConfig.routerAddresses` (default `DiscoveryConfig.defaultRouterAddresses`, common home, office and hotspot routers) is where an emulator looks for the host's router when nothing else names its LAN.
- `DevSetupStore` keeps a `LanHost` key, read and written with `lanHost()` and `setLanHost()`.

### Probing

- A failed TCP probe is read by its OS error code first. A refused connection counts as a live host, and an unreachable network or a host reported down as a dead one, however long either took. Any other failure falls back to the timing rule, an unreachable host included: Linux reports a firewall's administratively prohibited reject that way, from a host that may serve another port. `tcpProbe` takes an optional `timeout`, `connectTimeout` by default.

### API

- `DevServerDiscovery.emulatorSubnets` returns the subnets an emulator sweeps, each with the octet its walk starts from, and `DevServerDiscovery.classifyConnectError` reads a failed connection. `candidatePhases` takes `knownHosts`, `exclude` for hosts never to propose, and `isLan` for which known hosts count.
- `DevServerDiscovery` takes `emulatorHost`, `isLanAddress` and `routerProbe` overrides, and has a static `routerAnswers` with a `connect` override, all marked `@visibleForTesting`, so tests can run the emulator path against loopback without probing real routers.

### Screen

- The status card is more compact, and tapping anywhere on it copies the URL.

## 0.1.0

Initial release.

### Features

- `DevSetupScreen` chooses the API base URL from the default, a server found on the local network, or a saved address. The choice is applied at runtime through `onBaseUrlChanged` and kept across launches.
- `DevServerDiscovery` sweeps the device's /24: known hosts first, then the DHCP lease band, then the rest of the subnet working outward from the device. A host counts only if `isHealthy` accepts its health response, and the other ports are tried only on hosts already known to be up. On an emulator or simulator it checks the host machine's alias and lists it even before the server starts.
- Servers are named by an `x-dev-host` response header or a reverse DNS lookup. A name the developer gives a server is kept on that device.
- Saved addresses for VPNs, tunnels and other subnets, normalised to `scheme://host:port` and re-checked on every scan. An IPv6 literal is accepted in brackets, as in `http://[fd7a:115c::5]:8080`, saved in its shortest form, and kept in brackets wherever it is saved, restored, checked or shown. Pins are per subnet for private LAN addresses and global for everything else.
- `DevSetup.savedBaseUrl({keyPrefix})` and `DevSetup.isReachable(url, {config, timeout})` restore the saved URL in `main()`, before the first request.

### Configuration

- `DiscoveryConfig`: ports, health path, `isHealthy`, name header, lease band, connect, verify and reverse-lookup timeouts, and concurrency.
- `DevSetupStore(keyPrefix, config)` keeps everything in `SharedPreferences` under `<prefix>BaseUrl`, `BaseUrlSuffix`, `CustomServers`, `ServerLabels`, `ServerPins`, `DiscoveredHost` and `DiscoveredOctet`. A key, or a single label or pin, holding a value of another type reads as unset. A pin stored under another key, such as the phone's subnet rather than the server's, moves to its server's key when read, unless that key already holds a pin, and `setPins` writes only those keys. A pin whose value isn't a bare host is dropped.
- `DevSetupStrings` holds all of the screen's text. `enableDiscovery: false` turns scanning off and leaves saved addresses working.

### Behaviour guarantees

- The scan that runs when the screen opens only lists servers. A scan the developer starts selects the pinned server or the only one found, unless they picked a server or edited the URL while it ran.
- Typing never commits. A URL is committed by tapping a server, Default, Reset or Proceed, by adding an address, or by a developer-started scan selecting a server. Proceed is enabled only once the URL passes the health check.
- Selecting, pinning and renaming never reorder the list, and an address both saved and discovered is listed once.
- The health check uses the discovery probe on the port the HTTP client will use, so an interceptor can't make it disagree with the list. It pauses while another route covers the screen or the app is in the background.

### Theming and accessibility

- `DevSetupTheme` sets the screen's colours. `fieldTextStyle` is merged over the host theme's `textTheme.bodyLarge`, so the app's font is inherited and the URL field and scheme picker always match. Status text is pulled toward `textPrimary` until it reaches 4.5:1 contrast.
- Every control is at least 48dp to tap, and server rows report their selected state to screen readers.
- Dialogs stack their actions when they don't fit side by side, and scroll rather than overflow above a keyboard.

### API

- `DevSetupController` is a widget-free `ChangeNotifier`. Its state (scan phase and progress, health status, scheme, server list) is exposed through read-only getters and changes through its methods. Pass one to `DevSetupScreen(controller:)` to drive the screen yourself.
- `toggleScan()` is the Local IP control: it cancels a running scan or starts a manual one. `scan()` always starts a fresh scan, replacing any that is running; `scan(manual: false)` only lists.
- `pausePinging()` and `resumePinging()` suspend and resume the periodic health check. The screen calls them itself, and resuming checks at once.
- `ScanPhase.failed`: a scanner that throws ends the scan as failed, and the error goes to `FlutterError.reportError`.
- `DevServer.fromUrl` reads a URL as an HTTP client will, so no port means 80 or 443. `DevServer.parse` and `DevServer.normalize` read a typed address, where a bare `http://` host gets the first configured port.
- `DevServerScanner` is the network interface behind the controller, so tests can fake it without sockets.
