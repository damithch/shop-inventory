const { Router } = require('express');
const db = require('../db');
const { notFound, conflict, positiveInt, nonEmptyString, optionalString, optionalPrice } = require('../errors');
const { getDefaultThreshold } = require('../services/stock');

const router = Router();

// Items with their stock in the main shop and in total.
router.get('/', async (req, res) => {
  const includeArchived = req.query.include_archived === 'true';
  const search = req.query.q ? `%${req.query.q}%` : null;
  const { rows } = await db.query(
    `SELECT i.*,
            COALESCE(SUM(s.quantity) FILTER (WHERE l.type = 'main'), 0)::int AS main_quantity,
            COALESCE(SUM(s.quantity), 0)::int AS total_quantity
       FROM items i
       LEFT JOIN stock_levels s ON s.item_id = i.id
       LEFT JOIN locations l ON l.id = s.location_id
      WHERE ($1 OR NOT i.archived)
        AND ($2::text IS NULL OR i.name ILIKE $2 OR i.sku ILIKE $2)
      GROUP BY i.id
      ORDER BY i.name`,
    [includeArchived, search],
  );
  res.json(rows);
});

router.post('/', async (req, res) => {
  const name = nonEmptyString(req.body?.name, 'name');
  const sku = optionalString(req.body?.sku);
  const unit = optionalString(req.body?.unit) ?? 'pcs';
  const price = req.body?.price === undefined ? null : optionalPrice(req.body.price, 'price');
  try {
    const { rows } = await db.query(
      'INSERT INTO items (name, sku, unit, price) VALUES ($1, $2, $3, $4) RETURNING *',
      [name, sku, unit, price],
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    if (err.code === '23505') throw conflict(`An item with SKU "${sku}" already exists`);
    throw err;
  }
});

// One item with its stock at every location.
router.get('/:id', async (req, res) => {
  const id = positiveInt(req.params.id, 'id');
  const { rows: item } = await db.query('SELECT * FROM items WHERE id = $1', [id]);
  if (!item.length) throw notFound(`Item ${id} not found`);
  const defaultThreshold = await getDefaultThreshold();
  const { rows: stock } = await db.query(
    `SELECT l.id AS location_id, l.name AS location_name, l.type AS location_type,
            COALESCE(s.quantity, 0) AS quantity,
            COALESCE(s.threshold, $2) AS threshold,
            s.threshold IS NULL AS uses_default,
            s.item_id IS NOT NULL AND s.quantity <= COALESCE(s.threshold, $2) AS low
       FROM locations l LEFT JOIN stock_levels s ON s.location_id = l.id AND s.item_id = $1
      WHERE NOT l.archived
      ORDER BY l.type = 'main' DESC, l.name`,
    [id, defaultThreshold],
  );
  res.json({ ...item[0], stock });
});

router.patch('/:id', async (req, res) => {
  const id = positiveInt(req.params.id, 'id');
  const body = req.body ?? {};
  const fields = [];
  const values = [id];
  const set = (column, value) => {
    values.push(value);
    fields.push(`${column} = $${values.length}`);
  };
  if (body.name !== undefined) set('name', nonEmptyString(body.name, 'name'));
  if (body.sku !== undefined) set('sku', optionalString(body.sku));
  if (body.unit !== undefined) set('unit', optionalString(body.unit) ?? 'pcs');
  if (body.price !== undefined) set('price', optionalPrice(body.price, 'price'));
  if (typeof body.archived === 'boolean') set('archived', body.archived);
  if (!fields.length) {
    const { rows } = await db.query('SELECT * FROM items WHERE id = $1', [id]);
    if (!rows.length) throw notFound(`Item ${id} not found`);
    return res.json(rows[0]);
  }
  try {
    const { rows } = await db.query(`UPDATE items SET ${fields.join(', ')} WHERE id = $1 RETURNING *`, values);
    if (!rows.length) throw notFound(`Item ${id} not found`);
    res.json(rows[0]);
  } catch (err) {
    if (err.code === '23505') throw conflict(`An item with SKU "${body.sku}" already exists`);
    throw err;
  }
});

module.exports = router;
