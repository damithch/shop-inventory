const express = require('express');
const db = require('../db');
const { badRequest, positiveInt, optionalPrice } = require('../errors');
const { notifyLowStock } = require('../services/notifier');
const { loadContext } = require('../import/items');
const { normalize } = require('../import/items');
const { ACTIONS, parsePaste, planPaste, applyPaste, namedLocation } = require('../import/paste');

const router = express.Router();

const LABELS = { receive: 'Pasted purchase', transfer: 'Pasted transfer', sale: 'Pasted sale' };

// Body: { action: receive | transfer | sale, text, location_id, to_location_id, matches, prices }.
// receive: stock arrives at location_id (default the main shop).
// transfer: stock moves from location_id (default the main shop) to
//   to_location_id, or to the place a line of the list names ("Dehiwela").
// sale: stock is sold at location_id.
// matches: { "pasted name": item_id } for names the app didn't recognise.
// no_match: ["pasted name"] the app matched automatically, but wrongly.
async function plan(body = {}) {
  const { action, text } = body;
  if (!ACTIONS.includes(action)) throw badRequest(`action must be one of ${ACTIONS.join(', ')}`);
  if (typeof text !== 'string' || !text.trim()) throw badRequest('Paste the list of items first');
  if (text.length > 200000) throw badRequest('The pasted list is too long');

  const matches = new Map();
  if (body.matches !== undefined) {
    if (typeof body.matches !== 'object' || body.matches === null || Array.isArray(body.matches)) {
      throw badRequest('matches must map pasted names to item ids');
    }
    for (const [name, id] of Object.entries(body.matches)) matches.set(normalize(name), positiveInt(id, 'matches'));
  }

  const noMatch = new Set();
  if (body.no_match !== undefined) {
    if (!Array.isArray(body.no_match) || body.no_match.some((n) => typeof n !== 'string')) {
      throw badRequest('no_match must be a list of pasted names');
    }
    for (const name of body.no_match) noMatch.add(normalize(name));
  }

  // prices: { item_id: price or null } for a sale; typed-in prices are
  // remembered as the item's price.
  const prices = new Map();
  if (body.prices !== undefined) {
    if (action !== 'sale') throw badRequest('Prices can only be given for sales');
    if (typeof body.prices !== 'object' || body.prices === null || Array.isArray(body.prices)) {
      throw badRequest('prices must map item ids to prices');
    }
    for (const [id, price] of Object.entries(body.prices)) prices.set(positiveInt(id, 'prices'), optionalPrice(price, 'Price'));
  }

  const parsed = parsePaste(text);
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
    if (body.to_location_id) {
      to = find(body.to_location_id, 'to_location_id');
    } else {
      to = parsed.skipped.map((s) => namedLocation(s.text, context.locations)).find((l) => l && l.id !== from.id);
      if (!to) throw badRequest('Choose where the stock is going');
    }
    if (from.id === to.id) throw badRequest('Stock must go to a different place');
  } else {
    if (!body.location_id) throw badRequest('Choose where the items were sold');
    from = find(body.location_id, 'location_id');
  }
  // A line that only names a place is a heading, not an item.
  for (const s of parsed.skipped) {
    const place = s.reason === 'no quantity on this line' && namedLocation(s.text, context.locations);
    if (place) s.reason = `place name (${place.name})`;
  }
  return { planned: planPaste(action, parsed, context, { from, to, matches, noMatch, prices }), prices };
}

// What saving the pasted list would do. Saves nothing.
router.post('/preview', async (req, res) => {
  res.json((await plan(req.body)).planned);
});

// Saves the pasted list. Stock is checked again at this moment, so lines that
// no longer have enough stock are skipped, never taken below zero.
router.post('/', async (req, res) => {
  const { planned, prices } = await plan(req.body);
  if (!planned.lines.length) throw badRequest('None of the pasted lines can be saved');
  const place = (planned.action === 'sale' ? planned.from : planned.to).location_name;
  const filename = `${LABELS[planned.action]} (${planned.from && planned.to ? `${planned.from.location_name} → ` : ''}${place})`;
  const { upload, alerts } = await db.withTransaction(async (client) => {
    const { rows } = await client.query(
      'INSERT INTO stock_uploads (filename, summary) VALUES ($1, $2) RETURNING *', [filename, planned.summary],
    );
    const raised = await applyPaste(client, planned, { note: filename, uploadId: rows[0].id, prices });
    return { upload: rows[0], alerts: raised };
  });
  await notifyLowStock(alerts);
  res.status(201).json({ ...upload, alerts });
});

module.exports = router;
