const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const ExcelJS = require('exceljs');
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

// Collects a binary response body into a Buffer.
function binary(res, done) {
  const chunks = [];
  res.on('data', (c) => chunks.push(c));
  res.on('end', () => done(null, Buffer.concat(chunks)));
}

async function loginHeader() {
  const res = await request(app).post('/auth/login').send({ password: 'test-password' });
  return `Bearer ${res.body.token}`;
}

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

test('exports one location as a sheet that reads back as a stock sheet', async () => {
  await api.post('/stock/receive', { item_id: itemId, quantity: 10 });
  await api.post('/stock/transfer', { item_id: itemId, to_location_id: branchId, quantity: 8 });
  await api.post('/items', { name: 'Sugar, white "1kg"' });

  const csv = await api.get(`/exports/stock?location_id=${branchId}&format=csv`);
  assert.equal(csv.status, 200);
  assert.match(csv.headers['content-type'], /text\/csv/);
  assert.match(csv.headers['content-disposition'], /filename="stock-kandy-branch-\d{4}-\d{2}-\d{2}\.csv"/);
  assert.equal(
    csv.text,
    '﻿Item name,SKU,Unit,Qty,Alert level,Low stock\r\n' +
      'Rice 5kg,RICE5,pcs,8,3,\r\n' +
      '"Sugar, white ""1kg""",,pcs,0,3,\r\n',
  );

  const xlsx = await api.get(`/exports/stock?location_id=${mainId}`).buffer(true).parse(binary);
  assert.equal(xlsx.status, 200);
  const preview = await request(app)
    .post(`/uploads/preview?filename=main.xlsx&location_id=${mainId}`)
    .set('Authorization', (await loginHeader()))
    .set('Content-Type', 'application/octet-stream')
    .send(xlsx.body);
  assert.equal(preview.status, 200);
  assert.deepEqual(preview.body.columns.stock.map((c) => c.header), ['Qty']);
  assert.deepEqual(preview.body.columns.ignored, ['Alert level', 'Low stock']);
  assert.equal(preview.body.new_items.length, 0);
  assert.equal(preview.body.changes.length, 0);
});

test('exports all locations, and the item list, as Excel or CSV', async () => {
  await api.post('/stock/receive', { item_id: itemId, quantity: 10 });
  await api.post('/stock/transfer', { item_id: itemId, to_location_id: branchId, quantity: 4 });

  const csv = await api.get('/exports/stock?format=csv');
  assert.equal(csv.text.split('\r\n')[0], '﻿Item name,SKU,Unit,Main Shop,Kandy Branch,Total');
  assert.equal(csv.text.split('\r\n')[1], 'Rice 5kg,RICE5,pcs,6,4,10');

  const xlsx = await api.get('/exports/stock').buffer(true).parse(binary);
  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.load(xlsx.body);
  assert.deepEqual(workbook.worksheets.map((s) => s.name), ['All locations', 'Main Shop', 'Kandy Branch']);
  assert.deepEqual(workbook.worksheets[0].getRow(2).values.slice(1), ['Rice 5kg', 'RICE5', 'pcs', 6, 4, 10]);

  const items = await api.get('/exports/items?format=csv');
  assert.match(items.headers['content-disposition'], /filename="items-/);
  assert.match(items.text.split('\r\n')[1], /^Rice 5kg,RICE5,pcs,10,\d{4}-\d{2}-\d{2}$/);

  assert.equal((await api.get('/exports/items?format=pdf')).status, 400);
  assert.equal((await api.get('/exports/stock?location_id=999')).status, 404);
});

test('changing the password signs out other phones and keeps this one signed in', async () => {
  const other = await api.get('/items');
  assert.equal(other.status, 200);

  const wrong = await api.post('/auth/password', { current_password: 'nope', new_password: 'new-secret' });
  assert.equal(wrong.status, 400);
  assert.equal(wrong.body.error, 'The current password is wrong');
  const short = await api.post('/auth/password', { current_password: 'test-password', new_password: 'abc' });
  assert.equal(short.status, 400);

  const res = await api.post('/auth/password', { current_password: 'test-password', new_password: 'new-secret' });
  assert.equal(res.status, 200);
  const fresh = { Authorization: `Bearer ${res.body.token}` };
  assert.equal((await request(app).get('/items').set(fresh)).status, 200);

  // The old token, and the old password, no longer work.
  const old = await api.get('/items');
  assert.equal(old.status, 401);
  assert.equal(old.body.error, 'The password was changed, sign in again');
  assert.equal((await request(app).post('/auth/login').send({ password: 'test-password' })).status, 401);
  const login = await request(app).post('/auth/login').send({ password: 'new-secret' });
  assert.equal(login.status, 200);
  assert.equal((await request(app).get('/items').set('Authorization', `Bearer ${login.body.token}`)).status, 200);

  // The stored password never shows up in settings.
  assert.deepEqual((await request(app).get('/settings').set(fresh)).body, { default_threshold: 3 });
});
