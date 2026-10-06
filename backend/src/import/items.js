// Reads an item list or stock sheet (CSV or Excel) and turns it into items and
// stock. Used by scripts/import-items.js and the /uploads API. Reading and
// planning touch nothing; only applyPlan writes, in one transaction.
const fs = require('fs');
const path = require('path');
const { parse } = require('csv-parse/sync');
const ExcelJS = require('exceljs');
const { receiveIn, saleIn } = require('../services/stock');

// Header names we recognise, compared after normalize().
const ALIASES = {
  name: ['name', 'item', 'itemname', 'items', 'product', 'productname', 'description', 'itemdescription', 'productdescription', 'article', 'particulars', 'itemdetails', 'details'],
  sku: ['sku', 'code', 'itemcode', 'productcode', 'barcode', 'itemno', 'itemnumber', 'partno', 'partnumber', 'ref', 'reference'],
  unit: ['unit', 'units', 'uom', 'unitofmeasure', 'measure'],
  // A plain quantity column: stock at the main shop, or the chosen location.
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
  return readTableBuffer(fs.readFileSync(filePath), path.extname(filePath), { sheet });
}

async function readTableBuffer(buffer, ext, { sheet } = {}) {
  ext = ext.toLowerCase();
  if (ext === '.csv' || ext === '.txt' || ext === '.tsv') {
    const rows = parse(buffer, {
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
    try {
      await workbook.xlsx.load(buffer);
    } catch {
      throw new Error('Could not open this file as an Excel (.xlsx) workbook');
    }
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

const isWholeNumber = (cell) => /^-?[\d,]+(\.0+)?$/.test(cell.replace(/\s/g, ''));
const columnLetter = (index) => String.fromCharCode(65 + index);

// For a sheet with no header row (just names and counts): the column with the
// most text is the item name and the column with the most whole numbers is
// the quantity. Returns rows with a header written into the row above the
// data, or null when the sheet doesn't look like that.
function guessHeader(rows) {
  const width = Math.max(0, ...rows.map((r) => r.length));
  const text = Array(width).fill(0);
  const nums = Array(width).fill(0);
  for (const row of rows) {
    row.forEach((cell, c) => {
      if (!cell) return;
      if (isWholeNumber(cell)) nums[c]++;
      else text[c]++;
    });
  }
  const nameCol = text.indexOf(Math.max(...text));
  const qtyCol = nums.map((n, c) => (c === nameCol ? -1 : n)).reduce((best, n, c, a) => (n > a[best] ? c : best), 0);
  if (text[nameCol] < 3 || nums[qtyCol] < text[nameCol] / 2) return null;
  const start = rows.findIndex((r) => r[nameCol] && !isWholeNumber(r[nameCol]) && r[qtyCol] && isWholeNumber(r[qtyCol]));
  if (start < 1) return null;
  const header = Array(width).fill('');
  header[nameCol] = 'Item name';
  header[qtyCol] = 'Qty';
  const out = rows.slice();
  out[start - 1] = header;
  return {
    rows: out,
    headerIndex: start - 1,
    note: `No header row found. Reading column ${columnLetter(nameCol)} as the item name and column ${columnLetter(qtyCol)} as the quantity.`,
  };
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
// the file) to "name", "sku", "unit", "ignore", "stock" (a plain quantity) or
// "stock:<location name>". A plain quantity column is stock at
// defaultLocationId, or the main shop when that isn't given.
function mapColumns(header, locations, overrides = {}, defaultLocationId = null) {
  const overrideByNorm = new Map(Object.entries(overrides).map(([h, f]) => [normalize(h), { header: h, field: f }]));
  const main = locations.find((l) => l.id === defaultLocationId) ?? locations.find((l) => l.type === 'main');
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

// "1,200" -> 1200, "12.0" -> 12. Returns null when it isn't a whole number >= 0.
function parseQuantity(text) {
  const n = Number(text.replace(/[\s,]/g, ''));
  return Number.isInteger(n) && n >= 0 ? n : null;
}

const isEmptyQuantity = (text) => ['', '-'].includes(text.replace(/\s/g, ''));

// Names match ignoring case, spaces and punctuation: "AFNAN 9AM" is "Afnan 9 AM".
const keyName = (name) => normalize(name);

function itemKey(name, sku) {
  return sku ? `sku:${sku.toLowerCase()}` : `name:${keyName(name)}`;
}

// Decides what happens to every row below the header. Nothing is dropped
// without a reason: each data row ends up in create, update, unchanged or
// skipped. Rows for items already in the app are skipped unless
// updateExisting is set; then their counts become the new stock levels.
// levels (from loadContext) gives the current counts so changes can be shown.
function planImport(rows, headerIndex, mapping, existingItems, { updateExisting = false, levels = [] } = {}) {
  const existing = new Map();
  for (const item of existingItems) {
    if (item.sku) existing.set(itemKey(item.name, item.sku), item);
    existing.set(itemKey(item.name, null), item);
  }
  const current = new Map(levels.map((l) => [`${l.item_id}:${l.location_id}`, l.quantity]));
  const seen = new Map();
  const create = [];
  const update = [];
  const skipped = [];
  let unchanged = 0;
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
    // counts: what the sheet says is at each location; blank cells say nothing.
    const counts = [];
    const bad = [];
    for (const col of mapping.stock) {
      const text = get(col.index);
      if (isEmptyQuantity(text)) continue;
      const quantity = parseQuantity(text);
      if (quantity === null) bad.push(`${col.header} "${text}"`);
      else counts.push({ location: col.location, quantity });
    }
    if (bad.length) {
      skip(`quantity is not a whole number of 0 or more: ${bad.join(', ')}`);
      continue;
    }
    const key = itemKey(name, sku);
    if (seen.has(key)) {
      skip(`same ${sku ? `SKU ${sku}` : 'name'} as row ${seen.get(key)}`);
      continue;
    }
    seen.set(key, rowNumber);
    const match = existing.get(key);
    if (match) {
      const described = `"${match.name}"${match.sku ? ` (SKU ${match.sku})` : ''}`;
      if (match.archived) {
        skip(`${described} is archived in the app`);
      } else if (!updateExisting) {
        skip(`already in the app as ${described}`);
      } else {
        const changes = counts
          .map((c) => ({ ...c, from: current.get(`${match.id}:${c.location.id}`) ?? 0 }))
          .filter((c) => c.from !== c.quantity);
        if (changes.length) update.push({ row: rowNumber, item: match, changes });
        else unchanged++;
      }
      continue;
    }
    create.push({ row: rowNumber, name, sku, unit, stock: counts.filter((c) => c.quantity > 0), similar: similarNames(name, existingItems) });
  }
  return { create, update, unchanged, skipped, blankRows };
}

// Items in the app whose name contains this one or is contained in it, e.g.
// "HAWAS ICE" and "RASASI HAWAS ICE 100 ML", so a short name on a sheet
// doesn't quietly become a second copy of an item.
function similarNames(name, items) {
  const n = normalize(name);
  if (n.length < 4) return [];
  return items
    .filter((i) => !i.archived && i.name.length >= 4)
    .filter((i) => {
      const m = normalize(i.name);
      return m.includes(n) || n.includes(m);
    })
    .slice(0, 3)
    .map((i) => i.name);
}

// Totals for a plan: units going in as new stock, sold and received.
function summarize(plan) {
  let newStock = 0;
  let sold = 0;
  let received = 0;
  for (const e of plan.create) for (const s of e.stock) newStock += s.quantity;
  for (const e of plan.update) {
    for (const c of e.changes) {
      if (c.quantity < c.from) sold += c.from - c.quantity;
      else received += c.quantity - c.from;
    }
  }
  return { new_items: plan.create.length, new_stock: newStock, changed_items: plan.update.length, sold, received, unchanged_items: plan.unchanged, skipped_rows: plan.skipped.length };
}

async function loadContext(db) {
  const { rows: locations } = await db.query('SELECT id, name, type FROM locations WHERE NOT archived ORDER BY type = \'main\' DESC, name');
  const { rows: items } = await db.query('SELECT id, name, sku, archived FROM items');
  const { rows: levels } = await db.query('SELECT item_id, location_id, quantity FROM stock_levels');
  return { locations, items, levels };
}

// Creates the planned items with their stock as "receive" movements, and
// brings existing items to the counts in the sheet: a lower count is recorded
// as a sale, a higher one as stock received. Counts are compared with the
// stock at the moment of saving, not the preview. All or nothing: any error
// rolls the whole import back. Returns low-stock alerts to send after commit.
async function applyPlan(client, plan, { note, uploadId = null }) {
  let movements = 0;
  let sold = 0;
  let received = 0;
  const alerts = [];
  for (const entry of plan.create) {
    const { rows } = await client.query(
      'INSERT INTO items (name, sku, unit) VALUES ($1, $2, $3) RETURNING id',
      [entry.name, entry.sku, entry.unit],
    );
    for (const s of entry.stock) {
      await receiveIn(client, { itemId: rows[0].id, locationId: s.location.id, quantity: s.quantity, note, uploadId });
      movements++;
      received += s.quantity;
    }
  }
  for (const entry of plan.update) {
    for (const c of entry.changes) {
      const { rows } = await client.query(
        'SELECT quantity FROM stock_levels WHERE item_id = $1 AND location_id = $2 FOR UPDATE',
        [entry.item.id, c.location.id],
      );
      const delta = c.quantity - (rows[0]?.quantity ?? 0);
      if (delta === 0) continue;
      if (delta > 0) {
        await receiveIn(client, { itemId: entry.item.id, locationId: c.location.id, quantity: delta, note, uploadId });
        received += delta;
      } else {
        const r = await saleIn(client, { itemId: entry.item.id, locationId: c.location.id, quantity: -delta, note, uploadId });
        alerts.push(...r.alerts);
        sold += -delta;
      }
      movements++;
    }
  }
  return { items: plan.create.length, updated: plan.update.length, movements, sold, received, alerts };
}

module.exports = {
  readTable, readTableBuffer, findHeaderRow, guessHeader, mapColumns, planImport, summarize, loadContext, applyPlan, normalize, parseQuantity,
};
