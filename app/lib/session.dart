import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api/api_client.dart';
import 'push.dart';

/// The server address the app starts with: the live server, unless another is
/// given at build time, e.g. for a server on your computer seen from the emulator:
///   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000
/// It can also be changed on the sign-in screen, which is remembered on the phone.
const defaultBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://backend-eight-lemon-fwgmzqzwyt.vercel.app',
);

/// Holds the server address and sign-in token, and the API client that uses them.
class Session extends ChangeNotifier {
  Session(this._prefs, {this._httpClient, this._push}) {
    _baseUrl = _prefs.getString(_baseUrlKey) ?? defaultBaseUrl;
    _token = _prefs.getString(_tokenKey);
    _api = _buildApi();
    _push?.onTokenRefresh.listen((token) {
      _pushToken = token;
      _registerPush();
    });
    if (signedIn) unawaited(_registerPush());
  }

  static const _baseUrlKey = 'api_base_url';
  static const _tokenKey = 'auth_token';

  final SharedPreferences _prefs;
  final http.Client? _httpClient;
  final PushService? _push;
  String? _pushToken;
  late String _baseUrl;
  String? _token;
  late ApiClient _api;

  String get baseUrl => _baseUrl;
  bool get signedIn => _token != null;
  ApiClient get api => _api;

  ApiClient _buildApi() =>
      ApiClient(baseUrl: _baseUrl, token: _token, httpClient: _httpClient, onUnauthorized: signOut);

  Future<void> setBaseUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed == _baseUrl) return;
    _baseUrl = trimmed;
    await _prefs.setString(_baseUrlKey, trimmed);
    _api = _buildApi();
    notifyListeners();
  }

  Future<void> signIn(String password) async {
    final token = await _api.login(password);
    _token = token;
    await _prefs.setString(_tokenKey, token);
    _api = _buildApi();
    notifyListeners();
    unawaited(_registerPush());
  }

  Future<void> signOut() async {
    if (_token == null) return;
    // Stop low-stock notifications to this phone. Best effort: signing out
    // must work even offline.
    final oldApi = _api;
    final pushToken = _pushToken;
    _token = null;
    await _prefs.remove(_tokenKey);
    _api = _buildApi();
    notifyListeners();
    if (pushToken != null) unawaited(oldApi.unregisterDevice(pushToken).catchError((_) {}));
  }

  /// Tells the server where to send low-stock alerts for this phone. Repeated
  /// on every start, which is harmless and recovers from a missed attempt.
  Future<void> _registerPush() async {
    final push = _push;
    if (push == null || !signedIn) return;
    try {
      final pushToken = _pushToken ??= await push.getToken();
      if (pushToken != null && signedIn) await _api.registerDevice(pushToken);
    } catch (e) {
      debugPrint('Could not register for push notifications: $e');
    }
  }
}

/// Makes the [Session] available to every screen.
class SessionScope extends InheritedNotifier<Session> {
  const SessionScope({super.key, required Session session, required super.child}) : super(notifier: session);

  static Session of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SessionScope>()!.notifier!;

  /// The session without rebuilding when it changes, for use in callbacks and initState.
  static Session read(BuildContext context) => context.getInheritedWidgetOfExactType<SessionScope>()!.notifier!;

  static ApiClient apiOf(BuildContext context) => read(context).api;
}
