const { Router } = require('express');
const db = require('../db');
const stock = require('../services/stock');
const { badRequest, positiveInt, nonNegativeInt, optionalString } = require('../errors');

const router = Router();

const optionalId = (value, field) => (value === undefined || value === null ? null : positiveInt(value, field));

// Add new stock. Goes to the main shop unless location_id is given.
router.post('/receive', async (req, res) => {
  const b = req.body ?? {};
  const result = await stock.receive({
    itemId: positiveInt(b.item_id, 'item_id'),
    locationId: optionalId(b.location_id, 'location_id'),
    quantity: positiveInt(b.quantity, 'quantity'),
    note: optionalString(b.note),
  });
  res.status(201).json(result);
});

// Move stock between locations. Comes from the main shop unless from_location_id is given.
router.post('/transfer', async (req, res) => {
  const b = req.body ?? {};
  const result = await stock.transfer({
    itemId: positiveInt(b.item_id, 'item_id'),
    fromLocationId: optionalId(b.from_location_id, 'from_location_id'),
    toLocationId: positiveInt(b.to_location_id, 'to_location_id'),
    quantity: positiveInt(b.quantity, 'quantity'),
    note: optionalString(b.note),
  });
  res.status(201).json(result);
});

// Record stock sold or used at a location.
router.post('/sale', async (req, res) => {
  const b = req.body ?? {};
  const result = await stock.sale({
    itemId: positiveInt(b.item_id, 'item_id'),
    locationId: positiveInt(b.location_id, 'location_id'),
    quantity: positiveInt(b.quantity, 'quantity'),
    note: optionalString(b.note),
  });
  res.status(201).json(result);
});

// Correct the count at a location after a physical stock check.
router.post('/adjust', async (req, res) => {
  const b = req.body ?? {};
  const result = await stock.adjust({
    itemId: positiveInt(b.item_id, 'item_id'),
    locationId: positiveInt(b.location_id, 'location_id'),
    newQuantity: nonNegativeInt(b.new_quantity, 'new_quantity'),
    note: optionalString(b.note),
  });
  res.status(201).json(result);
});

// Set the alert level for one item at one location. threshold: null resets to the default.
router.put('/threshold', async (req, res) => {
  const b = req.body ?? {};
  if (!('threshold' in b)) throw badRequest('threshold is required (use null to reset to the default)');
  const result = await stock.setThreshold({
    itemId: positiveInt(b.item_id, 'item_id'),
    locationId: positiveInt(b.location_id, 'location_id'),
    threshold: b.threshold === null ? null : nonNegativeInt(b.threshold, 'threshold'),
  });
  res.json(result);
});

// Everything currently at or below its alert level.
router.get('/low', async (req, res) => {
  const defaultThreshold = await stock.getDefaultThreshold();
  const locationId = optionalId(req.query.location_id, 'location_id');
  const { rows } = await db.query(
    `SELECT i.id AS item_id, i.name AS item_name, i.unit,
            l.id AS location_id, l.name AS location_name, l.type AS location_type,
            s.quantity, COALESCE(s.threshold, $1) AS threshold
       FROM stock_levels s
       JOIN items i ON i.id = s.item_id
       JOIN locations l ON l.id = s.location_id
      WHERE NOT i.archived AND NOT l.archived
        AND s.quantity <= COALESCE(s.threshold, $1)
        AND ($2::int IS NULL OR l.id = $2)
      ORDER BY s.quantity, i.name`,
    [defaultThreshold, locationId],
  );
  res.json(rows);
});

// Movement history, newest first.
router.get('/movements', async (req, res) => {
  const itemId = optionalId(req.query.item_id, 'item_id');
  const locationId = optionalId(req.query.location_id, 'location_id');
  const limit = Math.min(Number(req.query.limit) || 50, 200);
  const before = optionalId(req.query.before_id, 'before_id');
  const { rows } = await db.query(
    `SELECT m.*, i.name AS item_name, f.name AS from_location_name, t.name AS to_location_name
       FROM stock_movements m
       JOIN items i ON i.id = m.item_id
       LEFT JOIN locations f ON f.id = m.from_location_id
       LEFT JOIN locations t ON t.id = m.to_location_id
      WHERE ($1::int IS NULL OR m.item_id = $1)
        AND ($2::int IS NULL OR m.from_location_id = $2 OR m.to_location_id = $2)
        AND ($3::int IS NULL OR m.id < $3)
      ORDER BY m.id DESC
      LIMIT $4`,
    [itemId, locationId, before, limit],
  );
  res.json(rows);
});

module.exports = router;
