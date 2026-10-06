import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = Session(await SharedPreferences.getInstance());
  runApp(ShopInventoryApp(session: session));
}

class ShopInventoryApp extends StatelessWidget {
  const ShopInventoryApp({super.key, required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    return SessionScope(
      session: session,
      child: MaterialApp(
        title: 'Shop Inventory',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    // A new key per sign-in so screens reload with the fresh token.
    return session.signedIn ? HomeScreen(key: ObjectKey(session.api)) : const LoginScreen();
  }
}
