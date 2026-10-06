const db = require('../db');
const { badRequest, notFound, conflict } = require('../errors');
const { notifyLowStock } = require('./notifier');

async function getDefaultThreshold(client = db) {
  const { rows } = await client.query("SELECT value FROM settings WHERE key = 'default_threshold'");
  return rows.length ? Number(rows[0].value) : 3;
}

async function getItem(client, itemId) {
  const { rows } = await client.query('SELECT id, name, archived FROM items WHERE id = $1', [itemId]);
  if (!rows.length) throw notFound(`Item ${itemId} not found`);
  if (rows[0].archived) throw badRequest(`Item "${rows[0].name}" is archived`);
  return rows[0];
}

async function getLocation(client, locationId) {
  const { rows } = await client.query('SELECT id, name, type, archived FROM locations WHERE id = $1', [locationId]);
  if (!rows.length) throw notFound(`Location ${locationId} not found`);
  if (rows[0].archived) throw badRequest(`Location "${rows[0].name}" is archived`);
  return rows[0];
}

async function getMainLocationId(client = db) {
  const { rows } = await client.query("SELECT id FROM locations WHERE type = 'main'");
  return rows[0].id;
}

// Locks the stock row for (item, location), creating it at 0 if missing.
async function lockLevel(client, itemId, locationId) {
  await client.query(
    'INSERT INTO stock_levels (item_id, location_id) VALUES ($1, $2) ON CONFLICT DO NOTHING',
    [itemId, locationId],
  );
  const { rows } = await client.query(
    'SELECT quantity, threshold FROM stock_levels WHERE item_id = $1 AND location_id = $2 FOR UPDATE',
    [itemId, locationId],
  );
  return rows[0];
}

// Applies delta to a locked level. Returns a low-stock alert if this change
// takes the quantity from above the alert level to at or below it.
async function applyDelta(client, item, location, level, delta, defaultThreshold) {
  const before = level.quantity;
  const after = before + delta;
  if (after < 0) {
    throw conflict(`Not enough "${item.name}" at ${location.name}: ${before} in stock, ${-delta} requested`);
  }
  await client.query(
    'UPDATE stock_levels SET quantity = $3, updated_at = now() WHERE item_id = $1 AND location_id = $2',
    [item.id, location.id, after],
  );
  const threshold = level.threshold ?? defaultThreshold;
  if (before > threshold && after <= threshold) {
    return recordAlert(client, item, location, after, threshold);
  }
  return null;
}

async function recordAlert(client, item, location, quantity, threshold) {
  await client.query(
    'INSERT INTO low_stock_alerts (item_id, location_id, quantity, threshold) VALUES ($1, $2, $3, $4)',
    [item.id, location.id, quantity, threshold],
  );
  return {
    itemId: item.id,
    itemName: item.name,
    locationId: location.id,
    locationName: location.name,
    locationType: location.type,
    quantity,
    threshold,
  };
}

async function insertMovement(client, { itemId, type, quantity, fromId = null, toId = null, note = null, uploadId = null }) {
  const { rows } = await client.query(
    `INSERT INTO stock_movements (item_id, type, quantity, from_location_id, to_location_id, note, upload_id)
     VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *`,
    [itemId, type, quantity, fromId, toId, note, uploadId],
  );
  return rows[0];
}

async function levelsFor(client, itemId, locationIds) {
  const { rows } = await client.query(
    `SELECT location_id, quantity FROM stock_levels WHERE item_id = $1 AND location_id = ANY($2)`,
    [itemId, locationIds],
  );
  return rows;
}

// Runs a stock change in a transaction, then sends any alerts after commit.
async function run(fn) {
  const { result, alerts } = await db.withTransaction(async (client) => {
    const alerts = [];
    const result = await fn(client, alerts);
    return { result, alerts };
  });
  await notifyLowStock(alerts);
  return { ...result, alerts };
}

// Receives stock inside an existing transaction (used by the item import too).
// Receiving only adds stock, so it never raises a low-stock alert.
async function receiveIn(client, { itemId, locationId, quantity, note, uploadId }) {
  const item = await getItem(client, itemId);
  const location = await getLocation(client, locationId ?? (await getMainLocationId(client)));
  const level = await lockLevel(client, item.id, location.id);
  await applyDelta(client, item, location, level, quantity, 0);
  const movement = await insertMovement(client, { itemId: item.id, type: 'receive', quantity, toId: location.id, note, uploadId });
  return { movement, levels: await levelsFor(client, item.id, [location.id]) };
}

function receive(args) {
  return run((client) => receiveIn(client, args));
}

// Moves stock inside an existing transaction (used by pasted transfer lists
// too). Returns any low-stock alert in alerts; the caller sends it after commit.
async function transferIn(client, { itemId, fromLocationId, toLocationId, quantity, note, uploadId }) {
  const item = await getItem(client, itemId);
  const fromId = fromLocationId ?? (await getMainLocationId(client));
  if (fromId === toLocationId) throw badRequest('Cannot transfer to the same location');
  const from = await getLocation(client, fromId);
  const to = await getLocation(client, toLocationId);
  const defaultThreshold = await getDefaultThreshold(client);

  // Lock rows in a fixed order so concurrent transfers can't deadlock.
  const [first, second] = from.id < to.id ? [from, to] : [to, from];
  const locked = {};
  locked[first.id] = await lockLevel(client, item.id, first.id);
  locked[second.id] = await lockLevel(client, item.id, second.id);

  const alert = await applyDelta(client, item, from, locked[from.id], -quantity, defaultThreshold);
  await applyDelta(client, item, to, locked[to.id], quantity, defaultThreshold);
  const movement = await insertMovement(client, {
    itemId: item.id, type: 'transfer', quantity, fromId: from.id, toId: to.id, note, uploadId,
  });
  return { movement, levels: await levelsFor(client, item.id, [from.id, to.id]), alerts: alert ? [alert] : [] };
}

function transfer(args) {
  return run(async (client, alerts) => {
    const { alerts: raised, ...result } = await transferIn(client, args);
    alerts.push(...raised);
    return result;
  });
}

// Records a sale inside an existing transaction (used by stock sheet uploads
// too). Returns any low-stock alert in alerts; the caller sends it after commit.
async function saleIn(client, { itemId, locationId, quantity, note, uploadId }) {
  const item = await getItem(client, itemId);
  const location = await getLocation(client, locationId);
  const level = await lockLevel(client, item.id, location.id);
  const alert = await applyDelta(client, item, location, level, -quantity, await getDefaultThreshold(client));
  const movement = await insertMovement(client, { itemId: item.id, type: 'sale', quantity, fromId: location.id, note, uploadId });
  return { movement, levels: await levelsFor(client, item.id, [location.id]), alerts: alert ? [alert] : [] };
}

function sale(args) {
  return run(async (client, alerts) => {
    const { alerts: raised, ...result } = await saleIn(client, args);
    alerts.push(...raised);
    return result;
  });
}

// Sets the counted quantity at a location (e.g. after a physical stock check).
function adjust({ itemId, locationId, newQuantity, note }) {
  return run(async (client, alerts) => {
    const item = await getItem(client, itemId);
    const location = await getLocation(client, locationId);
    const level = await lockLevel(client, item.id, location.id);
    const delta = newQuantity - level.quantity;
    if (delta === 0) return { movement: null, levels: await levelsFor(client, item.id, [location.id]) };
    const alert = await applyDelta(client, item, location, level, delta, await getDefaultThreshold(client));
    if (alert) alerts.push(alert);
    const movement = await insertMovement(client, {
      itemId: item.id,
      type: 'adjust',
      quantity: Math.abs(delta),
      fromId: delta < 0 ? location.id : null,
      toId: delta > 0 ? location.id : null,
      note,
    });
    return { movement, levels: await levelsFor(client, item.id, [location.id]) };
  });
}

// threshold null resets the level to the global default.
function setThreshold({ itemId, locationId, threshold }) {
  return run(async (client, alerts) => {
    const item = await getItem(client, itemId);
    const location = await getLocation(client, locationId);
    const level = await lockLevel(client, item.id, location.id);
    const defaultThreshold = await getDefaultThreshold(client);
    const before = level.threshold ?? defaultThreshold;
    const after = threshold ?? defaultThreshold;
    await client.query(
      'UPDATE stock_levels SET threshold = $3, updated_at = now() WHERE item_id = $1 AND location_id = $2',
      [item.id, location.id, threshold],
    );
    // Raising the alert level above the current stock counts as going low.
    if (level.quantity > before && level.quantity <= after) {
      alerts.push(await recordAlert(client, item, location, level.quantity, after));
    }
    return { item_id: item.id, location_id: location.id, quantity: level.quantity, threshold: after, uses_default: threshold === null };
  });
}

module.exports = { receive, receiveIn, sale, saleIn, transfer, transferIn, adjust, setThreshold, getDefaultThreshold, getMainLocationId };
