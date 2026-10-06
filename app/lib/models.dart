// Data returned by the inventory API. Field names follow backend/README.md.

int asInt(Object? v) => v is num ? v.toInt() : int.parse(v.toString());
int? asIntOrNull(Object? v) => v == null ? null : asInt(v);
DateTime? asDate(Object? v) => v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

class Location {
  Location({
    required this.id,
    required this.name,
    required this.type,
    this.archived = false,
    this.itemCount = 0,
    this.totalUnits = 0,
  });

  factory Location.fromJson(Map<String, dynamic> j) => Location(
    id: asInt(j['id']),
    name: j['name'] as String,
    type: j['type'] as String,
    archived: j['archived'] == true,
    itemCount: asIntOrNull(j['item_count']) ?? 0,
    totalUnits: asIntOrNull(j['total_units']) ?? 0,
  );

  final int id;
  final String name;
  final String type;
  final bool archived;
  final int itemCount;
  final int totalUnits;

  bool get isMain => type == 'main';
}

class Item {
  Item({
    required this.id,
    required this.name,
    this.sku,
    this.unit = 'pcs',
    this.mainQuantity = 0,
    this.totalQuantity = 0,
  });

  factory Item.fromJson(Map<String, dynamic> j) => Item(
    id: asInt(j['id']),
    name: j['name'] as String,
    sku: j['sku'] as String?,
    unit: (j['unit'] as String?) ?? 'pcs',
    mainQuantity: asIntOrNull(j['main_quantity']) ?? 0,
    totalQuantity: asIntOrNull(j['total_quantity']) ?? 0,
  );

  final int id;
  final String name;
  final String? sku;
  final String unit;
  final int mainQuantity;
  final int totalQuantity;
}

/// One item's count at one location, as in GET /locations/:id/stock.
class StockLine {
  StockLine({
    required this.itemId,
    required this.name,
    this.sku,
    required this.unit,
    required this.quantity,
    required this.threshold,
    required this.usesDefault,
    required this.low,
  });

  factory StockLine.fromJson(Map<String, dynamic> j) => StockLine(
    itemId: asInt(j['item_id']),
    name: j['name'] as String,
    sku: j['sku'] as String?,
    unit: (j['unit'] as String?) ?? 'pcs',
    quantity: asInt(j['quantity']),
    threshold: asInt(j['threshold']),
    usesDefault: j['uses_default'] == true,
    low: j['low'] == true,
  );

  final int itemId;
  final String name;
  final String? sku;
  final String unit;
  final int quantity;
  final int threshold;
  final bool usesDefault;
  final bool low;
}

class LocationStock {
  LocationStock({required this.location, required this.items});

  factory LocationStock.fromJson(Map<String, dynamic> j) => LocationStock(
    location: Location.fromJson(j['location'] as Map<String, dynamic>),
    items: (j['items'] as List).map((e) => StockLine.fromJson(e as Map<String, dynamic>)).toList(),
  );

  final Location location;
  final List<StockLine> items;
}

/// One location's count for an item, as in GET /items/:id.
class ItemLocationStock {
  ItemLocationStock({
    required this.locationId,
    required this.locationName,
    required this.locationType,
    required this.quantity,
    required this.threshold,
    required this.usesDefault,
    required this.low,
  });

  factory ItemLocationStock.fromJson(Map<String, dynamic> j) => ItemLocationStock(
    locationId: asInt(j['location_id']),
    locationName: j['location_name'] as String,
    locationType: j['location_type'] as String,
    quantity: asInt(j['quantity']),
    threshold: asInt(j['threshold']),
    usesDefault: j['uses_default'] == true,
    low: j['low'] == true,
  );

  final int locationId;
  final String locationName;
  final String locationType;
  final int quantity;
  final int threshold;
  final bool usesDefault;
  final bool low;

  bool get isMain => locationType == 'main';
}

class ItemDetail {
  ItemDetail({required this.item, required this.stock});

  factory ItemDetail.fromJson(Map<String, dynamic> j) => ItemDetail(
    item: Item.fromJson(j),
    stock: (j['stock'] as List).map((e) => ItemLocationStock.fromJson(e as Map<String, dynamic>)).toList(),
  );

  final Item item;
  final List<ItemLocationStock> stock;
}

/// A low-stock alert raised by a stock change. The API sends these in camelCase.
class StockAlert {
  StockAlert({required this.itemName, required this.locationName, required this.quantity, required this.threshold});

  factory StockAlert.fromJson(Map<String, dynamic> j) => StockAlert(
    itemName: j['itemName'] as String,
    locationName: j['locationName'] as String,
    quantity: asInt(j['quantity']),
    threshold: asInt(j['threshold']),
  );

  static List<StockAlert> listFrom(Object? v) =>
      v is List ? v.map((e) => StockAlert.fromJson(e as Map<String, dynamic>)).toList() : [];

  final String itemName;
  final String locationName;
  final int quantity;
  final int threshold;

  String get message => '$itemName is low at $locationName: $quantity left (alert level $threshold)';
}

class StockResult {
  StockResult({required this.alerts});

  factory StockResult.fromJson(Map<String, dynamic> j) => StockResult(alerts: StockAlert.listFrom(j['alerts']));

  final List<StockAlert> alerts;
}

class LowStockEntry {
  LowStockEntry({
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.locationId,
    required this.locationName,
    required this.locationType,
    required this.quantity,
    required this.threshold,
  });

  factory LowStockEntry.fromJson(Map<String, dynamic> j) => LowStockEntry(
    itemId: asInt(j['item_id']),
    itemName: j['item_name'] as String,
    unit: (j['unit'] as String?) ?? 'pcs',
    locationId: asInt(j['location_id']),
    locationName: j['location_name'] as String,
    locationType: j['location_type'] as String,
    quantity: asInt(j['quantity']),
    threshold: asInt(j['threshold']),
  );

  final int itemId;
  final String itemName;
  final String unit;
  final int locationId;
  final String locationName;
  final String locationType;
  final int quantity;
  final int threshold;
}

class Movement {
  Movement({
    required this.id,
    required this.type,
    required this.itemName,
    required this.quantity,
    this.fromLocationName,
    this.toLocationName,
    this.note,
    this.createdAt,
  });

  factory Movement.fromJson(Map<String, dynamic> j) => Movement(
    id: asInt(j['id']),
    type: j['type'] as String,
    itemName: j['item_name'] as String,
    quantity: asInt(j['quantity']),
    fromLocationName: j['from_location_name'] as String?,
    toLocationName: j['to_location_name'] as String?,
    note: j['note'] as String?,
    createdAt: asDate(j['created_at']),
  );

  final int id;
  final String type;
  final String itemName;
  final int quantity;
  final String? fromLocationName;
  final String? toLocationName;
  final String? note;
  final DateTime? createdAt;

  String get description {
    switch (type) {
      case 'receive':
        return 'Received $quantity at $toLocationName';
      case 'transfer':
        return 'Moved $quantity from $fromLocationName to $toLocationName';
      case 'sale':
        return 'Sold $quantity at $fromLocationName';
      case 'adjust':
        return toLocationName != null
            ? 'Count corrected +$quantity at $toLocationName'
            : 'Count corrected -$quantity at $fromLocationName';
      default:
        return '$type $quantity';
    }
  }
}

class AlertRecord {
  AlertRecord({
    required this.id,
    required this.itemName,
    required this.locationName,
    required this.quantity,
    required this.threshold,
    this.createdAt,
  });

  factory AlertRecord.fromJson(Map<String, dynamic> j) => AlertRecord(
    id: asInt(j['id']),
    itemName: j['item_name'] as String,
    locationName: j['location_name'] as String,
    quantity: asInt(j['quantity']),
    threshold: asInt(j['threshold']),
    createdAt: asDate(j['created_at']),
  );

  final int id;
  final String itemName;
  final String locationName;
  final int quantity;
  final int threshold;
  final DateTime? createdAt;
}
