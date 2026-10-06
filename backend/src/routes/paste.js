const express = require('express');
const db = require('../db');
const { badRequest, positiveInt } = require('../errors');
const { notifyLowStock } = require('../services/notifier');
const { loadContext } = require('../import/items');
const { ACTIONS, parsePaste, planPaste, applyPaste } = require('../import/paste');

const router = express.Router();

const LABELS = { receive: 'Pasted purchase', transfer: 'Pasted transfer', sale: 'Pasted sale' };

// Body: { action: receive | transfer | sale, text, location_id, to_location_id }.
// receive: stock arrives at location_id (default the main shop).
// transfer: stock moves from location_id (default the main shop) to to_location_id.
// sale: stock is sold at location_id.
async function plan(body = {}) {
  const { action, text } = body;
  if (!ACTIONS.includes(action)) throw badRequest(`action must be one of ${ACTIONS.join(', ')}`);
  if (typeof text !== 'string' || !text.trim()) throw badRequest('Paste the list of items first');
  if (text.length > 200000) throw badRequest('The pasted list is too long');

  const context = await loadContext(db);
  const main = context.locations.find((l) => l.type === 'main') ?? context.locations[0];
  const find = (value, field) => {
    const id = positiveInt(value, field);
    const location = context.locations.find((l) => l.id === id);
    if (!location) throw badRequest(`Location ${id} not found`);
    return location;
  };
  let from = null;
  let to = null;
  if (action === 'receive') {
    to = body.location_id ? find(body.location_id, 'location_id') : main;
  } else if (action === 'transfer') {
    from = body.location_id ? find(body.location_id, 'location_id') : main;
    if (!body.to_location_id) throw badRequest('Choose where the stock is going');
    to = find(body.to_location_id, 'to_location_id');
    if (from.id === to.id) throw badRequest('Stock must go to a different place');
  } else {
    if (!body.location_id) throw badRequest('Choose where the items were sold');
    from = find(body.location_id, 'location_id');
  }
  return planPaste(action, parsePaste(text), context, { from, to });
}

// What saving the pasted list would do. Saves nothing.
router.post('/preview', async (req, res) => {
  res.json(await plan(req.body));
});

// Saves the pasted list. Stock is checked again at this moment, so lines that
// no longer have enough stock are skipped, never taken below zero.
router.post('/', async (req, res) => {
  const planned = await plan(req.body);
  if (!planned.lines.length) throw badRequest('None of the pasted lines can be saved');
  const place = (planned.action === 'sale' ? planned.from : planned.to).location_name;
  const filename = `${LABELS[planned.action]} (${planned.from && planned.to ? `${planned.from.location_name} → ` : ''}${place})`;
  const { upload, alerts } = await db.withTransaction(async (client) => {
    const { rows } = await client.query(
      'INSERT INTO stock_uploads (filename, summary) VALUES ($1, $2) RETURNING *', [filename, planned.summary],
    );
    const raised = await applyPaste(client, planned, { note: filename, uploadId: rows[0].id });
    return { upload: rows[0], alerts: raised };
  });
  await notifyLowStock(alerts);
  res.status(201).json({ ...upload, alerts });
});

module.exports = router;
