import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'app_state.dart';
import 'home_page.dart';
import 'models.dart';

const seedGreen = Color(0xFF3CB043);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.load();

  // Version for the corner overlay — read from the bundled pubspec.yaml so
  // it can never drift from the real app version.
  var version = '';
  try {
    version = versionFromPubspec(await rootBundle.loadString('pubspec.yaml'));
  } catch (e) {
    debugPrint('Could not read version from pubspec: $e');
  }

  runApp(YouDownApp(state: state, version: version));
}

class YouDownApp extends StatelessWidget {
  const YouDownApp({super.key, required this.state, this.version = ''});

  final AppState state;
  final String version;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YouDown',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedGreen,
          primary: seedGreen,
        ),
        visualDensity: VisualDensity.compact,
      ),
      // Persistent version tag in the bottom-right corner, above every page.
      builder: (context, child) => Stack(
        textDirection: TextDirection.ltr,
        children: [
          ?child,
          if (version.isNotEmpty)
            Positioned(
              right: 4,
              bottom: 2,
              child: IgnorePointer(
                child: Text(
                  version,
                  style: const TextStyle(
                    fontSize: 5,
                    color: Colors.black54,
                    decoration: TextDecoration.none,
                    fontWeight: FontWeight.normal,
                  ),
                ),
              ),
            ),
        ],
      ),
      home: HomePage(state: state),
    );
  }
}
