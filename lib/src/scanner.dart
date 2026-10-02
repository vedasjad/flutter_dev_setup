import 'models.dart';

/// The network side of the screen, behind an interface so it can be faked.
abstract class DevServerScanner {
  Future<ScanSummary> scan({
    String? currentHost,
    String? rememberedHost,
    int? rememberedOctet,
    required void Function(DevServer server) onFound,
    void Function(String subnetBase)? onSubnet,
    void Function(int probed, int total, String label)? onProgress,
  });

  /// Checks one typed address. Accepts hostnames as well as IPs. With no port
  /// written, checks the port an HTTP client would use: 80 or 443.
  Future<DevServer?> verifyOrigin(String origin);

  void cancel();
}
