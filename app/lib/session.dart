import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api/api_client.dart';

/// The server address baked in at build time:
///   flutter build apk --dart-define=API_BASE_URL=https://my-api.vercel.app
/// It can also be changed on the sign-in screen, which is remembered on the phone.
const defaultBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:3000');

/// Holds the server address and sign-in token, and the API client that uses them.
class Session extends ChangeNotifier {
  Session(this._prefs, {this._httpClient}) {
    _baseUrl = _prefs.getString(_baseUrlKey) ?? defaultBaseUrl;
    _token = _prefs.getString(_tokenKey);
    _api = _buildApi();
  }

  static const _baseUrlKey = 'api_base_url';
  static const _tokenKey = 'auth_token';

  final SharedPreferences _prefs;
  final http.Client? _httpClient;
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
  }

  Future<void> signOut() async {
    if (_token == null) return;
    _token = null;
    await _prefs.remove(_tokenKey);
    _api = _buildApi();
    notifyListeners();
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
