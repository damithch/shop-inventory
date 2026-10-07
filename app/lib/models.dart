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

/// Totals for a stock sheet, as in POST /uploads/preview.
class UploadSummary {
  UploadSummary({
    required this.newItems,
    required this.newStock,
    required this.changedItems,
    required this.sold,
    required this.received,
    required this.unchangedItems,
    required this.skippedRows,
    this.transferred = 0,
  });

  factory UploadSummary.fromJson(Map<String, dynamic> j) => UploadSummary(
    newItems: asInt(j['new_items']),
    newStock: asInt(j['new_stock']),
    changedItems: asInt(j['changed_items']),
    sold: asInt(j['sold']),
    received: asInt(j['received']),
    unchangedItems: asInt(j['unchanged_items']),
    skippedRows: asInt(j['skipped_rows']),
    transferred: asIntOrNull(j['transferred']) ?? 0,
  );

  final int newItems;
  final int newStock;
  final int changedItems;
  final int sold;
  final int received;
  final int unchangedItems;
  final int skippedRows;

  /// Units moved between locations, for a pasted transfer.
  final int transferred;
}

/// An item already in the app whose count the sheet changes.
class UploadChange {
  UploadChange({required this.itemName, required this.locationName, required this.from, required this.to});

  factory UploadChange.fromJson(Map<String, dynamic> j) => UploadChange(
    itemName: j['item_name'] as String,
    locationName: j['location_name'] as String,
    from: asInt(j['from']),
    to: asInt(j['to']),
  );

  final String itemName;
  final String locationName;
  final int from;
  final int to;

  bool get isSale => to < from;
}

/// An item the sheet adds to the app.
class UploadNewItem {
  UploadNewItem({
    required this.name,
    required this.unit,
    required this.stock,
    required this.similarTo,
    this.row = 0,
    this.similarIds = const [],
  });

  factory UploadNewItem.fromJson(Map<String, dynamic> j) => UploadNewItem(
    row: asIntOrNull(j['row']) ?? 0,
    name: j['name'] as String,
    unit: (j['unit'] as String?) ?? 'pcs',
    stock: {
      for (final s in (j['stock'] as List? ?? const []).cast<Map<String, dynamic>>())
        s['location_name'] as String: asInt(s['quantity']),
    },
    similarTo: ((j['similar_to'] as List?) ?? const []).cast<String>(),
    similarIds: [for (final id in (j['similar_ids'] as List?) ?? const []) asInt(id)],
  );

  /// Row number in the sheet, as Excel shows it.
  final int row;
  final String name;
  final String unit;

  /// Starting stock by location name.
  final Map<String, int> stock;

  /// Items already in the app with a similar name: maybe the same item.
  final List<String> similarTo;

  /// The ids of [similarTo], in the same order.
  final List<int> similarIds;
}

class SkippedRow {
  SkippedRow({required this.row, required this.item, required this.reason});

  factory SkippedRow.fromJson(Map<String, dynamic> j) =>
      SkippedRow(row: asInt(j['row']), item: j['item'] as String, reason: j['reason'] as String);

  final int row;
  final String item;
  final String reason;
}

class UploadPreview {
  UploadPreview({
    required this.filename,
    required this.notes,
    required this.stockColumns,
    required this.ignoredColumns,
    required this.summary,
    required this.newItems,
    required this.changes,
    required this.skipped,
  });

  factory UploadPreview.fromJson(Map<String, dynamic> j) {
    final columns = j['columns'] as Map<String, dynamic>;
    return UploadPreview(
      filename: j['filename'] as String,
      notes: ((j['notes'] as List?) ?? const []).cast<String>(),
      stockColumns: {
        for (final c in (columns['stock'] as List).cast<Map<String, dynamic>>())
          c['header'] as String: c['location_name'] as String,
      },
      ignoredColumns: (columns['ignored'] as List).cast<String>(),
      summary: UploadSummary.fromJson(j['summary'] as Map<String, dynamic>),
      newItems: (j['new_items'] as List).map((e) => UploadNewItem.fromJson(e as Map<String, dynamic>)).toList(),
      changes: (j['changes'] as List).map((e) => UploadChange.fromJson(e as Map<String, dynamic>)).toList(),
      skipped: (j['skipped'] as List).map((e) => SkippedRow.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }

  final String filename;
  final List<String> notes;

  /// Which location each stock column in the sheet is for, by column header.
  final Map<String, String> stockColumns;
  final List<String> ignoredColumns;
  final UploadSummary summary;
  final List<UploadNewItem> newItems;
  final List<UploadChange> changes;
  final List<SkippedRow> skipped;
}

/// A saved stock sheet, as in POST /uploads and GET /uploads.
class UploadResult {
  UploadResult({
    required this.id,
    required this.filename,
    required this.summary,
    this.createdAt,
    this.alerts = const [],
  });

  factory UploadResult.fromJson(Map<String, dynamic> j) => UploadResult(
    id: asInt(j['id']),
    filename: j['filename'] as String,
    summary: UploadSummary.fromJson(j['summary'] as Map<String, dynamic>),
    createdAt: asDate(j['created_at']),
    alerts: StockAlert.listFrom(j['alerts']),
  );

  final int id;
  final String filename;
  final UploadSummary summary;
  final DateTime? createdAt;
  final List<StockAlert> alerts;
}

class SaleLine {
  SaleLine({
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.locationName,
    required this.quantity,
  });

  factory SaleLine.fromJson(Map<String, dynamic> j) => SaleLine(
    itemId: asInt(j['item_id']),
    itemName: j['item_name'] as String,
    unit: (j['unit'] as String?) ?? 'pcs',
    locationName: j['location_name'] as String,
    quantity: asInt(j['quantity']),
  );

  final int itemId;
  final String itemName;
  final String unit;
  final String locationName;
  final int quantity;
}

/// What sold on one day, as in GET /reports/sales.
class SalesReport {
  SalesReport({required this.date, required this.total, required this.items});

  factory SalesReport.fromJson(Map<String, dynamic> j) => SalesReport(
    date: j['date'] as String,
    total: asInt(j['total']),
    items: (j['items'] as List).map((e) => SaleLine.fromJson(e as Map<String, dynamic>)).toList(),
  );

  /// YYYY-MM-DD in the shop's time zone.
  final String date;
  final int total;
  final List<SaleLine> items;
}

/// What a pasted list is: purchases received, a transfer, or sales.
enum PasteAction {
  receive('Purchase'),
  transfer('Transfer'),
  sale('Sale');

  const PasteAction(this.label);

  final String label;
}

/// One item from a pasted list (lines for the same item added together).
class PasteLine {
  PasteLine({
    required this.lines,
    required this.itemName,
    required this.quantity,
    required this.newItem,
    this.similarTo = const [],
  });

  factory PasteLine.fromJson(Map<String, dynamic> j) => PasteLine(
    lines: [for (final l in j['lines'] as List) asInt(l)],
    itemName: j['item_name'] as String,
    quantity: asInt(j['quantity']),
    newItem: j['new_item'] == true,
    similarTo: [for (final s in (j['similar_to'] as List?) ?? const []) s as String],
  );

  final List<int> lines;
  final String itemName;
  final int quantity;
  final bool newItem;
  final List<String> similarTo;
}

class PastePreview {
  PastePreview({required this.lines, required this.skipped, required this.summary, this.fromName, this.toName});

  factory PastePreview.fromJson(Map<String, dynamic> j) => PastePreview(
    lines: [for (final l in j['lines'] as List) PasteLine.fromJson(l as Map<String, dynamic>)],
    skipped: [
      for (final s in j['skipped'] as List)
        SkippedRow(
          row: asInt((s as Map<String, dynamic>)['line']),
          item: s['text'] as String,
          reason: s['reason'] as String,
        ),
    ],
    summary: UploadSummary.fromJson(j['summary'] as Map<String, dynamic>),
    fromName: (j['from'] as Map<String, dynamic>?)?['location_name'] as String?,
    toName: (j['to'] as Map<String, dynamic>?)?['location_name'] as String?,
  );

  final List<PasteLine> lines;
  final List<SkippedRow> skipped;
  final UploadSummary summary;
  final String? fromName;
  final String? toName;
}
