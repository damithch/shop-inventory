const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const ExcelJS = require('exceljs');
const { app, db, reset, client, sent } = require('./helpers');

let api;
let token;
let mainId;
let branchId;

const upload = (path, filename, body, query = {}) => request(app)
  .post(path)
  .query({ filename, ...query })
  .set('Authorization', `Bearer ${token}`)
  .set('Content-Type', 'application/octet-stream')
  .send(Buffer.from(body));

const itemByName = async (name) => (await api.get(`/items?q=${encodeURIComponent(name)}`)).body.find((i) => i.name === name);

before(reset);
beforeEach(async () => {
  await reset();
  api = await client();
  token = (await request(app).post('/auth/login').send({ password: 'test-password' })).body.token;
  mainId = (await api.get('/locations')).body[0].id;
  branchId = (await api.post('/locations', { name: 'Home' })).body.id;
});
after(async () => {
  await db.pool.end();
});

test('preview saves nothing, upload creates the items and stock', async () => {
  const sheet = 'Item name,Unit,Qty,Home\nRice,bag,10,4\nSalt,,0,\nTotal,,10,\n';
  const preview = await upload('/uploads/preview', 'morning.csv', sheet);
  assert.equal(preview.status, 200);
  assert.deepEqual(preview.body.summary, {
    new_items: 2, new_stock: 14, changed_items: 0, sold: 0, received: 0, unchanged_items: 0, skipped_rows: 1,
  });
  assert.deepEqual(preview.body.columns.stock.map((c) => c.location_name), ['Main Shop', 'Home']);
  assert.equal(preview.body.skipped[0].reason, 'totals row');
  assert.equal((await api.get('/items')).body.length, 0);

  const saved = await upload('/uploads', 'morning.csv', sheet);
  assert.equal(saved.status, 201);
  const rice = await itemByName('Rice');
  assert.equal(rice.unit, 'bag');
  assert.equal(rice.total_quantity, 14);
  const history = (await api.get('/uploads')).body;
  assert.equal(history[0].filename, 'morning.csv');
  const moves = (await api.get(`/stock/movements?item_id=${rice.id}`)).body;
  assert.ok(moves.every((m) => m.type === 'receive' && m.upload_id === history[0].id));
});

test('an end-of-day sheet records drops as sales and rises as received', async () => {
  await upload('/uploads', 'morning.csv', 'Item,Qty\nRice,10\nSalt,8\nSoap,5\nTea,6\n');
  // Rice sold 3, Salt restocked to 12, Soap blank (not counted), Tea missing from the sheet.
  const evening = 'Item,Qty\nRice,7\nSalt,12\nSoap,\n';
  const preview = (await upload('/uploads/preview', 'evening.csv', evening)).body;
  assert.equal(preview.summary.sold, 3);
  assert.equal(preview.summary.received, 4);
  assert.equal(preview.summary.unchanged_items, 1);
  assert.deepEqual(preview.changes.map((c) => [c.item_name, c.from, c.to]), [['Rice', 10, 7], ['Salt', 8, 12]]);

  const saved = (await upload('/uploads', 'evening.csv', evening)).body;
  assert.equal(saved.summary.sold, 3);
  assert.equal((await itemByName('Rice')).main_quantity, 7);
  assert.equal((await itemByName('Salt')).main_quantity, 12);
  assert.equal((await itemByName('Soap')).main_quantity, 5);
  assert.equal((await itemByName('Tea')).main_quantity, 6);

  const sales = (await api.get('/reports/sales')).body;
  assert.equal(sales.total, 3);
  assert.deepEqual(sales.items.map((s) => [s.item_name, s.location_name, s.quantity]), [['Rice', 'Main Shop', 3]]);
});

test('sales from the app count too, and the report is per day', async () => {
  await upload('/uploads', 'morning.csv', 'Item,Qty\nRice,10\n');
  const rice = await itemByName('Rice');
  await api.post('/stock/sale', { item_id: rice.id, location_id: mainId, quantity: 2 });
  await db.query("UPDATE stock_movements SET created_at = '2026-01-01 12:00+05:30' WHERE type = 'sale'");
  await api.post('/stock/sale', { item_id: rice.id, location_id: mainId, quantity: 1 });

  assert.equal((await api.get('/reports/sales')).body.total, 1);
  const jan = (await api.get('/reports/sales?date=2026-01-01')).body;
  assert.equal(jan.date, '2026-01-01');
  assert.equal(jan.total, 2);
  assert.equal((await api.get(`/reports/sales?location_id=${branchId}`)).body.total, 0);
  assert.equal((await api.get('/reports/sales?date=yesterday')).status, 400);
});

test('a drop to the alert level sends a low-stock alert', async () => {
  await upload('/uploads', 'morning.csv', 'Item,Qty\nRice,10\n');
  const res = await upload('/uploads', 'evening.csv', 'Item,Qty\nRice,2\n');
  assert.equal(res.body.alerts.length, 1);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].itemName, 'Rice');
});

test('matches names ignoring spacing and flags look-alike new items', async () => {
  await upload('/uploads', 'shop.csv', 'Item,Qty\nAFNAN 9 AM,3\nRASASI HAWAS ICE 100 ML,5\n');
  const res = (await upload('/uploads/preview', 'home.csv', 'Item,Qty\nafnan 9am,2\nHAWAS ICE,69\n')).body;
  assert.deepEqual(res.changes.map((c) => [c.item_name, c.to]), [['AFNAN 9 AM', 2]]);
  assert.deepEqual(res.new_items.map((i) => [i.name, i.similar_to]), [['HAWAS ICE', ['RASASI HAWAS ICE 100 ML']]]);
});

test('a plain quantity column can be for a branch', async () => {
  const res = await upload('/uploads', 'home.csv', 'Item,Qty\nRice,4\n', { location_id: branchId });
  assert.equal(res.status, 201);
  const rice = await itemByName('Rice');
  assert.equal(rice.main_quantity, 0);
  assert.equal(rice.total_quantity, 4);
});

test('each place uploads its own sheet and its sales are recorded there', async () => {
  await upload('/uploads', 'home.csv', 'Item,Qty\nRice,10\n');
  await upload('/uploads', 'branch.csv', 'Item,Qty\nRice,6\n', { location_id: branchId });
  await upload('/uploads', 'branch-evening.csv', 'Item,Qty\nRice,4\n', { location_id: branchId });
  await upload('/uploads', 'home-evening.csv', 'Item,Qty\nRice,9\n');

  const rice = await itemByName('Rice');
  assert.equal(rice.main_quantity, 9);
  assert.equal(rice.total_quantity, 13);
  const all = (await api.get('/reports/sales')).body;
  assert.deepEqual(all.items.map((s) => [s.location_name, s.quantity]), [['Home', 2], ['Main Shop', 1]]);
  assert.equal((await api.get(`/reports/sales?location_id=${branchId}`)).body.total, 2);
});

test('reads an Excel sheet with no header row', async () => {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Home');
  ws.addRow([]);
  ws.addRow(['', '', '', 'STOCK STATUS AT HOME -- 06 OCT']);
  ws.addRow([]);
  ws.addRow([]);
  ws.addRow(['', '', '', 'AFNAN 9AM', 2]);
  ws.addRow(['', '', '', 'HAWAS ICE ', 69]);
  ws.addRow(['', '', '', 'YARA', 15]);
  const file = await wb.xlsx.writeBuffer();
  const res = await upload('/uploads/preview', 'STOCK STATUS.xlsx', file, { location_id: branchId });
  assert.equal(res.status, 200);
  assert.match(res.body.notes[0], /column D as the item name and column E as the quantity/);
  assert.deepEqual(res.body.new_items.map((i) => [i.name, i.stock[0].quantity, i.stock[0].location_name]),
    [['AFNAN 9AM', 2, 'Home'], ['HAWAS ICE', 69, 'Home'], ['YARA', 15, 'Home']]);
  assert.equal(res.body.skipped.length, 0);
});

test('rejects files it cannot read', async () => {
  assert.equal((await upload('/uploads/preview', 'list.pdf', 'x')).status, 400);
  assert.equal((await upload('/uploads/preview', 'list.xlsx', 'not a workbook')).status, 400);
  assert.equal((await upload('/uploads/preview', 'list.csv', 'a,b\n1,2\n')).status, 400);
  assert.equal((await upload('/uploads/preview', '', 'Item,Qty\nRice,1\n')).status, 400);
  assert.equal((await request(app).post('/uploads/preview?filename=a.csv').send('x')).status, 401);
});
