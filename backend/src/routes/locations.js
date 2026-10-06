const { Router } = require('express');
const db = require('../db');
const { notFound, conflict, badRequest, nonEmptyString, positiveInt } = require('../errors');
const { getDefaultThreshold } = require('../services/stock');

const router = Router();

router.get('/', async (req, res) => {
  const includeArchived = req.query.include_archived === 'true';
  const { rows } = await db.query(
    `SELECT l.*,
            COUNT(s.item_id) FILTER (WHERE s.quantity > 0)::int AS item_count,
            COALESCE(SUM(s.quantity), 0)::int AS total_units
       FROM locations l LEFT JOIN stock_levels s ON s.location_id = l.id
      WHERE $1 OR NOT l.archived
      GROUP BY l.id
      ORDER BY l.type = 'main' DESC, l.name`,
    [includeArchived],
  );
  res.json(rows);
});

router.post('/', async (req, res) => {
  const name = nonEmptyString(req.body?.name, 'name');
  try {
    const { rows } = await db.query(
      "INSERT INTO locations (name, type) VALUES ($1, 'branch') RETURNING *",
      [name],
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    if (err.code === '23505') throw conflict(`A location named "${name}" already exists`);
    throw err;
  }
});

router.patch('/:id', async (req, res) => {
  const id = positiveInt(req.params.id, 'id');
  const { name, archived } = req.body ?? {};
  const { rows: existing } = await db.query('SELECT * FROM locations WHERE id = $1', [id]);
  if (!existing.length) throw notFound(`Location ${id} not found`);
  if (archived === true && existing[0].type === 'main') throw badRequest('The main shop cannot be archived');
  try {
    const { rows } = await db.query(
      `UPDATE locations SET name = COALESCE($2, name), archived = COALESCE($3, archived)
        WHERE id = $1 RETURNING *`,
      [id, name === undefined ? null : nonEmptyString(name, 'name'), typeof archived === 'boolean' ? archived : null],
    );
    res.json(rows[0]);
  } catch (err) {
    if (err.code === '23505') throw conflict(`A location named "${name}" already exists`);
    throw err;
  }
});

// Stock of every item at one location.
router.get('/:id/stock', async (req, res) => {
  const id = positiveInt(req.params.id, 'id');
  const { rows: loc } = await db.query('SELECT * FROM locations WHERE id = $1', [id]);
  if (!loc.length) throw notFound(`Location ${id} not found`);
  const defaultThreshold = await getDefaultThreshold();
  const { rows } = await db.query(
    `SELECT i.id AS item_id, i.name, i.sku, i.unit,
            COALESCE(s.quantity, 0) AS quantity,
            COALESCE(s.threshold, $2) AS threshold,
            s.threshold IS NULL AS uses_default,
            s.item_id IS NOT NULL AND s.quantity <= COALESCE(s.threshold, $2) AS low
       FROM items i LEFT JOIN stock_levels s ON s.item_id = i.id AND s.location_id = $1
      WHERE NOT i.archived
      ORDER BY i.name`,
    [id, defaultThreshold],
  );
  res.json({ location: loc[0], items: rows });
});

module.exports = router;
