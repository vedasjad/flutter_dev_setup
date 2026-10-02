/// Every piece of text the screen shows, overridable for localisation.
class DevSetupStrings {
  const DevSetupStrings({
    this.title = 'Developer Setup',
    this.baseUrl = 'Base URL',
    this.apiSuffix = 'API suffix',
    this.baseUrlHint = 'api.example.com',
    this.suffixHint = '/api/v1/',
    this.localIp = 'Local IP',
    this.useDefault = 'Default',
    this.cancel = 'Cancel',
    this.proceed = 'Proceed',
    this.reset = 'Reset',
    this.ok = 'OK',
    this.save = 'Save',
    this.forget = 'Forget',
    this.headlineIdle = 'Not checked yet',
    this.headlineChecking = 'Checking connection',
    this.headlineOnline = 'Connected',
    this.headlineOffline = 'No response',
    this.captionIdle = 'Enter a base URL to begin',
    this.captionChecking = 'Checking the health endpoint',
    this.captionOnline = 'This server answered the health check',
    this.captionOffline = 'Nothing answered at this address',
    this.copied = _copied,
    this.copyUrl = 'Copy URL',
    this.serversTitle = 'Servers on this network',
    this.scanAgain = 'Scan again',
    this.addAddress = 'Add an address',
    this.lookingForServer = 'Looking for the dev server…',
    this.scanning = _scanning,
    this.foundServers = _foundServers,
    this.nothingFound = _nothingFound,
    this.noNetwork = 'Not connected to a local network.',
    this.scanCancelled = 'Scan cancelled',
    this.scanFailed = 'Scan failed',
    this.emptyTitle = 'No dev server answered',
    this.emptyBody = 'Check the server is running, or type the address above.',
    this.scanHint =
        'Tap Local IP to scan this network for a running dev server.',
    this.saved = 'saved',
    this.latency = _latency,
    this.pin = 'Keep at the top',
    this.unpin = 'Unpin',
    this.nameServer = 'Name this server',
    this.nameHint = 'e.g. my laptop',
    this.nameHelp =
        'Shown instead of the address, on this device only. '
        'Leave it empty to clear the name.',
    this.addServerTitle = 'Add a server',
    this.addServerBody =
        'For a server the scan cannot reach — a VPN or tunnel address.',
    this.addServerHint = 'http://my-machine:8080',
    this.addServerHelp = 'Kept in the list until you forget it.',
    this.addServerInvalid = 'Needs a scheme and a host, e.g. http://host:8080',
    this.invalidUrlTitle = 'Invalid URL',
    this.invalidUrlBody = 'Enter a valid URL before proceeding.',
  });

  final String title;
  final String baseUrl;
  final String apiSuffix;
  final String baseUrlHint;
  final String suffixHint;
  final String localIp;
  final String useDefault;
  final String cancel;
  final String proceed;
  final String reset;
  final String ok;
  final String save;
  final String forget;
  final String headlineIdle;
  final String headlineChecking;
  final String headlineOnline;
  final String headlineOffline;
  final String captionIdle;
  final String captionChecking;
  final String captionOnline;
  final String captionOffline;
  final String Function(String url) copied;
  final String copyUrl;
  final String serversTitle;
  final String scanAgain;
  final String addAddress;
  final String lookingForServer;
  final String Function(String label, int probed, int total) scanning;
  final String Function(int count, String label) foundServers;
  final String Function(String label) nothingFound;
  final String noNetwork;
  final String scanCancelled;
  final String scanFailed;
  final String emptyTitle;
  final String emptyBody;
  final String scanHint;
  final String saved;
  final String Function(int ms) latency;
  final String pin;
  final String unpin;
  final String nameServer;
  final String nameHint;
  final String nameHelp;
  final String addServerTitle;
  final String addServerBody;
  final String addServerHint;
  final String addServerHelp;
  final String addServerInvalid;
  final String invalidUrlTitle;
  final String invalidUrlBody;

  static String _copied(String url) => 'Copied $url';
  static String _scanning(String label, int probed, int total) =>
      'Scanning $label — $probed/$total';
  static String _foundServers(int count, String label) => count == 1
      ? 'Found 1 server on $label'
      : 'Found $count servers on $label';
  static String _nothingFound(String label) =>
      'No dev server found on $label. Enter the URL manually.';
  static String _latency(int ms) => '$ms ms';
}
