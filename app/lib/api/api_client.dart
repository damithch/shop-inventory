import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';

/// An error from the API. [message] is written to be shown to the user as is.
class ApiException implements Exception {
  ApiException(this.message, {this.status});

  final String message;
  final int? status;

  bool get isUnauthorized => status == 401;

  @override
  String toString() => message;
}

/// Talks to the inventory backend. See backend/README.md for the endpoints.
class ApiClient {
  ApiClient({required this.baseUrl, this.token, http.Client? httpClient, this.onUnauthorized})
    : _http = httpClient ?? http.Client();

  final String baseUrl;
  String? token;
  final http.Client _http;

  /// Called when a signed-in request comes back 401, so the app can sign out.
  final void Function()? onUnauthorized;

  // Generous, since the first request after a quiet spell is slower (server and
  // database waking up) and shop Wi-Fi or mobile data can be slow.
  static const _timeout = Duration(seconds: 75);

  Uri _uri(String path, [Map<String, String?>? query]) {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final q = query == null
        ? null
        : {
            for (final e in query.entries)
              if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
          };
    return Uri.parse('$base$path').replace(queryParameters: (q == null || q.isEmpty) ? null : q);
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    List<int>? bytes,
    Map<String, String?>? query,
  }) async {
    final request = http.Request(method, _uri(path, query));
    request.headers['Accept'] = 'application/json';
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    } else if (bytes != null) {
      request.headers['Content-Type'] = 'application/octet-stream';
      request.bodyBytes = bytes;
    }

    http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request).timeout(_timeout));
    } on TimeoutException {
      throw ApiException('The server took too long to answer. Check your connection and try again.');
    } catch (_) {
      throw ApiException('Could not reach the server. Check your connection and the server address.');
    }

    final decoded = _decode(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) return decoded;

    if (response.statusCode == 401 && token != null) onUnauthorized?.call();
    final message = decoded is Map && decoded['error'] is String
        ? decoded['error'] as String
        : 'Something went wrong (${response.statusCode})';
    throw ApiException(message, status: response.statusCode);
  }

  dynamic _decode(String body) {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  // Auth

  Future<String> login(String password) async {
    final res = await _send('POST', '/auth/login', body: {'password': password});
    return res['token'] as String;
  }

  // Locations

  Future<List<Location>> locations() async {
    final res = await _send('GET', '/locations') as List;
    return res.map((e) => Location.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Location> addBranch(String name) async {
    final res = await _send('POST', '/locations', body: {'name': name});
    return Location.fromJson(res as Map<String, dynamic>);
  }

  Future<Location> updateLocation(int id, {String? name, bool? archived}) async {
    final res = await _send('PATCH', '/locations/$id', body: {'name': ?name, 'archived': ?archived});
    return Location.fromJson(res as Map<String, dynamic>);
  }

  Future<LocationStock> locationStock(int id) async {
    final res = await _send('GET', '/locations/$id/stock');
    return LocationStock.fromJson(res as Map<String, dynamic>);
  }

  // Items

  Future<List<Item>> items({String? search}) async {
    final res = await _send('GET', '/items', query: {'q': search}) as List;
    return res.map((e) => Item.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Item> addItem({required String name, String? sku, String? unit}) async {
    final res = await _send(
      'POST',
      '/items',
      body: {
        'name': name,
        if (sku != null && sku.isNotEmpty) 'sku': sku,
        if (unit != null && unit.isNotEmpty) 'unit': unit,
      },
    );
    return Item.fromJson(res as Map<String, dynamic>);
  }

  Future<ItemDetail> item(int id) async {
    final res = await _send('GET', '/items/$id');
    return ItemDetail.fromJson(res as Map<String, dynamic>);
  }

  Future<void> updateItem(int id, {String? name, String? sku, String? unit, bool? archived}) async {
    await _send('PATCH', '/items/$id', body: {'name': ?name, 'sku': ?sku, 'unit': ?unit, 'archived': ?archived});
  }

  // Stock changes

  Future<StockResult> receive({required int itemId, required int quantity, int? locationId, String? note}) =>
      _stock('/stock/receive', {
        'item_id': itemId,
        'quantity': quantity,
        'location_id': ?locationId,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<StockResult> transfer({
    required int itemId,
    required int toLocationId,
    required int quantity,
    int? fromLocationId,
    String? note,
  }) => _stock('/stock/transfer', {
    'item_id': itemId,
    'to_location_id': toLocationId,
    'quantity': quantity,
    'from_location_id': ?fromLocationId,
    if (note != null && note.isNotEmpty) 'note': note,
  });

  Future<StockResult> sale({required int itemId, required int locationId, required int quantity, String? note}) =>
      _stock('/stock/sale', {
        'item_id': itemId,
        'location_id': locationId,
        'quantity': quantity,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<StockResult> adjust({required int itemId, required int locationId, required int newQuantity, String? note}) =>
      _stock('/stock/adjust', {
        'item_id': itemId,
        'location_id': locationId,
        'new_quantity': newQuantity,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<StockResult> _stock(String path, Map<String, Object> body) async {
    final res = await _send('POST', path, body: body);
    return StockResult.fromJson(res as Map<String, dynamic>);
  }

  /// Sets the alert level for one item at one location. null goes back to the default.
  Future<List<StockAlert>> setThreshold({required int itemId, required int locationId, required int? threshold}) async {
    final res = await _send(
      'PUT',
      '/stock/threshold',
      body: {'item_id': itemId, 'location_id': locationId, 'threshold': threshold},
    );
    return StockAlert.listFrom((res as Map<String, dynamic>)['alerts']);
  }

  Future<List<LowStockEntry>> lowStock({int? locationId}) async {
    final res = await _send('GET', '/stock/low', query: {'location_id': locationId?.toString()}) as List;
    return res.map((e) => LowStockEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Movement>> movements({int? itemId, int? locationId, int limit = 50}) async {
    final res = await _send(
      'GET',
      '/stock/movements',
      query: {'item_id': itemId?.toString(), 'location_id': locationId?.toString(), 'limit': '$limit'},
    ) as List;
    return res.map((e) => Movement.fromJson(e as Map<String, dynamic>)).toList();
  }

  // Settings and alerts

  Future<int> defaultThreshold() async {
    final res = await _send('GET', '/settings');
    return asInt(res['default_threshold']);
  }

  Future<int> setDefaultThreshold(int value) async {
    final res = await _send('PUT', '/settings', body: {'default_threshold': value});
    return asInt(res['default_threshold']);
  }

  Future<List<AlertRecord>> alerts({int limit = 50}) async {
    final res = await _send('GET', '/alerts', query: {'limit': '$limit'}) as List;
    return res.map((e) => AlertRecord.fromJson(e as Map<String, dynamic>)).toList();
  }

  // Stock sheets and sales

  /// What uploading this stock sheet would change. Saves nothing.
  /// [locationId] is where a plain quantity column's stock is; null means the main shop.
  Future<UploadPreview> previewUpload({required String filename, required List<int> bytes, int? locationId}) async {
    final res = await _send(
      'POST',
      '/uploads/preview',
      bytes: bytes,
      query: {'filename': filename, 'location_id': locationId?.toString()},
    );
    return UploadPreview.fromJson(res as Map<String, dynamic>);
  }

  /// Saves the stock sheet: new items are added, and lower counts are recorded as sold.
  Future<UploadResult> upload({required String filename, required List<int> bytes, int? locationId}) async {
    final res = await _send(
      'POST',
      '/uploads',
      bytes: bytes,
      query: {'filename': filename, 'location_id': locationId?.toString()},
    );
    return UploadResult.fromJson(res as Map<String, dynamic>);
  }

  Future<List<UploadResult>> uploads({int limit = 50}) async {
    final res = await _send('GET', '/uploads', query: {'limit': '$limit'}) as List;
    return res.map((e) => UploadResult.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// What sold on [date] (the shop's today when null), optionally at one location.
  Future<SalesReport> sales({String? date, int? locationId}) async {
    final res = await _send('GET', '/reports/sales', query: {'date': date, 'location_id': locationId?.toString()});
    return SalesReport.fromJson(res as Map<String, dynamic>);
  }

  // Push notifications

  Future<void> registerDevice(String pushToken) async {
    await _send('POST', '/devices', body: {'token': pushToken, 'platform': 'android'});
  }

  Future<void> unregisterDevice(String pushToken) async {
    await _send('DELETE', '/devices/${Uri.encodeComponent(pushToken)}');
  }
}
