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
  }) async => _decode((await _fetch(method, path, body: body, bytes: bytes, query: query)).body);

  /// Sends a request and returns the response if it succeeded, else throws an
  /// [ApiException] with the server's message.
  Future<http.Response> _fetch(
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

    if (response.statusCode >= 200 && response.statusCode < 300) return response;

    if (response.statusCode == 401 && token != null) onUnauthorized?.call();
    final decoded = _decode(response.body);
    final message = decoded is Map && decoded['error'] is String
        ? decoded['error'] as String
        : 'Something went wrong (${response.statusCode})';
    throw ApiException(message, status: response.statusCode);
  }

  /// Downloads a file, named as the server names it.
  Future<ExportFile> _download(String path, Map<String, String?> query, String fallbackName) async {
    final response = await _fetch('GET', path, query: query);
    final disposition = response.headers['content-disposition'] ?? '';
    final name = RegExp(r'filename="([^"]+)"').firstMatch(disposition)?.group(1) ?? fallbackName;
    final mimeType = (response.headers['content-type'] ?? 'application/octet-stream').split(';').first.trim();
    return ExportFile(name: name, bytes: response.bodyBytes, mimeType: mimeType);
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

  /// Changes the sign-in password. Other phones are signed out; returns the
  /// new token for this one.
  Future<String> changePassword({required String current, required String next}) async {
    final res = await _send('POST', '/auth/password', body: {'current_password': current, 'new_password': next});
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

  // Reset and delete. Each needs the password again; a dry run checks it and
  // says what would change without changing anything.

  /// Every count at [locationId], or at every place when null, to zero.
  Future<ResetResult> resetStock({int? locationId, required String password, bool dryRun = false}) =>
      _reset('/reset/stock', {'location_id': ?locationId}, password, dryRun);

  /// The item's stock everywhere to zero, then it is removed.
  Future<ResetResult> deleteItem(int itemId, {required String password, bool dryRun = false}) =>
      _reset('/reset/delete-item', {'item_id': itemId}, password, dryRun);

  /// Every item's stock to zero, then every item is removed. Places stay.
  Future<ResetResult> deleteAllItems({required String password, bool dryRun = false}) =>
      _reset('/reset/delete-all-items', {}, password, dryRun);

  /// The branch's stock to zero, then the branch is removed.
  Future<ResetResult> deleteBranch(int locationId, {required String password, bool dryRun = false}) =>
      _reset('/reset/delete-branch', {'location_id': locationId}, password, dryRun);

  Future<ResetResult> _reset(String path, Map<String, Object> body, String password, bool dryRun) async {
    final res = await _send('POST', path, body: {...body, 'password': password, 'dry_run': dryRun});
    return ResetResult.fromJson(res as Map<String, dynamic>);
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
  /// [matches] maps a sheet row to the id of the item it is, for names the
  /// app doesn't recognise. Saving remembers them for later sheets.
  Future<UploadPreview> previewUpload({
    required String filename,
    required List<int> bytes,
    int? locationId,
    Map<int, int> matches = const {},
  }) async {
    final res = await _send(
      'POST',
      '/uploads/preview',
      bytes: bytes,
      query: _uploadQuery(filename, locationId, matches),
    );
    return UploadPreview.fromJson(res as Map<String, dynamic>);
  }

  /// Saves the stock sheet: new items are added, and lower counts are recorded as sold.
  Future<UploadResult> upload({
    required String filename,
    required List<int> bytes,
    int? locationId,
    Map<int, int> matches = const {},
  }) async {
    final res = await _send('POST', '/uploads', bytes: bytes, query: _uploadQuery(filename, locationId, matches));
    return UploadResult.fromJson(res as Map<String, dynamic>);
  }

  Map<String, String?> _uploadQuery(String filename, int? locationId, Map<int, int> matches) => {
    'filename': filename,
    'location_id': locationId?.toString(),
    'matches': [for (final e in matches.entries) '${e.key}:${e.value}'].join(','),
  };

  Future<List<UploadResult>> uploads({int limit = 50}) async {
    final res = await _send('GET', '/uploads', query: {'limit': '$limit'}) as List;
    return res.map((e) => UploadResult.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// What saving a pasted list would change. Saves nothing. [locationId] is
  /// where stock arrives (purchase), leaves from (transfer) or is sold (sale);
  /// [toLocationId] is where a transfer goes.
  Future<PastePreview> previewPaste({
    required PasteAction action,
    required String text,
    int? locationId,
    int? toLocationId,
    Map<String, int> matches = const {},
    Set<String> noMatch = const {},
  }) async {
    final res = await _send(
      'POST',
      '/paste/preview',
      body: _pasteBody(action, text, locationId, toLocationId, matches, noMatch),
    );
    return PastePreview.fromJson(res as Map<String, dynamic>);
  }

  Future<UploadResult> savePaste({
    required PasteAction action,
    required String text,
    int? locationId,
    int? toLocationId,
    Map<String, int> matches = const {},
    Set<String> noMatch = const {},
  }) async {
    final res = await _send(
      'POST',
      '/paste',
      body: _pasteBody(action, text, locationId, toLocationId, matches, noMatch),
    );
    return UploadResult.fromJson(res as Map<String, dynamic>);
  }

  Map<String, Object> _pasteBody(
    PasteAction action,
    String text,
    int? locationId,
    int? toLocationId,
    Map<String, int> matches,
    Set<String> noMatch,
  ) => {
    'action': action.name,
    'text': text,
    'location_id': ?locationId,
    'to_location_id': ?toLocationId,
    if (matches.isNotEmpty) 'matches': matches,
    if (noMatch.isNotEmpty) 'no_match': noMatch.toList(),
  };

  /// What sold on [date] (the shop's today when null), optionally at one location.
  Future<SalesReport> sales({String? date, int? locationId}) async {
    final res = await _send('GET', '/reports/sales', query: {'date': date, 'location_id': locationId?.toString()});
    return SalesReport.fromJson(res as Map<String, dynamic>);
  }

  // Exports

  /// Stock at one location, or at every location when [locationId] is null.
  Future<ExportFile> exportStock({int? locationId, required ExportFormat format}) => _download('/exports/stock', {
    'location_id': locationId?.toString(),
    'format': format.name,
  }, 'stock.${format.name}');

  /// Every item with its total stock.
  Future<ExportFile> exportItems({required ExportFormat format}) =>
      _download('/exports/items', {'format': format.name}, 'items.${format.name}');

  // Push notifications

  Future<void> registerDevice(String pushToken) async {
    await _send('POST', '/devices', body: {'token': pushToken, 'platform': 'android'});
  }

  Future<void> unregisterDevice(String pushToken) async {
    await _send('DELETE', '/devices/${Uri.encodeComponent(pushToken)}');
  }
}
