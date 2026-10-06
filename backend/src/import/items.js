// Bulk import of items (and optional starting stock) from a CSV or Excel file.
// Used by scripts/import-items.js. Reading and planning touch nothing; only
// applyPlan writes, in one transaction.
const fs = require('fs');
const path = require('path');
const { parse } = require('csv-parse/sync');
const ExcelJS = require('exceljs');
const { receiveIn } = require('../services/stock');

// Header names we recognise, compared after normalize().
const ALIASES = {
  name: ['name', 'item', 'itemname', 'items', 'product', 'productname', 'description', 'itemdescription', 'productdescription', 'article', 'particulars', 'itemdetails', 'details'],
  sku: ['sku', 'code', 'itemcode', 'productcode', 'barcode', 'itemno', 'itemnumber', 'partno', 'partnumber', 'ref', 'reference'],
  unit: ['unit', 'units', 'uom', 'unitofmeasure', 'measure'],
  // A plain quantity column means stock at the main shop.
  mainStock: ['qty', 'quantity', 'stock', 'count', 'onhand', 'qtyonhand', 'instock', 'openingstock', 'openingqty', 'balance', 'main', 'mainqty', 'mainstock'],
};

// Words around a location name in a stock column, e.g. "Kandy qty", "Stock - Galle".
const STOCK_WORDS = /^(qty|quantity|stock|count|onhand)|(qty|quantity|stock|count|onhand)$/;

function normalize(text) {
  return String(text ?? '').toLowerCase().replace(/[^a-z0-9]/g, '');
}

function cellText(value) {
  if (value === null || value === undefined) return '';
  return String(value).trim();
}

async function readTable(filePath, { sheet } = {}) {
  const ext = path.extname(filePath).toLowerCase();
  if (ext === '.csv' || ext === '.txt' || ext === '.tsv') {
    const rows = parse(fs.readFileSync(filePath), {
      bom: true,
      delimiter: [',', ';', '\t'],
      relax_column_count: true,
      relax_quotes: true,
      skip_empty_lines: false,
    });
    return rows.map((r) => r.map(cellText));
  }
  if (ext === '.xlsx') {
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.readFile(filePath);
    const ws = sheet ? workbook.getWorksheet(sheet) : workbook.worksheets[0];
    if (!ws) {
      const names = workbook.worksheets.map((w) => w.name).join(', ');
      throw new Error(`Sheet "${sheet}" not found. Sheets in this file: ${names}`);
    }
    const rows = [];
    for (let r = 1; r <= ws.rowCount; r++) {
      const row = ws.getRow(r);
      const cells = [];
      for (let c = 1; c <= ws.columnCount; c++) cells.push(cellText(row.getCell(c).text));
      rows.push(cells);
    }
    return rows;
  }
  if (ext === '.xls') throw new Error('Old .xls files are not supported. Open it in Excel and save as .xlsx or .csv.');
  throw new Error(`Unsupported file type "${ext}". Use .csv or .xlsx.`);
}

function isBlank(row) {
  return row.every((cell) => cell === '');
}

// The header is the first row (of the first 20) with a column we read as the
// item name, so title rows above the table are skipped.
function findHeaderRow(rows, overrides = {}) {
  const overrideHeaders = new Set(Object.entries(overrides).filter(([, f]) => f === 'name').map(([h]) => normalize(h)));
  for (let i = 0; i < Math.min(rows.length, 20); i++) {
    if (rows[i].some((cell) => ALIASES.name.includes(normalize(cell)) || overrideHeaders.has(normalize(cell)))) return i;
  }
  return -1;
}

function locationFor(header, locations) {
  const n = normalize(header);
  const bare = n.replace(STOCK_WORDS, '');
  return locations.find((l) => {
    const ln = normalize(l.name);
    return ln === n || ln === bare || (l.type === 'main' && ['main', 'mainshop'].includes(bare));
  });
}

// Works out what each column means. overrides maps a header (as written in
// the file) to "name", "sku", "unit", "ignore", "stock" (main shop) or
// "stock:<location name>".
function mapColumns(header, locations, overrides = {}) {
  const overrideByNorm = new Map(Object.entries(overrides).map(([h, f]) => [normalize(h), { header: h, field: f }]));
  const main = locations.find((l) => l.type === 'main');
  const mapping = { name: null, sku: null, unit: null, stock: [], ignored: [] };
  const stockSeen = new Set();
  const errors = [];

  const addStock = (index, location, headerText) => {
    if (stockSeen.has(location.id)) {
      mapping.ignored.push({ index, header: headerText, reason: `second stock column for ${location.name}` });
      return;
    }
    stockSeen.add(location.id);
    mapping.stock.push({ index, header: headerText, location });
  };

  header.forEach((headerText, index) => {
    const n = normalize(headerText);
    if (!n) return;
    const override = overrideByNorm.get(n)?.field;
    if (override !== undefined) {
      overrideByNorm.delete(n);
      if (override === 'ignore') {
        mapping.ignored.push({ index, header: headerText, reason: 'ignored with --map' });
      } else if (['name', 'sku', 'unit'].includes(override)) {
        mapping[override] = index;
      } else if (override === 'stock') {
        addStock(index, main, headerText);
      } else if (override.startsWith('stock:')) {
        const wanted = override.slice(6);
        const location = locations.find((l) => normalize(l.name) === normalize(wanted));
        if (location) addStock(index, location, headerText);
        else errors.push(`--map "${headerText}=${override}": no location called "${wanted}"`);
      } else {
        errors.push(`--map "${headerText}=${override}": use name, sku, unit, stock, stock:<location> or ignore`);
      }
      return;
    }
    for (const field of ['name', 'sku', 'unit']) {
      if (mapping[field] === null && ALIASES[field].includes(n)) {
        mapping[field] = index;
        return;
      }
    }
    if (ALIASES.mainStock.includes(n)) return addStock(index, main, headerText);
    const location = locationFor(headerText, locations);
    if (location) return addStock(index, location, headerText);
    mapping.ignored.push({ index, header: headerText, reason: 'not a known column or location' });
  });

  for (const { header: h } of overrideByNorm.values()) errors.push(`--map: no column called "${h}" in the file`);
  if (mapping.name === null) errors.push('No item name column found');
  return { mapping, errors };
}

// "1,200" -> 1200, "12.0" -> 12, "" -> 0. Returns null when it isn't a whole number >= 0.
function parseQuantity(text) {
  const cleaned = text.replace(/[\s,]/g, '');
  if (cleaned === '' || cleaned === '-') return 0;
  const n = Number(cleaned);
  return Number.isInteger(n) && n >= 0 ? n : null;
}

function itemKey(name, sku) {
  return sku ? `sku:${sku.toLowerCase()}` : `name:${name.toLowerCase()}`;
}

// Decides what happens to every row below the header. Nothing is dropped
// without a reason: each data row ends up in create or skipped.
function planImport(rows, headerIndex, mapping, existingItems) {
  const existing = new Map();
  for (const item of existingItems) {
    if (item.sku) existing.set(itemKey(item.name, item.sku), item);
    existing.set(itemKey(item.name, null), item);
  }
  const seen = new Map();
  const create = [];
  const skipped = [];
  let blankRows = 0;

  for (let i = headerIndex + 1; i < rows.length; i++) {
    const row = rows[i];
    const rowNumber = i + 1; // as shown in Excel
    if (isBlank(row)) {
      blankRows++;
      continue;
    }
    const get = (index) => (index === null ? '' : row[index] ?? '');
    const name = get(mapping.name).replace(/\s+/g, ' ');
    const sku = get(mapping.sku) || null;
    const unit = get(mapping.unit) || 'pcs';
    const label = name || sku || row.filter(Boolean).join(' | ');
    const skip = (reason) => skipped.push({ row: rowNumber, item: label, reason });

    if (!name) {
      skip('no item name');
      continue;
    }
    if (/^(grand\s*)?total$/i.test(name)) {
      skip('totals row');
      continue;
    }
    const stock = [];
    const bad = [];
    for (const col of mapping.stock) {
      const quantity = parseQuantity(get(col.index));
      if (quantity === null) bad.push(`${col.header} "${get(col.index)}"`);
      else if (quantity > 0) stock.push({ location: col.location, quantity });
    }
    if (bad.length) {
      skip(`quantity is not a whole number of 0 or more: ${bad.join(', ')}`);
      continue;
    }
    const key = itemKey(name, sku);
    const match = existing.get(key);
    if (match) {
      skip(`already in the app as "${match.name}"${match.sku ? ` (SKU ${match.sku})` : ''}${match.archived ? ', archived' : ''}`);
      continue;
    }
    if (seen.has(key)) {
      skip(`same ${sku ? `SKU ${sku}` : 'name'} as row ${seen.get(key)}`);
      continue;
    }
    seen.set(key, rowNumber);
    create.push({ row: rowNumber, name, sku, unit, stock });
  }
  return { create, skipped, blankRows };
}

async function loadContext(db) {
  const { rows: locations } = await db.query('SELECT id, name, type FROM locations WHERE NOT archived ORDER BY type = \'main\' DESC, name');
  const { rows: items } = await db.query('SELECT id, name, sku, archived FROM items');
  return { locations, items };
}

// Creates the planned items and records their starting stock as "receive"
// movements. All or nothing: any database error rolls the whole import back.
async function applyPlan(db, plan, note) {
  return db.withTransaction(async (client) => {
    let movements = 0;
    for (const entry of plan.create) {
      const { rows } = await client.query(
        'INSERT INTO items (name, sku, unit) VALUES ($1, $2, $3) RETURNING id',
        [entry.name, entry.sku, entry.unit],
      );
      for (const s of entry.stock) {
        await receiveIn(client, { itemId: rows[0].id, locationId: s.location.id, quantity: s.quantity, note });
        movements++;
      }
    }
    return { items: plan.create.length, movements };
  });
}

module.exports = { readTable, findHeaderRow, mapColumns, planImport, loadContext, applyPlan, normalize, parseQuantity };
