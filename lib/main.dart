import 'package:flutter/material.dart';

import 'app_state.dart';
import 'home_page.dart';

const seedGreen = Color(0xFF3CB043);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.load();
  runApp(YouDownApp(state: state));
}

class YouDownApp extends StatelessWidget {
  const YouDownApp({super.key, required this.state});

  final AppState state;

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
      home: HomePage(state: state),
    );
  }
}
