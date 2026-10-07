const { Router } = require('express');
const ExcelJS = require('exceljs');
const db = require('../db');
const config = require('../config');
const { badRequest, notFound, positiveInt } = require('../errors');
const { getDefaultThreshold } = require('../services/stock');

const router = Router();

// Spreadsheets to download: the stock at one location or all of them, and
// the item list. ?format=xlsx (default) or csv. Archived items and
// locations are left out.

function readFormat(query) {
  const format = query.format ?? 'xlsx';
  if (format !== 'xlsx' && format !== 'csv') throw badRequest('format must be xlsx or csv');
  return format;
}

async function today() {
  return (await db.query('SELECT (now() AT TIME ZONE $1)::date::text AS d', [config.timeZone])).rows[0].d;
}

function slug(name) {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'location';
}

function csvCell(value) {
  if (value === null || value === undefined) return '';
  const text = String(value);
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

// A table is { name, columns: [{ header, key, width? }], rows }.
async function send(res, format, filename, tables) {
  if (format === 'csv') {
    const { columns, rows } = tables[0];
    const lines = [columns.map((c) => csvCell(c.header)).join(',')];
    for (const row of rows) lines.push(columns.map((c) => csvCell(row[c.key])).join(','));
    // The byte order mark makes Excel read names with non-English letters correctly.
    res.set('Content-Type', 'text/csv; charset=utf-8');
    res.attachment(`${filename}.csv`);
    res.send(`﻿${lines.join('\r\n')}\r\n`);
    return;
  }
  const workbook = new ExcelJS.Workbook();
  for (const table of tables) {
    // Sheet names are limited to 31 characters and can't use some symbols.
    const sheet = workbook.addWorksheet(table.name.replace(/[*?:\\/[\]]/g, ' ').slice(0, 31));
    sheet.columns = table.columns.map((c) => ({ header: c.header, key: c.key, width: c.width ?? 12 }));
    sheet.getRow(1).font = { bold: true };
    sheet.views = [{ state: 'frozen', ySplit: 1 }];
    sheet.addRows(table.rows);
  }
  res.set('Content-Type', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
  res.attachment(`${filename}.xlsx`);
  res.send(Buffer.from(await workbook.xlsx.writeBuffer()));
}

const itemColumns = [
  { header: 'Item name', key: 'name', width: 40 },
  { header: 'SKU', key: 'sku', width: 14 },
  { header: 'Unit', key: 'unit', width: 8 },
];

// Every item's stock at one location, with its alert level. The columns read
// back as a stock sheet, so a counted copy can be uploaded for that location.
async function locationTable(location, defaultThreshold) {
  const { rows } = await db.query(
    `SELECT i.name, i.sku, i.unit,
            COALESCE(s.quantity, 0) AS quantity,
            COALESCE(s.threshold, $2) AS threshold,
            s.item_id IS NOT NULL AND s.quantity <= COALESCE(s.threshold, $2) AS low
       FROM items i LEFT JOIN stock_levels s ON s.item_id = i.id AND s.location_id = $1
      WHERE NOT i.archived
      ORDER BY i.name`,
    [location.id, defaultThreshold],
  );
  return {
    name: location.name,
    columns: [
      ...itemColumns,
      { header: 'Qty', key: 'quantity', width: 8 },
      { header: 'Alert level', key: 'threshold', width: 11 },
      { header: 'Low stock', key: 'low', width: 10 },
    ],
    rows: rows.map((r) => ({ ...r, low: r.low ? 'Yes' : '' })),
  };
}

// One row per item, a column per location and the total.
async function allLocationsTable(locations) {
  const { rows } = await db.query(
    `SELECT i.id, i.name, i.sku, i.unit,
            COALESCE(json_object_agg(s.location_id, s.quantity) FILTER (WHERE s.location_id IS NOT NULL), '{}') AS stock
       FROM items i LEFT JOIN stock_levels s ON s.item_id = i.id
      WHERE NOT i.archived
      GROUP BY i.id
      ORDER BY i.name`,
  );
  return {
    name: 'All locations',
    columns: [
      ...itemColumns,
      ...locations.map((l) => ({ header: l.name, key: `loc${l.id}`, width: Math.max(10, l.name.length + 2) })),
      { header: 'Total', key: 'total', width: 8 },
    ],
    rows: rows.map((r) => {
      const row = { name: r.name, sku: r.sku, unit: r.unit, total: 0 };
      for (const l of locations) {
        const qty = r.stock[l.id] ?? 0;
        row[`loc${l.id}`] = qty;
        row.total += qty;
      }
      return row;
    }),
  };
}

async function activeLocations() {
  const { rows } = await db.query("SELECT * FROM locations WHERE NOT archived ORDER BY type = 'main' DESC, name");
  return rows;
}

// ?location_id= for one location; without it, every location: in Excel a
// summary sheet plus a sheet per location, in CSV the summary.
router.get('/stock', async (req, res) => {
  const format = readFormat(req.query);
  const date = await today();
  const defaultThreshold = await getDefaultThreshold();
  if (req.query.location_id) {
    const id = positiveInt(req.query.location_id, 'location_id');
    const { rows } = await db.query('SELECT * FROM locations WHERE id = $1', [id]);
    if (!rows.length) throw notFound(`Location ${id} not found`);
    await send(res, format, `stock-${slug(rows[0].name)}-${date}`, [await locationTable(rows[0], defaultThreshold)]);
    return;
  }
  const locations = await activeLocations();
  const tables = [await allLocationsTable(locations)];
  if (format === 'xlsx') {
    for (const location of locations) tables.push(await locationTable(location, defaultThreshold));
  }
  await send(res, format, `stock-all-locations-${date}`, tables);
});

// The item list: name, SKU, unit, total stock and when it was added.
router.get('/items', async (req, res) => {
  const format = readFormat(req.query);
  const { rows } = await db.query(
    `SELECT i.name, i.sku, i.unit,
            COALESCE(SUM(s.quantity) FILTER (WHERE NOT l.archived), 0)::int AS total,
            to_char(i.created_at AT TIME ZONE $1, 'YYYY-MM-DD') AS added
       FROM items i
       LEFT JOIN stock_levels s ON s.item_id = i.id
       LEFT JOIN locations l ON l.id = s.location_id
      WHERE NOT i.archived
      GROUP BY i.id
      ORDER BY i.name`,
    [config.timeZone],
  );
  await send(res, format, `items-${await today()}`, [
    {
      name: 'Items',
      columns: [
        ...itemColumns,
        { header: 'Total stock', key: 'total', width: 11 },
        { header: 'Added', key: 'added', width: 11 },
      ],
      rows,
    },
  ]);
});

module.exports = router;
