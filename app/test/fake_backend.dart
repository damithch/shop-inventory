import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A tiny in-memory stand-in for the backend API, enough for the app's flows.
/// It mirrors the response shapes documented in backend/README.md.
class FakeBackend {
  FakeBackend({this.password = 'secret'});

  final String password;
  int defaultThreshold = 3;
  final requests = <String>[];

  final locations = <Map<String, dynamic>>[
    {'id': 1, 'name': 'Main Shop', 'type': 'main', 'archived': false},
    {'id': 2, 'name': 'Kandy', 'type': 'branch', 'archived': false},
  ];
  final items = <Map<String, dynamic>>[
    {'id': 10, 'name': 'Rice 5kg', 'sku': 'R5', 'unit': 'bag', 'archived': false},
  ];

  /// quantity by "item:location"
  final stock = <String, int>{'10:1': 8, '10:2': 4};
  final alerts = <Map<String, dynamic>>[];

  http.Client get client => MockClient(_handle);

  int _qty(int item, int loc) => stock['$item:$loc'] ?? 0;

  Map<String, dynamic> _loc(int id) => locations.firstWhere((l) => l['id'] == id);
  Map<String, dynamic> _item(int id) => items.firstWhere((i) => i['id'] == id);

  http.Response _json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  http.Response _error(int status, String message) => _json({'error': message}, status);

  Map<String, dynamic>? _change(int item, int loc, int delta) {
    final before = _qty(item, loc);
    stock['$item:$loc'] = before + delta;
    final after = before + delta;
    if (before > defaultThreshold && after <= defaultThreshold) {
      final alert = {
        'itemId': item,
        'itemName': _item(item)['name'],
        'locationId': loc,
        'locationName': _loc(loc)['name'],
        'locationType': _loc(loc)['type'],
        'quantity': after,
        'threshold': defaultThreshold,
      };
      alerts.add(alert);
      return alert;
    }
    return null;
  }

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    requests.add('${req.method} $path');
    final body = req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;

    if (req.method == 'POST' && path == '/auth/login') {
      return body['password'] == password
          ? _json({'token': 'tok', 'expires_in': '30d'})
          : _error(401, 'Wrong password');
    }
    if (req.headers['Authorization'] != 'Bearer tok') return _error(401, 'Sign in required');

    if (req.method == 'GET' && path == '/locations') {
      return _json([
        for (final l in locations)
          {
            ...l,
            'item_count': items.where((i) => _qty(i['id'] as int, l['id'] as int) > 0).length,
            'total_units': items.fold<int>(0, (s, i) => s + _qty(i['id'] as int, l['id'] as int)),
          },
      ]);
    }
    if (req.method == 'POST' && path == '/locations') {
      final loc = {'id': locations.length + 1, 'name': body['name'], 'type': 'branch', 'archived': false};
      locations.add(loc);
      return _json(loc, 201);
    }
    final locStock = RegExp(r'^/locations/(\d+)/stock$').firstMatch(path);
    if (req.method == 'GET' && locStock != null) {
      final id = int.parse(locStock.group(1)!);
      return _json({
        'location': _loc(id),
        'items': [
          for (final i in items)
            {
              'item_id': i['id'],
              'name': i['name'],
              'sku': i['sku'],
              'unit': i['unit'],
              'quantity': _qty(i['id'] as int, id),
              'threshold': defaultThreshold,
              'uses_default': true,
              'low': stock.containsKey('${i['id']}:$id') && _qty(i['id'] as int, id) <= defaultThreshold,
            },
        ],
      });
    }
    if (req.method == 'GET' && path == '/items') {
      return _json([
        for (final i in items)
          {
            ...i,
            'main_quantity': _qty(i['id'] as int, 1),
            'total_quantity': locations.fold<int>(0, (s, l) => s + _qty(i['id'] as int, l['id'] as int)),
          },
      ]);
    }
    if (req.method == 'POST' && path == '/items') {
      final item = {'id': 10 + items.length, 'name': body['name'], 'sku': body['sku'], 'unit': body['unit'] ?? 'pcs'};
      items.add(item);
      return _json(item, 201);
    }
    final itemMatch = RegExp(r'^/items/(\d+)$').firstMatch(path);
    if (req.method == 'GET' && itemMatch != null) {
      final id = int.parse(itemMatch.group(1)!);
      return _json({
        ..._item(id),
        'stock': [
          for (final l in locations)
            {
              'location_id': l['id'],
              'location_name': l['name'],
              'location_type': l['type'],
              'quantity': _qty(id, l['id'] as int),
              'threshold': defaultThreshold,
              'uses_default': true,
              'low': _qty(id, l['id'] as int) <= defaultThreshold,
            },
        ],
      });
    }
    if (req.method == 'POST' && path == '/stock/receive') {
      final item = body['item_id'] as int;
      final loc = (body['location_id'] as int?) ?? 1;
      _change(item, loc, body['quantity'] as int);
      return _json({'movement': {}, 'levels': [], 'alerts': []}, 201);
    }
    if (req.method == 'POST' && path == '/stock/transfer') {
      final item = body['item_id'] as int;
      final from = (body['from_location_id'] as int?) ?? 1;
      final to = body['to_location_id'] as int;
      final qty = body['quantity'] as int;
      if (_qty(item, from) < qty) {
        return _error(409, 'Not enough "${_item(item)['name']}" at ${_loc(from)['name']}');
      }
      final alert = _change(item, from, -qty);
      _change(item, to, qty);
      return _json({
        'movement': {},
        'levels': [],
        'alerts': [?alert],
      }, 201);
    }
    if (req.method == 'POST' && path == '/stock/sale') {
      final item = body['item_id'] as int;
      final loc = body['location_id'] as int;
      final qty = body['quantity'] as int;
      if (_qty(item, loc) < qty) return _error(409, 'Not enough "${_item(item)['name']}" at ${_loc(loc)['name']}');
      final alert = _change(item, loc, -qty);
      return _json({
        'movement': {},
        'levels': [],
        'alerts': [?alert],
      }, 201);
    }
    if (req.method == 'GET' && path == '/stock/movements') return _json([]);
    if (req.method == 'GET' && path == '/stock/low') {
      return _json([
        for (final e in stock.entries)
          if (e.value <= defaultThreshold)
            () {
              final [item, loc] = e.key.split(':').map(int.parse).toList();
              return {
                'item_id': item,
                'item_name': _item(item)['name'],
                'unit': _item(item)['unit'],
                'location_id': loc,
                'location_name': _loc(loc)['name'],
                'location_type': _loc(loc)['type'],
                'quantity': e.value,
                'threshold': defaultThreshold,
              };
            }(),
      ]);
    }
    if (req.method == 'GET' && path == '/settings') return _json({'default_threshold': defaultThreshold});
    if (req.method == 'PUT' && path == '/settings') {
      defaultThreshold = body['default_threshold'] as int;
      return _json({'default_threshold': defaultThreshold});
    }
    return _error(404, 'Not found');
  }
}
