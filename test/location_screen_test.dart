import 'package:flutter/material.dart';
import 'package:flutter_dev_setup/flutter_dev_setup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fakes.dart';

const office = MockPlace('Office', MockPoint(25.4762689, 80.3395498));

const config = MockLocationConfig(
  places: [office],
  placeSearch: null,
  routeFinder: null,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpSetup(
    WidgetTester tester, {
    MockLocationConfig? mockLocation,
  }) async {
    tallView(tester);
    final controller = DevSetupController(
      defaultBaseUrl: 'https://example.com/api/v1/',
      onBaseUrlChanged: (_) {},
      scannerFactory: FakeScanner.new,
      enableDiscovery: false,
    );
    addTearDown(controller.dispose);
    await controller.init(startBackgroundWork: false);
    await tester.pumpWidget(
      MaterialApp(
        home: DevSetupScreen(
          controller: controller,
          defaultBaseUrl: 'https://example.com/api/v1/',
          onBaseUrlChanged: (_) {},
          onProceed: (_) {},
          mockLocation: mockLocation,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the setup screen shows the card only when configured', (
    tester,
  ) async {
    await pumpSetup(tester);
    expect(find.byType(MockLocationCard), findsNothing);

    await pumpSetup(tester, mockLocation: config);
    expect(find.byType(MockLocationCard), findsOneWidget);
    expect(find.text('Off: the app reads the GPS'), findsOneWidget);
  });

  testWidgets('typed coordinates become the point, and the card follows', (
    tester,
  ) async {
    await pumpSetup(tester, mockLocation: config);
    await tester.tap(find.byType(MockLocationCard));
    await tester.pumpAndSettle();
    expect(find.byType(MockLocationScreen), findsOneWidget);

    await tester.tap(find.text('Point'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '25.4775, 80.3349');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('Fixed point'), findsOneWidget);
    expect(find.text('25.477500, 80.334900'), findsOneWidget);
    expect(
      (await const MockLocationStore().state()).point,
      const MockPoint(25.4775, 80.3349),
    );

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('25.47750, 80.33490'), findsOneWidget);
  });

  testWidgets("the app's places are tagged and can't be edited", (
    tester,
  ) async {
    tallView(tester);
    await tester.pumpWidget(
      const MaterialApp(home: MockLocationScreen(config: config)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Point'));
    await tester.pumpAndSettle();

    expect(find.text('Office'), findsOneWidget);
    expect(find.text('app'), findsOneWidget);
    expect(find.byTooltip('Rename or forget'), findsNothing);

    await tester.tap(find.text('Office'));
    await tester.pumpAndSettle();
    expect(find.text('Fixed point'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });

  testWidgets('a route plays and pauses from the screen', (tester) async {
    tallView(tester);
    final controller = MockLocationController(config: config);
    addTearDown(controller.dispose);
    await controller.init();
    await controller.setMode(MockMode.route);
    await controller.pasteRoute('25.4775, 80.3349\n25.4890, 80.3420');

    await tester.pumpWidget(
      MaterialApp(
        home: MockLocationScreen(config: config, controller: controller),
      ),
    );
    await tester.pump();
    expect(find.text('Moving along a route'), findsOneWidget);
    expect(find.text('2 points · 1.46 km'), findsOneWidget);

    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(find.text('Route paused'), findsOneWidget);
    expect(controller.state.playing, isFalse);

    await tester.tap(find.text('Play'));
    await tester.pump();
    expect(controller.state.playing, isTrue);

    await controller.setMode(MockMode.off);
    await tester.pumpAndSettle();
  });
}
