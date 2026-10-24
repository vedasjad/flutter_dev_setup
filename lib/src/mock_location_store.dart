import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'mock_location.dart';

/// Where the mocked location and the saved places are kept.
///
/// It reads through [SharedPreferencesAsync], which has no cache, so a
/// background isolate sees a change the moment the setup screen makes it.
/// The keys are separate from [DevSetupStore]'s and live in that API's own
/// storage, so they never show up among an app's [SharedPreferences] keys.
class MockLocationStore {
  const MockLocationStore({this.keyPrefix = 'devSetup'});

  final String keyPrefix;

  String get stateKey => '${keyPrefix}MockLocation';
  String get placesKey => '${keyPrefix}MockPlaces';

  Future<MockLocationState> state() async =>
      MockLocationState.fromJson(await _readJson(stateKey));

  Future<void> setState(MockLocationState state) =>
      SharedPreferencesAsync().setString(stateKey, jsonEncode(state.toJson()));

  Future<List<MockPlace>> places() async {
    final stored = await _readJson(placesKey);
    if (stored is! List) return [];
    return [for (final place in stored) ?MockPlace.fromJson(place)];
  }

  Future<void> setPlaces(List<MockPlace> places) => SharedPreferencesAsync()
      .setString(placesKey, jsonEncode([for (final p in places) p.toJson()]));

  /// A value another version wrote with a different type, or that does not
  /// parse, reads as unset.
  Future<Object?> _readJson(String key) async {
    try {
      final raw = await SharedPreferencesAsync().getString(key);
      return raw == null ? null : jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
}

/// Entry points for the app's own location code.
///
/// The package cannot change what a location plugin reports, so the app asks
/// here first: [current] in place of a one-off position request, [overlay]
/// around a position stream.
abstract final class MockLocation {
  /// The mocked position now, or null when mocking is off — then use the
  /// real one. Never throws.
  static Future<MockPosition?> current({
    MockLocationStore store = const MockLocationStore(),
  }) async {
    try {
      return (await store.state()).positionAt(DateTime.now());
    } catch (_) {
      return null;
    }
  }

  /// [real] while mocking is off; the mocked position, every [interval],
  /// while it is on. It switches either way as the developer changes the
  /// setting, in this isolate or another.
  ///
  /// [real] stays subscribed throughout, and its events and errors are
  /// dropped while mocking is on. A position that has not changed since the
  /// last one sent — a fixed point, a paused route — is not sent again. The
  /// stream ends when [real] has ended and mocking is off.
  static Stream<T> overlay<T>(
    Stream<T> real,
    T Function(MockPosition position) convert, {
    MockLocationStore store = const MockLocationStore(),
    Duration interval = const Duration(seconds: 1),
  }) {
    late final StreamController<T> out;
    StreamSubscription<T>? source;
    Timer? timer;
    var mocking = false;
    var realDone = false;
    var reading = false;
    var cancelled = false;
    MockPosition? last;

    Future<void> tick() async {
      if (reading || cancelled || out.isClosed) return;
      reading = true;
      final position = await current(store: store);
      reading = false;
      if (cancelled || out.isClosed) return;
      mocking = position != null;
      if (position == null) {
        last = null;
        if (realDone) {
          timer?.cancel();
          await out.close();
        }
        return;
      }
      if (last?.sameFixAs(position) ?? false) return;
      last = position;
      out.add(convert(position));
    }

    void startTimer() {
      timer?.cancel();
      timer = Timer.periodic(interval, (_) => unawaited(tick()));
    }

    out = StreamController<T>(
      onListen: () async {
        await tick();
        if (cancelled || out.isClosed) return;
        source = real.listen(
          (event) {
            if (!mocking) out.add(event);
          },
          onError: (Object error, StackTrace stack) {
            if (!mocking) out.addError(error, stack);
          },
          onDone: () {
            realDone = true;
            if (!mocking) {
              timer?.cancel();
              unawaited(out.close());
            }
          },
        );
        startTimer();
      },
      onPause: () {
        timer?.cancel();
        source?.pause();
      },
      onResume: () {
        source?.resume();
        if (source != null) startTimer();
      },
      onCancel: () async {
        cancelled = true;
        timer?.cancel();
        await source?.cancel();
      },
    );
    return out.stream;
  }
}
