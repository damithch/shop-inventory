const { Router } = require('express');
const db = require('../db');
const config = require('../config');
const { nonEmptyString, nonNegativeInt, optionalString, positiveInt } = require('../errors');

const router = Router();

router.get('/settings', async (req, res) => {
  const { rows } = await db.query('SELECT key, value FROM settings');
  const settings = Object.fromEntries(rows.map((r) => [r.key, r.value]));
  res.json({
    default_threshold: Number(settings.default_threshold ?? 3),
    exports_enabled: config.exportsEnabled,
    paste_sales_enabled: config.pasteSalesEnabled,
  });
});

// Changes the alert level used wherever no per-item level has been set.
router.put('/settings', async (req, res) => {
  const value = nonNegativeInt(req.body?.default_threshold, 'default_threshold');
  await db.query(
    `INSERT INTO settings (key, value) VALUES ('default_threshold', $1)
     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
    [String(value)],
  );
  res.json({ default_threshold: value });
});

// Register a phone's FCM token for push notifications.
router.post('/devices', async (req, res) => {
  const token = nonEmptyString(req.body?.token, 'token');
  const platform = optionalString(req.body?.platform) ?? 'android';
  await db.query(
    `INSERT INTO device_tokens (token, platform) VALUES ($1, $2)
     ON CONFLICT (token) DO UPDATE SET platform = EXCLUDED.platform`,
    [token, platform],
  );
  res.status(201).json({ token, platform });
});

router.delete('/devices/:token', async (req, res) => {
  await db.query('DELETE FROM device_tokens WHERE token = $1', [req.params.token]);
  res.status(204).end();
});

// Low-stock alerts raised so far, newest first.
router.get('/alerts', async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 50, 200);
  const before = req.query.before_id ? positiveInt(req.query.before_id, 'before_id') : null;
  const { rows } = await db.query(
    `SELECT a.*, i.name AS item_name, l.name AS location_name, l.type AS location_type
       FROM low_stock_alerts a
       JOIN items i ON i.id = a.item_id
       JOIN locations l ON l.id = a.location_id
      WHERE ($1::int IS NULL OR a.id < $1)
      ORDER BY a.id DESC
      LIMIT $2`,
    [before, limit],
  );
  res.json(rows);
});

module.exports = router;
