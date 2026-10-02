import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dev_setup/flutter_dev_setup.dart';

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

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ValueListenableBuilder<String>(
            valueListenable: apiBaseUrl,
            builder: (context, url, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'API base URL',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                SelectableText(url, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
