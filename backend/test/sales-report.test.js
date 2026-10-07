const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { PDFDocument } = require('pdf-lib');
const { app, db, reset, client } = require('./helpers');
const { salesPdf } = require('../src/services/sales-pdf');

let api;
let shopId;
let otherId;

const itemByName = async (name) => (await api.get(`/items?q=${encodeURIComponent(name)}`)).body.find((i) => i.name === name);

before(reset);
beforeEach(async () => {
  await reset();
  api = await client();
  shopId = (await api.post('/locations', { name: 'Kandy Branch' })).body.id;
  otherId = (await api.post('/locations', { name: 'Dehiwala' })).body.id;
  await api.post('/paste', { action: 'receive', text: 'DIOR SAUVAGE 10\nARMAF CLUB 10\nYARA 10' });
  await api.post('/paste', { action: 'transfer', text: 'DIOR SAUVAGE 5\nARMAF CLUB 5\nYARA 5', to_location_id: shopId });
  await api.post('/paste', { action: 'transfer', text: 'YARA 5', to_location_id: otherId });
});
after(async () => {
  await db.pool.end();
});

test('an end-of-day sales list with prices adds up the day in rupees and remembers the prices', async () => {
  const dior = await itemByName('DIOR SAUVAGE');
  const armaf = await itemByName('ARMAF CLUB');
  await api.patch(`/items/${armaf.id}`, { price: '18,500' });
  const text = '[07/10/2026, 8:40 pm] Nimal: 1. DIOR SAUVAGE 2\n2. ARMAF CLUB x1\nYARA - 3';

  const preview = (await api.post('/paste/preview', {
    action: 'sale', text, location_id: shopId, prices: { [dior.id]: 25000 },
  })).body;
  const byName = Object.fromEntries(preview.lines.map((l) => [l.item_name, l]));
  assert.equal(byName['DIOR SAUVAGE'].price, 25000);
  assert.equal(byName['ARMAF CLUB'].price, 18500);
  assert.equal(byName.YARA.price, null);
  assert.equal(preview.summary.amount, 68500);
  assert.equal(preview.summary.unpriced_units, 3);

  const saved = await api.post('/paste', { action: 'sale', text, location_id: shopId, prices: { [dior.id]: 25000 } });
  assert.equal(saved.status, 201);
  assert.equal((await itemByName('DIOR SAUVAGE')).price, 25000);

  const report = (await api.get(`/reports/sales?location_id=${shopId}`)).body;
  assert.equal(report.location_name, 'Kandy Branch');
  assert.equal(report.total, 6);
  assert.equal(report.total_amount, 68500);
  assert.equal(report.unpriced_units, 3);
  const line = report.items.find((i) => i.item_name === 'DIOR SAUVAGE');
  assert.deepEqual([line.quantity, line.unit_price, line.amount], [2, 25000, 50000]);
  assert.equal(report.items.find((i) => i.item_name === 'YARA').amount, null);

  // A later price change doesn't change what that day's sales were worth.
  await api.patch(`/items/${dior.id}`, { price: 30000 });
  assert.equal((await api.get(`/reports/sales?location_id=${shopId}`)).body.total_amount, 68500);

  assert.equal((await api.post('/paste/preview', { action: 'sale', text, location_id: shopId, prices: { [dior.id]: -1 } })).status, 400);
  assert.equal((await api.post('/paste/preview', { action: 'receive', text, prices: { [dior.id]: 1 } })).status, 400);
  assert.equal((await api.patch(`/items/${dior.id}`, { price: 'abc' })).status, 400);
});

test('the day report downloads as a PDF for one branch or every place, today or a past day', async () => {
  await api.post('/paste', { action: 'sale', text: 'DIOR SAUVAGE 2\nYARA 1', location_id: shopId });
  await api.post('/paste', { action: 'sale', text: 'YARA 2', location_id: otherId });
  const token = (await request(app).post('/auth/login').send({ password: 'test-password' })).body.token;
  const get = (url) => request(app).get(url).set('Authorization', `Bearer ${token}`).buffer(true)
    .parse((res, cb) => { const chunks = []; res.on('data', (c) => chunks.push(c)); res.on('end', () => cb(null, Buffer.concat(chunks))); });

  const { date } = (await api.get('/reports/sales')).body;
  const branch = await get(`/reports/sales/pdf?location_id=${shopId}&date=${date}`);
  assert.equal(branch.status, 200);
  assert.equal(branch.headers['content-type'], 'application/pdf');
  assert.match(branch.headers['content-disposition'], new RegExp(`sales-kandy-branch-${date}\\.pdf`));
  assert.equal(branch.body.subarray(0, 5).toString(), '%PDF-');
  assert.equal((await PDFDocument.load(branch.body)).getPageCount(), 1);

  const all = await get('/reports/sales/pdf?date=2026-01-01');
  assert.equal(all.status, 200);
  assert.match(all.headers['content-disposition'], /sales-all-2026-01-01\.pdf/);

  assert.equal((await api.get('/reports/sales/pdf?date=yesterday')).status, 400);
  assert.equal((await api.get('/reports/sales/pdf?location_id=999')).status, 404);
});

test('a long list runs onto more pages, and names Helvetica cannot draw still make a PDF', async () => {
  const items = Array.from({ length: 90 }, (_, i) => ({
    item_id: i + 1, item_name: i === 0 ? 'සබන් Soap → 100g' : `Item ${i + 1} with a rather long name that will not fit in the column at all`,
    unit: 'pcs', location_id: 1 + (i % 2), location_name: i % 2 ? 'Kandy' : 'Dehiwala',
    quantity: 2, unit_price: i % 3 ? 100 : null, amount: i % 3 ? 200 : null,
  }));
  const bytes = await salesPdf({
    date: '2026-10-07', location_name: null, total: 180, total_amount: 12000, unpriced_units: 60, items,
  }, { generatedAt: '7 Oct 2026, 9:00 pm' });
  assert.ok((await PDFDocument.load(bytes)).getPageCount() >= 3);
});
