import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A tiny in-memory stand-in for the backend API, enough for the app's flows.
/// It mirrors the response shapes documented in backend/README.md.
class FakeBackend {
  FakeBackend({this.password = 'secret'});

  String password;

  /// The token login hands out; changing the password replaces it.
  String token = 'tok';
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

  /// Push tokens registered with POST /devices.
  final devices = <String>{};

  /// Sales for GET /reports/sales: item, location, quantity and unit price.
  final sales = <({int item, int loc, int qty, double? price})>[];

  /// Query of each PDF report downloaded.
  final pdfs = <Map<String, String>>[];
  final uploads = <Map<String, dynamic>>[];

  /// Resets and deletes done for real, by path.
  final resets = <String>[];

  /// Sheet names picked for an item in an upload preview: name -> item id.
  final aliases = <String, int>{};

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
    final isJson = req.headers['Content-Type']?.startsWith('application/json') ?? false;
    final body = !isJson || req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;

    if (req.method == 'POST' && path == '/auth/login') {
      return body['password'] == password
          ? _json({'token': token, 'expires_in': '30d'})
          : _error(401, 'Wrong password');
    }
    if (req.headers['Authorization'] != 'Bearer $token') return _error(401, 'Sign in required');

    if (req.method == 'POST' && path == '/auth/password') {
      if (body['current_password'] != password) return _error(400, 'The current password is wrong');
      password = body['new_password'] as String;
      token = '${token}2';
      return _json({'token': token, 'expires_in': '30d'});
    }
    if (req.method == 'GET' && path == '/reports/sales/pdf') {
      final q = req.url.queryParameters;
      pdfs.add(q);
      final name = 'sales-${q['location_id'] ?? 'all'}-${q['date'] ?? '2026-10-06'}.pdf';
      return http.Response.bytes(
        utf8.encode('%PDF-1.7 fake'),
        200,
        headers: {'content-type': 'application/pdf', 'content-disposition': 'attachment; filename="$name"'},
      );
    }
    if (req.method == 'GET' && path.startsWith('/exports/')) {
      final format = req.url.queryParameters['format'];
      final where = req.url.queryParameters['location_id'] ?? 'all';
      final name = path == '/exports/items' ? 'items.$format' : 'stock-$where.$format';
      return http.Response.bytes(
        utf8.encode('Item name,Qty\r\nRice 5kg,8\r\n'),
        200,
        headers: {'content-type': 'text/csv; charset=utf-8', 'content-disposition': 'attachment; filename="$name"'},
      );
    }

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
    if (req.method == 'POST' && path.startsWith('/reset/')) return _reset(path, body);
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
      sales.add((item: item, loc: loc, qty: qty, price: null));
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
    if (req.method == 'POST' && (path == '/uploads/preview' || path == '/uploads')) {
      return _upload(req, save: path == '/uploads');
    }
    if (req.method == 'POST' && (path == '/paste/preview' || path == '/paste')) {
      return _paste(body, save: path == '/paste');
    }
    if (req.method == 'GET' && path == '/uploads') return _json(uploads.reversed.toList());
    if (req.method == 'GET' && path == '/reports/sales') {
      return _json({
        'date': req.url.queryParameters['date'] ?? '2026-10-06',
        'total': sales.fold<int>(0, (t, s) => t + s.qty),
        'total_amount': sales.fold<double>(0, (t, s) => t + s.qty * (s.price ?? 0)),
        'unpriced_units': sales.where((s) => s.price == null).fold<int>(0, (t, s) => t + s.qty),
        'items': [
          for (final s in sales)
            {
              'item_id': s.item,
              'item_name': _item(s.item)['name'],
              'unit': _item(s.item)['unit'],
              'location_id': s.loc,
              'location_name': _loc(s.loc)['name'],
              'quantity': s.qty,
              'amount': s.price == null ? null : s.qty * s.price!,
            },
        ],
      });
    }
    if (req.method == 'GET' && path == '/settings') return _json({'default_threshold': defaultThreshold});
    if (req.method == 'PUT' && path == '/settings') {
      defaultThreshold = body['default_threshold'] as int;
      return _json({'default_threshold': defaultThreshold});
    }
    if (req.method == 'POST' && path == '/devices') {
      devices.add(body['token'] as String);
      return _json({'token': body['token'], 'platform': body['platform']}, 201);
    }
    if (req.method == 'DELETE' && path.startsWith('/devices/')) {
      devices.remove(Uri.decodeComponent(path.substring('/devices/'.length)));
      return http.Response('', 204);
    }
    return _error(404, 'Not found');
  }

  /// A stock sheet as CSV lines of "name,count" under a header row.
  http.Response _upload(http.Request req, {required bool save}) {
    final loc = int.tryParse(req.url.queryParameters['location_id'] ?? '') ?? 1;
    final rows = const LineSplitter().convert(utf8.decode(req.bodyBytes)).skip(1).map((l) => l.split(',')).toList();
    final matches = {
      for (final pair in (req.url.queryParameters['matches'] ?? '').split(',').where((p) => p.isNotEmpty))
        int.parse(pair.split(':')[0]): int.parse(pair.split(':')[1]),
    };
    final newItems = <Map<String, dynamic>>[];
    final changes = <Map<String, dynamic>>[];
    var unchanged = 0;
    var sold = 0;
    var received = 0;
    for (var r = 0; r < rows.length; r++) {
      final [name, count] = rows[r];
      final row = r + 2;
      final qty = int.parse(count);
      final matchedId = matches[row] ?? aliases[name];
      final existing = matchedId != null ? _item(matchedId) : items.where((i) => i['name'] == name).firstOrNull;
      if (save && matches.containsKey(row)) aliases[name] = matches[row]!;
      if (existing == null) {
        final similar = [
          for (final i in items)
            if ((i['name'] as String).contains(name)) i,
        ];
        newItems.add({
          'row': row,
          'name': name,
          'sku': null,
          'unit': 'pcs',
          'similar_to': [for (final i in similar) i['name']],
          'similar_ids': [for (final i in similar) i['id']],
          'stock': [
            {'location_id': loc, 'location_name': _loc(loc)['name'], 'quantity': qty},
          ],
        });
        received += qty;
        if (save) {
          items.add({'id': 10 + items.length, 'name': name, 'sku': null, 'unit': 'pcs'});
          _change(items.last['id'] as int, loc, qty);
        }
        continue;
      }
      final id = existing['id'] as int;
      final from = _qty(id, loc);
      if (from == qty) {
        unchanged++;
        continue;
      }
      changes.add({
        'row': row,
        'item_id': id,
        'item_name': existing['name'],
        'location_id': loc,
        'location_name': _loc(loc)['name'],
        'from': from,
        'to': qty,
      });
      if (qty < from) {
        sold += from - qty;
        if (save) sales.add((item: id, loc: loc, qty: from - qty, price: null));
      } else {
        received += qty - from;
      }
      if (save) _change(id, loc, qty - from);
    }
    final summary = {
      'new_items': newItems.length,
      'new_stock': newItems.fold<int>(0, (t, i) => t + ((i['stock'] as List).first['quantity'] as int)),
      'changed_items': changes.length,
      'sold': sold,
      'received': received,
      'unchanged_items': unchanged,
      'skipped_rows': 0,
    };
    final filename = req.url.queryParameters['filename'];
    if (save) {
      final upload = {'id': uploads.length + 1, 'filename': filename, 'summary': summary, 'alerts': <Object>[]};
      uploads.add(upload);
      return _json(upload, 201);
    }
    return _json({
      'filename': filename,
      'notes': <String>[],
      'header_row': 1,
      'columns': {
        'stock': [
          {'header': 'Qty', 'location_id': loc, 'location_name': _loc(loc)['name']},
        ],
        'ignored': <String>[],
      },
      'summary': summary,
      'new_items': newItems,
      'changes': changes,
      'skipped': <Object>[],
    });
  }

  /// Pasted lists: "name qty" per line, names matched exactly (ignoring case).
  http.Response _paste(Map<String, dynamic> body, {required bool save}) {
    final action = body['action'] as String;
    final locationId = body['location_id'] as int?;
    final from = action == 'receive' ? null : (locationId ?? 1);
    final to = action == 'receive' ? (locationId ?? 1) : body['to_location_id'] as int?;
    if (action == 'transfer' && to == null) return _error(400, 'Choose where the stock is going');
    final lines = <Map<String, dynamic>>[];
    final skipped = <Map<String, dynamic>>[];
    final prices = (body['prices'] as Map<String, dynamic>?) ?? const {};
    final rows = (body['text'] as String).split('\n');
    for (var i = 0; i < rows.length; i++) {
      final m = RegExp(r'^(.*\S)\s+(\d+)$').firstMatch(rows[i].trim());
      if (m == null) {
        if (rows[i].trim().isNotEmpty) {
          skipped.add({'line': i + 1, 'text': rows[i], 'reason': 'no quantity on this line'});
        }
        continue;
      }
      final name = m[1]!;
      final qty = int.parse(m[2]!);
      final picked = (body['matches'] as Map<String, dynamic>?)?[name] as int?;
      if (save && picked != null) aliases[name] = picked;
      final known = picked ?? aliases[name];
      final exact = known != null
          ? _item(known)
          : items.where((it) => (it['name'] as String).toLowerCase() == name.toLowerCase()).firstOrNull;
      // A name that is part of exactly one item's name matches it by itself.
      final containing = [
        for (final it in items)
          if ((' ${(it['name'] as String).toLowerCase()} ').contains(' ${name.toLowerCase()} ')) it,
      ];
      final refused = ((body['no_match'] as List?) ?? const []).contains(name);
      final auto = exact == null && !refused && containing.length == 1 ? containing.single : null;
      final item = exact ?? auto;
      if (item == null && action != 'receive') {
        final similar = [
          for (final it in items)
            if ((it['name'] as String).toLowerCase().contains(name.toLowerCase())) it,
        ];
        skipped.add({
          'line': i + 1,
          'text': rows[i],
          'reason': 'not in the app',
          'name': name,
          'similar_to': [for (final it in similar) it['name']],
          'similar_ids': [for (final it in similar) it['id']],
        });
      } else if (item != null && from != null && _qty(item['id'] as int, from) < qty) {
        skipped.add({
          'line': i + 1,
          'text': rows[i],
          'reason': 'only ${_qty(item['id'] as int, from)} at ${_loc(from)['name']}, $qty asked for',
        });
      } else {
        lines.add({
          'lines': [i + 1],
          'name': name,
          'quantity': qty,
          'item_id': item?['id'],
          'item_name': item?['name'] ?? name,
          'new_item': item == null,
          'auto_matched': auto != null,
          'similar_to': <String>[],
          if (action == 'sale') 'price': prices.containsKey('${item!['id']}') ? prices['${item['id']}'] : item['price'],
        });
      }
    }
    final units = lines.fold<int>(0, (t, l) => t + (l['quantity'] as int));
    final summary = {
      'kind': action,
      'new_items': lines.where((l) => l['new_item'] == true).length,
      'new_stock': 0,
      'changed_items': lines.where((l) => l['new_item'] != true).length,
      'received': action == 'receive' ? units : 0,
      'transferred': action == 'transfer' ? units : 0,
      'sold': action == 'sale' ? units : 0,
      'unchanged_items': 0,
      'skipped_rows': skipped.length,
    };
    Map<String, dynamic>? place(int? id) => id == null ? null : {'location_id': id, 'location_name': _loc(id)['name']};
    if (!save) {
      return _json({
        'action': action,
        'from': place(from),
        'to': place(to),
        'lines': lines,
        'skipped': skipped,
        'summary': summary,
      });
    }
    final raised = <Map<String, dynamic>>[];
    for (final l in lines) {
      var id = l['item_id'] as int?;
      if (id == null) {
        id = 100 + items.length;
        items.add({'id': id, 'name': l['name'], 'sku': null, 'unit': 'pcs', 'archived': false});
      }
      final qty = l['quantity'] as int;
      if (from != null) {
        final alert = _change(id, from, -qty);
        if (alert != null) raised.add(alert);
      }
      if (to != null) _change(id, to, qty);
      if (action == 'sale') {
        final price = (l['price'] as num?)?.toDouble();
        sales.add((item: id, loc: from!, qty: qty, price: price));
        if (prices.containsKey('$id')) _item(id)['price'] = price;
      }
    }
    final upload = {
      'id': uploads.length + 1,
      'filename': 'Pasted ${action == 'receive' ? 'purchase' : action}',
      'summary': summary,
      'created_at': '2026-10-06T12:00:00Z',
    };
    uploads.add(upload);
    return _json({...upload, 'alerts': raised}, 201);
  }

  /// Reset and delete: zeroes stock and drops deleted items and branches.
  http.Response _reset(String path, Map<String, dynamic> body) {
    if (body['password'] != password) return _error(403, 'The password is wrong');
    final dryRun = body['dry_run'] == true;
    bool Function(String key) where;
    var deleted = <Map<String, dynamic>>[];
    switch (path) {
      case '/reset/stock':
        final loc = body['location_id'];
        where = (key) => loc == null || key.endsWith(':$loc');
      case '/reset/delete-item':
        where = (key) => key.startsWith('${body['item_id']}:');
        deleted = items.where((i) => i['id'] == body['item_id']).toList();
      case '/reset/delete-all-items':
        where = (_) => true;
        deleted = [...items];
      case '/reset/delete-branch':
        if (_loc(body['location_id'] as int)['type'] == 'main') return _error(400, 'The main shop cannot be deleted');
        where = (key) => key.endsWith(':${body['location_id']}');
      default:
        return _error(404, 'Not found');
    }
    final keys = stock.keys.where((k) => where(k) && stock[k]! > 0).toList();
    final result = {
      'items': keys.map((k) => k.split(':').first).toSet().length,
      'units': keys.fold<int>(0, (s, k) => s + stock[k]!),
      if (path.contains('item')) 'deleted_items': deleted.length,
      'dry_run': dryRun,
    };
    if (!dryRun) {
      resets.add(path);
      for (final k in keys) {
        stock[k] = 0;
      }
      items.removeWhere(deleted.contains);
      if (path == '/reset/delete-branch') locations.removeWhere((l) => l['id'] == body['location_id']);
    }
    return _json(result);
  }
}
