/// Mock location for the app's own location code: what [MockLocation]
/// reports, and nothing of the screens. Import this from code that reads the
/// device's position, including a background isolate.
library;

export 'src/geo.dart';
export 'src/mock_location.dart';
export 'src/mock_location_store.dart';
