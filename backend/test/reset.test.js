const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { db, reset, client, sent } = require('./helpers');

process.env.RESET_ENABLED = 'true';

let api;
let mainId;
let branchId;
let rice;
let soap;

const password = 'test-password';

before(async () => {
  await reset();
});

beforeEach(async () => {
  await reset();
  api = await client();
  mainId = (await api.get('/locations')).body[0].id;
  branchId = (await api.post('/locations', { name: 'Kandy Branch' })).body.id;
  rice = (await api.post('/items', { name: 'Rice 5kg', sku: 'RICE5' })).body.id;
  soap = (await api.post('/items', { name: 'Soap', sku: 'SOAP' })).body.id;
  await api.post('/stock/receive', { item_id: rice, quantity: 20 });
  await api.post('/stock/receive', { item_id: soap, quantity: 10 });
  await api.post('/stock/transfer', { item_id: rice, to_location_id: branchId, quantity: 8 });
  await api.post('/stock/sale', { item_id: rice, location_id: branchId, quantity: 2 });
  sent.length = 0;
});

after(async () => {
  await db.pool.end();
});

async function qty(itemId, locationId) {
  const { rows } = await db.query('SELECT quantity FROM stock_levels WHERE item_id = $1 AND location_id = $2', [itemId, locationId]);
  return rows[0]?.quantity ?? 0;
}

test('every reset needs the right password, and a wrong one does not sign out', async () => {
  assert.equal((await api.post('/reset/stock', {})).status, 400);
  const wrong = await api.post('/reset/stock', { password: 'nope' });
  assert.equal(wrong.status, 403);
  assert.equal(wrong.body.error, 'The password is wrong');
  assert.equal(await qty(rice, mainId), 12);
  assert.equal((await api.get('/items')).status, 200);
});

test('a dry run checks the password and says what would change, without changing it', async () => {
  const res = await api.post('/reset/stock', { password, location_id: mainId, dry_run: true });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body, { items: 2, units: 22, location: 'Main Shop', dry_run: true });
  assert.equal(await qty(rice, mainId), 12);
  const { rows } = await db.query("SELECT COUNT(*)::int AS n FROM stock_movements WHERE note = 'Reset to zero'");
  assert.equal(rows[0].n, 0);
});

test('resetting one place zeroes only there, records it, and sends no alerts', async () => {
  const res = await api.post('/reset/stock', { password, location_id: branchId });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body, { items: 1, units: 6, location: 'Kandy Branch', dry_run: false });
  assert.equal(await qty(rice, branchId), 0);
  assert.equal(await qty(rice, mainId), 12);
  assert.equal(sent.length, 0);
  const { rows } = await db.query(
    "SELECT type, quantity, from_location_id, note FROM stock_movements WHERE note = 'Reset to zero'",
  );
  assert.deepEqual(rows, [{ type: 'adjust', quantity: 6, from_location_id: branchId, note: 'Reset to zero' }]);
});

test('resetting everywhere keeps items and sales history', async () => {
  const res = await api.post('/reset/stock', { password });
  assert.deepEqual(res.body, { items: 2, units: 28, location: null, dry_run: false });
  for (const item of [rice, soap]) {
    for (const loc of [mainId, branchId]) assert.equal(await qty(item, loc), 0);
  }
  assert.equal((await api.get('/items')).body.length, 2);
  const sales = (await api.get('/reports/sales')).body;
  assert.equal(sales.total, 2);
  // Nothing left to reset.
  assert.deepEqual((await api.post('/reset/stock', { password })).body, { items: 0, units: 0, location: null, dry_run: false });
});

test('deleting an item zeroes it everywhere, hides it and frees its SKU and name', async () => {
  await db.query("INSERT INTO item_aliases (name_key, name, item_id) VALUES ('rice', 'Rice', $1)", [rice]);
  const res = await api.post('/reset/delete-item', { password, item_id: rice });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body, { items: 1, units: 18, deleted_items: 1, item: 'Rice 5kg', dry_run: false });
  assert.equal(await qty(rice, branchId), 0);
  assert.deepEqual((await api.get('/items')).body.map((i) => i.name), ['Soap']);
  assert.equal((await db.query('SELECT COUNT(*)::int AS n FROM item_aliases')).rows[0].n, 0);
  // Its sale still shows in the report, under its name.
  assert.equal((await api.get('/reports/sales')).body.items[0].item_name, 'Rice 5kg');
  // The SKU can be used again, and a new item with the same name takes its place in pasted lists.
  const again = await api.post('/items', { name: 'Rice 5kg', sku: 'RICE5' });
  assert.equal(again.status, 201);
  const preview = await api.post('/paste/preview', { action: 'receive', text: 'Rice 5kg 1' });
  assert.equal(preview.status, 200);
  assert.equal(preview.body.lines[0].item_id, again.body.id);
  // Deleting it twice is not found.
  assert.equal((await api.post('/reset/delete-item', { password, item_id: rice })).status, 404);
});

test('deleting all items leaves the places', async () => {
  const res = await api.post('/reset/delete-all-items', { password });
  assert.deepEqual(res.body, { items: 2, units: 28, deleted_items: 2, dry_run: false });
  assert.deepEqual((await api.get('/items')).body, []);
  assert.equal((await api.get('/locations')).body.length, 2);
});

test('deleting a branch zeroes and hides it, and its name can be used again', async () => {
  const res = await api.post('/reset/delete-branch', { password, location_id: branchId });
  assert.deepEqual(res.body, { items: 1, units: 6, location: 'Kandy Branch', dry_run: false });
  assert.equal(await qty(rice, branchId), 0);
  assert.deepEqual((await api.get('/locations')).body.map((l) => l.name), ['Main Shop']);
  const all = (await api.get('/locations?include_archived=true')).body;
  assert.match(all.find((l) => l.id === branchId).name, /^Kandy Branch \(deleted \d{4}-\d{2}-\d{2}\)$/);
  const again = await api.post('/locations', { name: 'Kandy Branch' });
  assert.equal(again.status, 201);
  // A second branch of the same name deleted the same day still gets a free name.
  assert.equal((await api.post('/reset/delete-branch', { password, location_id: again.body.id })).status, 200);
  // The sale made there still shows in the report.
  assert.equal((await api.get('/reports/sales')).body.total, 2);
});

test('the main shop cannot be deleted', async () => {
  const res = await api.post('/reset/delete-branch', { password, location_id: mainId });
  assert.equal(res.status, 400);
  assert.equal(await qty(rice, mainId), 12);
});

test('every reset endpoint is refused while RESET_ENABLED is off', async () => {
  delete process.env.RESET_ENABLED;
  try {
    const calls = [
      api.get('/reset/backup'),
      api.post('/reset/stock', { password, dry_run: true }),
      api.post('/reset/delete-item', { password, item_id: rice }),
      api.post('/reset/delete-all-items', { password }),
      api.post('/reset/delete-branch', { password, location_id: branchId }),
    ];
    for (const res of await Promise.all(calls)) {
      assert.equal(res.status, 403);
      assert.equal(res.body.error, 'Reset and delete is turned off');
    }
    assert.equal(await qty(rice, mainId), 12);
    assert.equal((await api.get('/items')).body.length, 2);
  } finally {
    process.env.RESET_ENABLED = 'true';
  }
});
