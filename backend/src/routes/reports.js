const { Router } = require('express');
const db = require('../db');
const config = require('../config');
const { badRequest, positiveInt } = require('../errors');

const router = Router();

// What sold on one day (in the shop's time zone): each item's total at each
// location, from sales entered in the app and drops in uploaded stock sheets.
// date defaults to today.
router.get('/sales', async (req, res) => {
  let date = req.query.date ?? null;
  if (date !== null && !/^\d{4}-\d{2}-\d{2}$/.test(date)) throw badRequest('date must look like 2026-10-06');
  const locationId = req.query.location_id ? positiveInt(req.query.location_id, 'location_id') : null;
  date ??= (await db.query('SELECT (now() AT TIME ZONE $1)::date::text AS d', [config.timeZone])).rows[0].d;
  const { rows } = await db.query(
    `SELECT i.id AS item_id, i.name AS item_name, i.unit,
            l.id AS location_id, l.name AS location_name,
            SUM(m.quantity)::int AS quantity
       FROM stock_movements m
       JOIN items i ON i.id = m.item_id
       JOIN locations l ON l.id = m.from_location_id
      WHERE m.type = 'sale'
        AND m.created_at >= ($1::date::timestamp AT TIME ZONE $2)
        AND m.created_at < (($1::date + 1)::timestamp AT TIME ZONE $2)
        AND ($3::int IS NULL OR l.id = $3)
      GROUP BY i.id, l.id
      ORDER BY quantity DESC, i.name`,
    [date, config.timeZone, locationId],
  );
  res.json({ date, total: rows.reduce((sum, r) => sum + r.quantity, 0), items: rows });
});

module.exports = router;
