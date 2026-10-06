const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { app, db, reset, client, sent } = require('./helpers');

let api;
let mainId;
let branchId;
let itemId;

before(async () => {
  await reset();
});

beforeEach(async () => {
  await reset();
  api = await client();
  mainId = (await api.get('/locations')).body[0].id;
  branchId = (await api.post('/locations', { name: 'Kandy Branch' })).body.id;
  itemId = (await api.post('/items', { name: 'Rice 5kg', sku: 'RICE5' })).body.id;
});

after(async () => {
  await db.pool.end();
});

test('rejects requests without a valid login', async () => {
  assert.equal((await request(app).get('/items')).status, 401);
  assert.equal((await request(app).post('/auth/login').send({ password: 'nope' })).status, 401);
});

test('a main shop exists from the start and cannot be archived', async () => {
  const locations = (await api.get('/locations')).body;
  assert.equal(locations[0].type, 'main');
  assert.equal((await api.patch(`/locations/${mainId}`, { archived: true })).status, 400);
});

test('receive adds to the main shop by default', async () => {
  const res = await api.post('/stock/receive', { item_id: itemId, quantity: 20 });
  assert.equal(res.status, 201);
  const item = (await api.get(`/items/${itemId}`)).body;
  assert.equal(item.stock.find((s) => s.location_id === mainId).quantity, 20);
});

test('transfer moves stock from main to a branch and keeps totals', async () => {
  await api.post('/stock/receive', { item_id: itemId, quantity: 20 });
  const res = await api.post('/stock/transfer', { item_id: itemId, to_location_id: branchId, quantity: 8 });
  assert.equal(res.status, 201);
  const items = (await api.get('/items')).body;
  assert.equal(items[0].main_quantity, 12);
  assert.equal(items[0].total_quantity, 20);
  const branch = (await api.get(`/locations/${branchId}/stock`)).body;
  assert.equal(branch.items[0].quantity, 8);
});

test('cannot move or sell more than is in stock', async () => {
  await api.post('/stock/receive', { item_id: itemId, quantity: 5 });
  const res = await api.post('/stock/transfer', { item_id: itemId, to_location_id: branchId, quantity: 6 });
  assert.equal(res.status, 409);
  assert.equal((await api.post('/stock/sale', { item_id: itemId, location_id: branchId, quantity: 1 })).status, 409);
  const item = (await api.get(`/items/${itemId}`)).body;
  assert.equal(item.stock.find((s) => s.location_id === mainId).quantity, 5);
  assert.equal((await api.get('/stock/movements')).body.length, 1);
});

test('alerts once when a branch drops to the default level of 3', async () => {
  await api.post('/stock/receive', { item_id: itemId, quantity: 20 });
  await api.post('/stock/transfer', { item_id: itemId, to_location_id: branchId, quantity: 10 });
  assert.equal(sent.length, 0);

  const res = await api.post('/stock/sale', { item_id: itemId, location_id: branchId, quantity: 7 });
  assert.equal(res.body.alerts.length, 1);
  assert.deepEqual(
    { location: sent[0].locationName, quantity: sent[0].quantity, threshold: sent[0].threshold },
    { location: 'Kandy Branch', quantity: 3, threshold: 3 },
  );

  // Already low: selling more does not alert again.
  await api.post('/stock/sale', { item_id: itemId, location_id: branchId, quantity: 1 });
  assert.equal(sent.length, 1);

  const low = (await api.get('/stock/low')).body;
  assert.equal(low.length, 1);
  assert.equal(low[0].quantity, 2);
  assert.equal((await api.get('/alerts')).body.length, 1);

  // Refilled above the level, then dropping again alerts again.
  await api.post('/stock/transfer', { item_id: itemId, to_location_id: branchId, quantity: 5 });
  await api.post('/stock/sale', { item_id: itemId, location_id: branchId, quantity: 4 });
  assert.equal(sent.length, 2);
});

test('main shop dropping low through a transfer alerts for the main shop', async () => {
  await api.post('/stock/receive', { item_id: itemId, quantity: 10 });
  await api.post('/stock/transfer', { item_id: itemId, to_location_id: branchId, quantity: 7 });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].locationId, mainId);
});

test('per-item thresholds and the global default are editable', async () => {
  await api.post('/stock/receive', { item_id: itemId, quantity: 20 });
  await api.post('/stock/transfer', { item_id: itemId, to_location_id: branchId, quantity: 10 });

  const set = await api.put('/stock/threshold', { item_id: itemId, location_id: branchId, threshold: 5 });
  assert.equal(set.body.threshold, 5);
  await api.post('/stock/sale', { item_id: itemId, location_id: branchId, quantity: 5 });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].threshold, 5);

  assert.equal((await api.put('/settings', { default_threshold: 2 })).body.default_threshold, 2);
  const reset = await api.put('/stock/threshold', { item_id: itemId, location_id: branchId, threshold: null });
  assert.equal(reset.body.threshold, 2);
  assert.equal(reset.body.uses_default, true);
});

test('raising a threshold above current stock raises an alert', async () => {
  await api.post('/stock/receive', { item_id: itemId, quantity: 6 });
  await api.put('/stock/threshold', { item_id: itemId, location_id: mainId, threshold: 10 });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].quantity, 6);
});

test('adjust sets the counted quantity and records the difference', async () => {
  await api.post('/stock/receive', { item_id: itemId, quantity: 10 });
  const res = await api.post('/stock/adjust', { item_id: itemId, location_id: mainId, new_quantity: 7, note: 'stock check' });
  assert.equal(res.body.movement.quantity, 3);
  assert.equal(res.body.movement.from_location_id, mainId);
  assert.equal(res.body.levels[0].quantity, 7);
});

test('movement history can be filtered by location', async () => {
  await api.post('/stock/receive', { item_id: itemId, quantity: 10 });
  await api.post('/stock/transfer', { item_id: itemId, to_location_id: branchId, quantity: 4 });
  await api.post('/stock/sale', { item_id: itemId, location_id: branchId, quantity: 1 });
  const all = (await api.get('/stock/movements')).body;
  assert.deepEqual(all.map((m) => m.type), ['sale', 'transfer', 'receive']);
  const branch = (await api.get(`/stock/movements?location_id=${branchId}`)).body;
  assert.equal(branch.length, 2);
});

test('concurrent sales never oversell', async () => {
  await api.post('/stock/receive', { item_id: itemId, quantity: 5 });
  const results = await Promise.all(
    Array.from({ length: 8 }, () => api.post('/stock/sale', { item_id: itemId, location_id: mainId, quantity: 1 })),
  );
  assert.equal(results.filter((r) => r.status === 201).length, 5);
  assert.equal(results.filter((r) => r.status === 409).length, 3);
  const item = (await api.get(`/items/${itemId}`)).body;
  assert.equal(item.stock.find((s) => s.location_id === mainId).quantity, 0);
});

test('validates input', async () => {
  assert.equal((await api.post('/stock/receive', { item_id: itemId, quantity: -1 })).status, 400);
  assert.equal((await api.post('/stock/receive', { item_id: 999, quantity: 1 })).status, 404);
  assert.equal((await api.post('/items', { name: '' })).status, 400);
  assert.equal((await api.post('/items', { name: 'Dup', sku: 'RICE5' })).status, 409);
  assert.equal((await api.post('/locations', { name: 'Kandy Branch' })).status, 409);
  assert.equal(
    (await api.post('/stock/transfer', { item_id: itemId, from_location_id: mainId, to_location_id: mainId, quantity: 1 })).status,
    400,
  );
});

test('registers device tokens for push', async () => {
  assert.equal((await api.post('/devices', { token: 'abc' })).status, 201);
  assert.equal((await api.post('/devices', { token: 'abc' })).status, 201);
  const { rows } = await db.query('SELECT * FROM device_tokens');
  assert.equal(rows.length, 1);
});
