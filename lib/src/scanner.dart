import 'models.dart';

/// The network side of the screen, behind an interface so it can be faked.
abstract class DevServerScanner {
  /// [knownHosts] are hints for where to look, best first: the remembered LAN
  /// server, one the developer used or a scan found, then the hosts the
  /// developer has pinned, saved or named.
  ///
  /// [onPreferred] gets, at most once per scan, the server a scan the
  /// developer started should select when nothing is pinned: on an emulator
  /// the alias for the host machine, on a physical device none. It is called
  /// as soon as that server is found, after [onFound] has reported it.
  Future<ScanSummary> scan({
    String? currentHost,
    String? rememberedHost,
    int? rememberedOctet,
    Iterable<String> knownHosts = const [],
    required void Function(DevServer server) onFound,
    void Function(DevServer server)? onPreferred,
    void Function(String subnetBase)? onSubnet,
    void Function(int probed, int total, String label)? onProgress,
  });

  /// Checks one typed address. Accepts hostnames as well as IPs. With no port
  /// written, checks the port an HTTP client would use: 80 or 443.
  Future<DevServer?> verifyOrigin(String origin);

  void cancel();
}
