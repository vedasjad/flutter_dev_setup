import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dev_setup/flutter_dev_setup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

Future<void> pumpScreen(
  WidgetTester tester,
  DevSetupController controller, {
  void Function(BuildContext context)? onProceed,
  ThemeData? theme,
  TransitionBuilder? builder,
}) async {
  tester.view.physicalSize = const Size(1080, 3600);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: builder,
      home: DevSetupScreen(
        controller: controller,
        defaultBaseUrl: defaultUrl,
        onBaseUrlChanged: (_) {},
        onProceed: onProceed ?? (_) {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// FakeScanner answers on a zero-length timer, and fake time only moves when
// the tester pumps.
Future<void> settle(WidgetTester tester, Future<void> work) async {
  await tester.pump(Duration.zero);
  await work;
}

// find.text also matches the URL field once that server is selected.
Finder rowText(String text) =>
    find.byWidgetPredicate((widget) => widget is Text && widget.data == text);

Widget swapHost(DevSetupController? controller) => MaterialApp(
  home: DevSetupScreen(
    controller: controller,
    defaultBaseUrl: defaultUrl,
    onBaseUrlChanged: (_) {},
    onProceed: (_) {},
    discovery: testConfig,
    store: testStore(),
    enableDiscovery: false,
  ),
);

double contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// The colour [finder]'s widget is painted on: every fill above the nearest
/// opaque one, composited.
Color backgroundBehind(WidgetTester tester, Finder finder) {
  final layers = <Color>[];
  tester.element(finder).visitAncestorElements((element) {
    final color = switch (element.widget) {
      DecoratedBox(decoration: BoxDecoration(:final color)) => color,
      DecoratedBox(decoration: ShapeDecoration(:final color)) => color,
      Material(:final color) => color,
      _ => null,
    };
    if (color != null) layers.add(color);
    return color == null || color.a < 1;
  });
  return layers.reversed.fold<Color>(
    const Color(0xFFFFFFFF),
    (under, over) => Color.alphaBlend(over, under),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('lists servers and commits the one tapped', (tester) async {
    final committed = <String>[];
    final c = await buildController(
      committed: committed,
      scanner: FakeScanner(
        found: [
          server('192.168.0.102'),
          server('192.168.0.111', name: 'ci-box'),
        ],
      ),
    );
    await settle(tester, c.scan(manual: false));
    await pumpScreen(tester, c);

    expect(find.text('Developer Setup'), findsOneWidget);
    expect(find.text('192.168.0.102:5001'), findsOneWidget);
    expect(find.text('ci-box'), findsOneWidget);

    await tester.tap(find.text('192.168.0.102:5001'));
    await tester.pumpAndSettle();

    expect(committed, ['http://192.168.0.102:5001/api/v1/']);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });

  testWidgets('Local IP starts a scan that selects what it finds', (
    tester,
  ) async {
    final committed = <String>[];
    final c = await buildController(
      committed: committed,
      scanner: FakeScanner(found: [server('192.168.0.102')]),
    );
    await pumpScreen(tester, c);

    await tester.tap(find.text('Local IP'));
    await tester.pumpAndSettle();

    expect(committed, ['http://192.168.0.102:5001/api/v1/']);
  });

  testWidgets('the refresh button starts a scan that selects what it finds', (
    tester,
  ) async {
    final committed = <String>[];
    final c = await buildController(
      committed: committed,
      scanner: FakeScanner(found: [server('192.168.0.102')]),
    );
    await pumpScreen(tester, c);

    await tester.tap(find.byTooltip('Scan again'));
    await tester.pumpAndSettle();

    expect(committed, ['http://192.168.0.102:5001/api/v1/']);
  });

  testWidgets('Scan again after an empty scan selects what it finds', (
    tester,
  ) async {
    final committed = <String>[];
    var round = 0;
    final scanners = [
      FakeScanner(outcome: ScanOutcome.notFound),
      FakeScanner(found: [server('192.168.0.102')]),
    ];
    final c = DevSetupController(
      defaultBaseUrl: defaultUrl,
      onBaseUrlChanged: committed.add,
      config: testConfig,
      store: testStore(),
      scannerFactory: () => scanners[round],
    );
    await c.init(startBackgroundWork: false);
    await settle(tester, c.scan(manual: false));
    await pumpScreen(tester, c);
    expect(c.scanPhase, ScanPhase.nothingFound);

    round = 1;
    await tester.tap(find.widgetWithText(TextButton, 'Scan again'));
    await tester.pumpAndSettle();

    expect(committed, ['http://192.168.0.102:5001/api/v1/']);
  });

  // Regression: disposing the dialog's controller on the dialog future tripped
  // `_dependents.isEmpty` while the route was still animating out.
  testWidgets('cancelling the name dialog closes it cleanly', (tester) async {
    final c = await buildController(
      scanner: FakeScanner(found: [server('192.168.0.102')]),
    );
    await settle(tester, c.scan(manual: false));
    await pumpScreen(tester, c);

    await tester.tap(find.byTooltip('Name this server'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(
      find.textContaining('Leave it empty to clear the name.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('saving a name shows it in place of the address', (tester) async {
    final c = await buildController(
      scanner: FakeScanner(found: [server('192.168.0.102')]),
    );
    await settle(tester, c.scan(manual: false));
    await pumpScreen(tester, c);

    await tester.tap(find.byTooltip('Name this server'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'my laptop');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('my laptop'), findsOneWidget);
    expect(find.text('192.168.0.102:5001'), findsOneWidget);
  });

  testWidgets('forget is only offered for saved addresses', (tester) async {
    SharedPreferences.setMockInitialValues({
      'devCustomServers': ['http://10.9.9.9:5001'],
    });
    final c = await buildController(
      scanner: FakeScanner(found: [server('192.168.0.102')]),
    );
    await settle(tester, c.scan(manual: false));
    await pumpScreen(tester, c);
    expect(find.text('saved'), findsOneWidget);

    await tester.tap(find.byTooltip('Name this server').last);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Forget'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Name this server').first);
    await tester.pumpAndSettle();
    expect(find.text('Forget'), findsOneWidget);
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();

    expect(find.text('10.9.9.9:5001'), findsNothing);
    expect(find.text('192.168.0.102:5001'), findsOneWidget);
    expect(await c.store.customOrigins(), isEmpty);
  });

  testWidgets('the add dialog rejects a non-address and accepts a real one', (
    tester,
  ) async {
    final committed = <String>[];
    final c = await buildController(committed: committed);
    await pumpScreen(tester, c);

    await tester.tap(find.byTooltip('Add an address'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'nonsense');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Needs a scheme and a host'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(committed, isEmpty);

    await tester.enterText(find.byType(TextField).last, 'http://box.lan:5001');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(committed.last, 'http://box.lan:5001/api/v1/');
    expect(rowText('box.lan:5001'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });

  testWidgets('the dialogs scroll rather than overflow above a keyboard', (
    tester,
  ) async {
    final c = await buildController(
      scanner: FakeScanner(found: [server('192.168.0.102')]),
    );
    await settle(tester, c.scan(manual: false));
    await pumpScreen(tester, c);

    Future<void> openInLandscape(Finder opener) async {
      tester.view.physicalSize = const Size(1080, 3600);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(opener);
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.viewInsets = const FakeViewPadding(bottom: 160 * 3);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    }

    await openInLandscape(find.byTooltip('Name this server'));
    await openInLandscape(find.byTooltip('Add an address'));
  });

  // Regression: the picker and the field resolved their styles over different
  // defaults and rendered as two different fonts.
  testWidgets('the scheme picker renders in the same style as the field', (
    tester,
  ) async {
    final c = await buildController();
    await pumpScreen(tester, c, theme: ThemeData(fontFamily: 'AppFont'));

    final field = tester
        .widget<EditableText>(find.byType(EditableText).first)
        .style;
    final picker = tester
        .widget<RichText>(
          find.descendant(
            of: find.text('https://').first,
            matching: find.byType(RichText),
          ),
        )
        .text
        .style;
    expect(field.fontFamily, 'AppFont');
    expect(picker, field);
  });

  testWidgets('the scheme picker switches the URL scheme', (tester) async {
    final c = await buildController();
    await pumpScreen(tester, c);
    expect(c.scheme, 'https');

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('http://').last);
    await tester.pumpAndSettle();

    expect(c.scheme, 'http');
    expect(c.fullUrl, 'http://staging.example.com/api/v1/');
  });

  testWidgets('Proceed commits and hands over once the server answers', (
    tester,
  ) async {
    var proceeded = false;
    final committed = <String>[];
    final c = await buildController(
      committed: committed,
      scanner: FakeScanner(
        verifyResults: {
          'https://staging.example.com:443': server('staging.example.com'),
        },
      ),
    );
    await settle(tester, c.checkHealth());
    await pumpScreen(tester, c, onProceed: (_) => proceeded = true);

    expect(find.text('Connected'), findsOneWidget);
    await tester.tap(find.text('Proceed'));
    await tester.pumpAndSettle();

    expect(proceeded, isTrue);
    expect(committed, [defaultUrl]);
  });

  testWidgets('Proceed hands over once however fast it is tapped', (
    tester,
  ) async {
    var proceeded = 0;
    final c = await buildController(
      scanner: FakeScanner(
        verifyResults: {
          'https://staging.example.com:443': server('staging.example.com'),
        },
      ),
    );
    await settle(tester, c.checkHealth());
    await pumpScreen(tester, c, onProceed: (_) => proceeded++);

    final proceed = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Proceed'),
    );
    proceed.onPressed!();
    proceed.onPressed!();
    await tester.pumpAndSettle();

    expect(proceeded, 1);
  });

  testWidgets('Proceed is disabled while the server is unreachable', (
    tester,
  ) async {
    var proceeded = false;
    final c = await buildController();
    await settle(tester, c.checkHealth());
    await pumpScreen(tester, c, onProceed: (_) => proceeded = true);

    expect(find.text('No response'), findsOneWidget);
    await tester.tap(find.text('Proceed'));
    await tester.pumpAndSettle();
    expect(proceeded, isFalse);
  });

  testWidgets('without discovery there is no scan to start', (tester) async {
    final c = DevSetupController(
      defaultBaseUrl: defaultUrl,
      onBaseUrlChanged: (_) {},
      config: testConfig,
      store: testStore(),
      scannerFactory: FakeScanner.new,
      enableDiscovery: false,
    );
    await c.init(startBackgroundWork: false);
    await pumpScreen(tester, c);

    expect(find.text('Local IP'), findsNothing);
    expect(find.byTooltip('Scan again'), findsNothing);
    expect(find.byTooltip('Add an address'), findsOneWidget);
    expect(find.textContaining('Tap Local IP'), findsNothing);
  });

  testWidgets('health checks pause while the screen is covered or hidden', (
    tester,
  ) async {
    final fake = FakeScanner();
    final c = await buildController(
      scanner: fake,
      pingInterval: const Duration(seconds: 1),
    );
    await pumpScreen(tester, c);
    c.startPinging();
    await tester.pump(const Duration(seconds: 3));
    expect(fake.verifyCalls, greaterThan(1));

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold())),
    );
    await tester.pumpAndSettle();
    final covered = fake.verifyCalls;
    await tester.pump(const Duration(seconds: 5));
    expect(fake.verifyCalls, covered);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(fake.verifyCalls, greaterThan(covered));

    void moveTo(List<AppLifecycleState> states) {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    moveTo(const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);
    await tester.pump();
    final hidden = fake.verifyCalls;
    await tester.pump(const Duration(seconds: 5));
    expect(fake.verifyCalls, hidden);

    moveTo(const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    await tester.pump(Duration.zero);
    expect(fake.verifyCalls, greaterThan(hidden));

    await tester.pumpWidget(const SizedBox());
    moveTo(const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);
    moveTo(const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    c.dispose();
  });

  testWidgets('a controller swapped in while covered starts paused', (
    tester,
  ) async {
    final fake = FakeScanner();
    final first = await buildController();
    final second = await buildController(
      scanner: fake,
      pingInterval: const Duration(seconds: 1),
    );
    final current = ValueNotifier(first);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<DevSetupController>(
          valueListenable: current,
          builder: (context, controller, _) => DevSetupScreen(
            controller: controller,
            defaultBaseUrl: defaultUrl,
            onBaseUrlChanged: (_) {},
            onProceed: (_) {},
          ),
        ),
      ),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold())),
    );
    await tester.pumpAndSettle();

    current.value = second;
    await tester.pump();
    second.startPinging();
    await tester.pump(const Duration(seconds: 3));

    expect(fake.verifyCalls, 0);
    await tester.pumpWidget(const SizedBox());
    first.dispose();
    second.dispose();
  });

  testWidgets("swapping in its own controller leaves the caller's alone", (
    tester,
  ) async {
    final c = await buildController();
    await tester.pumpWidget(swapHost(c));
    await tester.pumpAndSettle();
    await tester.pumpWidget(swapHost(null));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());

    c.urlController.text = '10.0.0.4:5001';
    c.dispose();
  });

  testWidgets('a controller passed in later replaces the one it made', (
    tester,
  ) async {
    final c = await buildController();
    c.urlController.text = '10.0.0.4:5001';
    await tester.pumpWidget(swapHost(null));
    await tester.pumpAndSettle();
    await tester.pumpWidget(swapHost(c));
    await tester.pumpAndSettle();

    expect(find.text('10.0.0.4:5001'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('every control is large enough to tap, and copy is labelled', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final c = await buildController(
      scanner: FakeScanner(found: [server('192.168.0.102')]),
    );
    await settle(tester, c.scan(manual: false));
    await pumpScreen(tester, c);

    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    final copy = tester.getSemantics(find.byTooltip('Copy URL'));
    expect(copy.getSemanticsData().tooltip, 'Copy URL');
    expect(copy.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(copy.getSemanticsData().flagsCollection.isButton, isTrue);

    // The guideline skips nodes inside the dialog's scroll view.
    await tester.tap(find.byTooltip('Add an address'));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(TextField),
    );
    expect(
      tester.getSize(field).height,
      greaterThanOrEqualTo(kMinInteractiveDimension),
    );
    semantics.dispose();
  });

  testWidgets('tapping the status card away from its icon copies the URL', (
    tester,
  ) async {
    final copied = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final c = await buildController();
    await pumpScreen(tester, c);

    await tester.tap(find.text(defaultUrl));
    await tester.pumpAndSettle();

    expect(copied, [defaultUrl]);
    expect(find.text('Copied $defaultUrl'), findsOneWidget);
  });

  testWidgets('a screen that made its own controller reports to the latest '
      'callback', (tester) async {
    final first = <String>[];
    final second = <String>[];
    Widget host(void Function(String url) onChanged) => MaterialApp(
      home: DevSetupScreen(
        defaultBaseUrl: defaultUrl,
        onBaseUrlChanged: onChanged,
        onProceed: (_) {},
        discovery: testConfig,
        store: testStore(),
        enableDiscovery: false,
      ),
    );
    await tester.pumpWidget(host(first.add));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(second.add));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();

    expect(first, isEmpty);
    expect(second, [defaultUrl]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rows tell assistive tech which one is selected', (tester) async {
    final semantics = tester.ensureSemantics();
    final c = await buildController(
      scanner: FakeScanner(
        found: [server('192.168.0.102'), server('192.168.0.111')],
      ),
    );
    await settle(tester, c.scan(manual: false));
    await pumpScreen(tester, c);

    await tester.tap(rowText('192.168.0.102:5001'));
    await tester.pumpAndSettle();

    final selected = tester
        .getSemantics(rowText('192.168.0.102:5001'))
        .getSemanticsData();
    expect(selected.flagsCollection.isButton, isTrue);
    expect(selected.flagsCollection.isSelected, Tristate.isTrue);
    expect(selected.hasAction(SemanticsAction.tap), isTrue);
    final other = tester
        .getSemantics(rowText('192.168.0.111:5001'))
        .getSemanticsData();
    expect(other.flagsCollection.isButton, isTrue);
    expect(other.flagsCollection.isSelected, Tristate.isFalse);
    semantics.dispose();
  });

  testWidgets('status text on the default theme meets WCAG AA', (tester) async {
    SharedPreferences.setMockInitialValues({
      'devCustomServers': ['http://10.9.9.9:5001'],
    });
    final c = await buildController(
      scanner: FakeScanner(
        found: [
          server('192.168.0.101', ms: 10),
          server('192.168.0.102', ms: 120),
          server('192.168.0.103', ms: 400),
        ],
        verifyResults: {
          'https://staging.example.com:443': server('staging.example.com'),
        },
      ),
    );
    await settle(tester, c.scan(manual: false));
    await pumpScreen(tester, c);

    void expectReadable(String text) {
      final finder = rowText(text);
      final color = tester.widget<Text>(finder).style!.color!;
      expect(
        contrast(color, backgroundBehind(tester, finder)),
        greaterThanOrEqualTo(4.5),
        reason: text,
      );
    }

    for (final text in [
      '10 ms',
      '120 ms',
      '400 ms',
      'saved',
      'Not checked yet',
      'BASE URL',
    ]) {
      expectReadable(text);
    }

    await tester.tap(rowText('192.168.0.102:5001'));
    await tester.pumpAndSettle();
    expectReadable('120 ms');

    await settle(tester, c.resetToDefault());
    await settle(tester, c.checkHealth());
    await tester.pumpAndSettle();
    expectReadable('Connected');
  });

  testWidgets('the source switch marks the active side right to left too', (
    tester,
  ) async {
    final c = await buildController();
    await pumpScreen(
      tester,
      c,
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
    );
    expect(c.urlMode, isFalse);

    final thumb = tester
        .getCenter(
          find.descendant(
            of: find.byType(AnimatedAlign),
            matching: find.byType(DecoratedBox),
          ),
        )
        .dx;
    final onDefault = tester.getCenter(find.text('Default')).dx;
    final onLocal = tester.getCenter(find.text('Local IP')).dx;
    expect((thumb - onDefault).abs(), lessThan((thumb - onLocal).abs()));
  });

  testWidgets('the back button and cursor follow DevSetupTheme', (
    tester,
  ) async {
    const dark = DevSetupTheme(
      primary: Color(0xFF818CF8),
      background: Color(0xFF0B0D12),
      textPrimary: Color(0xFFE6E8EE),
    );
    final c = await buildController();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorSchemeSeed: Colors.teal),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DevSetupScreen(
                  controller: c,
                  defaultBaseUrl: defaultUrl,
                  onBaseUrlChanged: (_) {},
                  onProceed: (_) {},
                  theme: dark,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      IconTheme.of(tester.element(find.byType(BackButtonIcon))).color,
      dark.textPrimary,
    );
    for (final field in tester.widgetList<EditableText>(
      find.byType(EditableText),
    )) {
      expect(field.cursorColor, dark.primary);
    }

    await tester.tap(find.byTooltip('Add an address'));
    await tester.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(dialogField).cursorColor, dark.primary);
  });

  testWidgets('field text sits centred in the taller fields', (tester) async {
    final c = await buildController();
    await pumpScreen(tester, c);

    void expectCentred(Finder field) {
      final text = find.descendant(
        of: field,
        matching: find.byType(EditableText),
      );
      expect(
        tester.getCenter(text).dy,
        closeTo(tester.getCenter(field).dy, 0.5),
      );
    }

    expectCentred(find.byType(TextField).first);
    await tester.tap(find.byTooltip('Add an address'));
    await tester.pumpAndSettle();
    expectCentred(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      ),
    );
  });
}
