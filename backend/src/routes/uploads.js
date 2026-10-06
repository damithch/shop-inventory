const express = require('express');
const path = require('path');
const db = require('../db');
const { badRequest, positiveInt } = require('../errors');
const { notifyLowStock } = require('../services/notifier');
const {
  readTableBuffer, findHeaderRow, guessHeader, mapColumns, planImport, summarize, loadContext, applyPlan,
} = require('../import/items');

const router = express.Router();

// The file is sent as the raw request body; filename and location_id go in
// the query string. Vercel caps request bodies at 4.5 MB.
const rawFile = express.raw({ type: () => true, limit: '4mb' });

// Reads the uploaded sheet and works out what saving it would do.
async function plan(req) {
  const filename = path.basename(String(req.query.filename ?? ''));
  if (!filename) throw badRequest('filename is required');
  if (!Buffer.isBuffer(req.body) || !req.body.length) throw badRequest('The file is empty');
  const locationId = req.query.location_id ? positiveInt(req.query.location_id, 'location_id') : null;

  let rows;
  try {
    rows = await readTableBuffer(req.body, path.extname(filename));
  } catch (err) {
    throw badRequest(err.message);
  }
  const notes = [];
  let headerIndex = findHeaderRow(rows);
  if (headerIndex < 0) {
    const guess = guessHeader(rows);
    if (!guess) throw badRequest('Could not find the item names in this file. Add a header row with "Item name" and "Qty" columns.');
    ({ rows, headerIndex } = guess);
    notes.push(guess.note);
  }
  const context = await loadContext(db);
  if (locationId && !context.locations.some((l) => l.id === locationId)) throw badRequest(`Location ${locationId} not found`);
  const { mapping, errors } = mapColumns(rows[headerIndex], context.locations, {}, locationId);
  if (errors.length) throw badRequest(`${errors.join('. ')}. Columns in the file: ${rows[headerIndex].filter(Boolean).join(', ')}`);
  const result = planImport(rows, headerIndex, mapping, context.items, { updateExisting: true, levels: context.levels });
  return { filename, notes, headerIndex, mapping, plan: result };
}

function describe({ filename, notes, headerIndex, mapping, plan: p }) {
  const loc = (l) => ({ location_id: l.id, location_name: l.name });
  return {
    filename,
    notes,
    header_row: headerIndex + 1,
    columns: {
      stock: mapping.stock.map((s) => ({ header: s.header, ...loc(s.location) })),
      ignored: mapping.ignored.map((c) => c.header),
    },
    summary: summarize(p),
    new_items: p.create.map((e) => ({
      row: e.row, name: e.name, sku: e.sku, unit: e.unit, similar_to: e.similar,
      stock: e.stock.map((s) => ({ ...loc(s.location), quantity: s.quantity })),
    })),
    changes: p.update.flatMap((e) => e.changes.map((c) => ({
      row: e.row, item_id: e.item.id, item_name: e.item.name, ...loc(c.location), from: c.from, to: c.quantity,
    }))),
    skipped: p.skipped,
  };
}

// What the sheet would change. Saves nothing.
router.post('/preview', rawFile, async (req, res) => {
  res.json(describe(await plan(req)));
});

// Saves the sheet: new items are created, and each count in the sheet becomes
// the stock at that location (a drop is recorded as sold, a rise as received).
router.post('/', rawFile, async (req, res) => {
  const planned = await plan(req);
  const preview = describe(planned);
  const { upload, result } = await db.withTransaction(async (client) => {
    const { rows } = await client.query(
      'INSERT INTO stock_uploads (filename, summary) VALUES ($1, $2) RETURNING *',
      [planned.filename, preview.summary],
    );
    const applied = await applyPlan(client, planned.plan, { note: `Stock sheet ${planned.filename}`, uploadId: rows[0].id });
    const summary = { ...preview.summary, sold: applied.sold, received: applied.received };
    const { rows: saved } = await client.query(
      'UPDATE stock_uploads SET summary = $2 WHERE id = $1 RETURNING *', [rows[0].id, summary],
    );
    return { upload: saved[0], result: applied };
  });
  await notifyLowStock(result.alerts);
  res.status(201).json({ ...upload, alerts: result.alerts });
});

// Past uploads, newest first.
router.get('/', async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 50, 200);
  const { rows } = await db.query('SELECT * FROM stock_uploads ORDER BY id DESC LIMIT $1', [limit]);
  res.json(rows);
});

module.exports = router;
