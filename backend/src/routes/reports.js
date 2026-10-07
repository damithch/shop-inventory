const { Router } = require('express');
const db = require('../db');
const config = require('../config');
const { badRequest, notFound, positiveInt } = require('../errors');
const { salesPdf } = require('../services/sales-pdf');

const router = Router();

// What sold on one day (in the shop's time zone): each item's total at each
// location, from sales entered in the app and drops in uploaded stock sheets.
// date defaults to today. Each sale counts at the price it was sold at, or the
// item's current price for sales recorded before prices existed; amount is
// null for a line with any units that have no price.
async function salesReport(query) {
  let date = query.date ?? null;
  if (date !== null && !/^\d{4}-\d{2}-\d{2}$/.test(date)) throw badRequest('date must look like 2026-10-06');
  const locationId = query.location_id ? positiveInt(query.location_id, 'location_id') : null;
  let location = null;
  if (locationId) {
    const { rows } = await db.query('SELECT id, name FROM locations WHERE id = $1', [locationId]);
    if (!rows.length) throw notFound(`Location ${locationId} not found`);
    location = rows[0];
  }
  date ??= (await db.query('SELECT (now() AT TIME ZONE $1)::date::text AS d', [config.timeZone])).rows[0].d;
  const { rows } = await db.query(
    `SELECT i.id AS item_id, i.name AS item_name, i.unit,
            l.id AS location_id, l.name AS location_name,
            SUM(m.quantity)::int AS quantity,
            SUM(m.quantity * COALESCE(m.unit_price, i.price)) AS priced_amount,
            COALESCE(SUM(m.quantity) FILTER (WHERE COALESCE(m.unit_price, i.price) IS NULL), 0)::int AS unpriced
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
  const items = rows.map(({ priced_amount: amount, unpriced, ...r }) => ({
    ...r,
    amount: unpriced ? null : amount,
    unit_price: unpriced ? null : Math.round((amount / r.quantity) * 100) / 100,
  }));
  return {
    date,
    location_id: location?.id ?? null,
    location_name: location?.name ?? null,
    total: items.reduce((sum, r) => sum + r.quantity, 0),
    total_amount: Math.round(rows.reduce((sum, r) => sum + (r.priced_amount ?? 0), 0) * 100) / 100,
    unpriced_units: rows.reduce((sum, r) => sum + r.unpriced, 0),
    items,
  };
}

router.get('/sales', async (req, res) => {
  res.json(await salesReport(req.query));
});

// The same report as a PDF to share or print, e.g. a branch's end of day.
router.get('/sales/pdf', async (req, res) => {
  const report = await salesReport(req.query);
  const place = report.location_name ?? 'all';
  const slug = place.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'location';
  const generatedAt = new Date().toLocaleString('en-GB', {
    timeZone: config.timeZone, day: 'numeric', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit',
  });
  res.set('Content-Type', 'application/pdf');
  res.attachment(`sales-${slug}-${report.date}.pdf`);
  res.send(Buffer.from(await salesPdf(report, { generatedAt })));
});

module.exports = router;
