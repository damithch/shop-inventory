const { Router } = require('express');
const db = require('../db');
const config = require('../config');
const { checkPassword } = require('../auth');
const { stockExport } = require('./exports');
const { HttpError, badRequest, notFound, positiveInt } = require('../errors');

const router = Router();

// Setting stock back to zero and deleting items or branches. Every request
// needs the owner's password again in "password". With "dry_run": true the
// change is worked out and rolled back, so the app can check the password and
// show what would happen before saving a backup and doing it for real.
//
// Nothing is wiped: each count taken away is recorded as an "adjust"
// movement with the note "Reset to zero", and deleted items and branches are
// archived, so sales history and past reports keep their names. Resets never
// raise low-stock alerts.

const RESET_NOTE = 'Reset to zero';

// The whole feature can be switched off with RESET_ENABLED (see config.js).
// The app shows this message in the confirm dialog, before any backup.
router.use((req, res, next) => {
  if (!config.resetEnabled) throw new HttpError(403, 'Reset and delete is turned off');
  next();
});

class DryRun extends Error {
  constructor(summary) {
    super('dry run');
    this.summary = summary;
  }
}

// Runs fn in a transaction after checking the password, and answers with its
// summary. A dry run rolls the transaction back.
function guarded(fn) {
  return async (req, res) => {
    const password = req.body?.password;
    if (typeof password !== 'string' || !password) throw badRequest('Enter your password');
    // 403, not 401: a mistyped password here must not sign the phone out.
    if (!(await checkPassword(password))) throw new HttpError(403, 'The password is wrong');
    const dryRun = req.body.dry_run === true;
    try {
      const summary = await db.withTransaction(async (client) => {
        const result = await fn(client, req.body);
        if (dryRun) throw new DryRun(result);
        return result;
      });
      res.json({ ...summary, dry_run: false });
    } catch (err) {
      if (err instanceof DryRun) return res.json({ ...err.summary, dry_run: true });
      throw err;
    }
  };
}

// Sets every count above zero to zero, for the given locations and items (all
// of them when null), recording each as an adjust movement.
async function zeroStock(client, { locationIds = null, itemIds = null }) {
  const { rows } = await client.query(
    `WITH old AS (
       SELECT item_id, location_id, quantity FROM stock_levels
        WHERE quantity > 0
          AND ($1::int[] IS NULL OR location_id = ANY($1))
          AND ($2::int[] IS NULL OR item_id = ANY($2))
        FOR UPDATE
     ), zeroed AS (
       UPDATE stock_levels s SET quantity = 0, updated_at = now()
         FROM old WHERE s.item_id = old.item_id AND s.location_id = old.location_id
       RETURNING old.item_id, old.location_id, old.quantity
     )
     INSERT INTO stock_movements (item_id, type, quantity, from_location_id, note)
     SELECT item_id, 'adjust', quantity, location_id, $3 FROM zeroed
     RETURNING item_id, quantity`,
    [locationIds, itemIds, RESET_NOTE],
  );
  return {
    items: new Set(rows.map((r) => r.item_id)).size,
    units: rows.reduce((sum, r) => sum + r.quantity, 0),
  };
}

async function findLocation(client, id) {
  const { rows } = await client.query('SELECT * FROM locations WHERE id = $1 FOR UPDATE', [id]);
  if (!rows.length) throw notFound(`Location ${id} not found`);
  return rows[0];
}

// Archives items, frees their SKUs for new items and forgets their other
// names, so new sheets and pasted lists don't match them.
async function archiveItems(client, itemIds) {
  await client.query('UPDATE items SET archived = TRUE, sku = NULL WHERE id = ANY($1)', [itemIds]);
  await client.query('DELETE FROM item_aliases WHERE item_id = ANY($1)', [itemIds]);
}

// Every count at one location (location_id), or at every location, to zero.
// The Excel backup the app saves before a reset: the same file as the stock
// export (?location_id= for one place), available even when exports are off.
router.get('/backup', (req, res) => stockExport(req, res, 'xlsx'));

router.post('/stock', guarded(async (client, body) => {
  if (body.location_id === undefined || body.location_id === null) {
    return { ...(await zeroStock(client, {})), location: null };
  }
  const location = await findLocation(client, positiveInt(body.location_id, 'location_id'));
  return { ...(await zeroStock(client, { locationIds: [location.id] })), location: location.name };
}));

// One item: its stock everywhere to zero, then it leaves every list.
router.post('/delete-item', guarded(async (client, body) => {
  const id = positiveInt(body.item_id, 'item_id');
  const { rows } = await client.query('SELECT id, name, archived FROM items WHERE id = $1 FOR UPDATE', [id]);
  if (!rows.length || rows[0].archived) throw notFound(`Item ${id} not found`);
  const zeroed = await zeroStock(client, { itemIds: [id] });
  await archiveItems(client, [id]);
  return { ...zeroed, deleted_items: 1, item: rows[0].name };
}));

// Every item, for a fresh start. Places stay.
router.post('/delete-all-items', guarded(async (client) => {
  const { rows } = await client.query('SELECT id FROM items WHERE NOT archived FOR UPDATE');
  const ids = rows.map((r) => r.id);
  const zeroed = await zeroStock(client, {});
  await archiveItems(client, ids);
  return { ...zeroed, deleted_items: ids.length };
}));

// One branch: its stock to zero, then it is archived under a new name so the
// name can be used again. The main shop can't be deleted.
router.post('/delete-branch', guarded(async (client, body) => {
  const location = await findLocation(client, positiveInt(body.location_id, 'location_id'));
  if (location.type === 'main') throw badRequest('The main shop cannot be deleted');
  if (location.archived) throw notFound(`Location ${location.id} not found`);
  const zeroed = await zeroStock(client, { locationIds: [location.id] });
  const { rows } = await client.query('SELECT (now() AT TIME ZONE $1)::date::text AS d', [config.timeZone]);
  let newName = `${location.name} (deleted ${rows[0].d})`;
  const { rows: taken } = await client.query('SELECT 1 FROM locations WHERE name = $1', [newName]);
  if (taken.length) newName = `${location.name} (deleted ${rows[0].d} #${location.id})`;
  await client.query('UPDATE locations SET archived = TRUE, name = $2 WHERE id = $1', [location.id, newName]);
  return { ...zeroed, location: location.name };
}));

module.exports = router;
