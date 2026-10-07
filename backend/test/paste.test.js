const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { db, reset, client, sent } = require('./helpers');
const { parsePaste } = require('../src/import/paste');

let api;
let mainId;
let shopId;

const itemByName = async (name) => (await api.get(`/items?q=${encodeURIComponent(name)}`)).body.find((i) => i.name === name);
const stockAt = async (name, locationId) => {
  const item = await itemByName(name);
  const detail = (await api.get(`/items/${item.id}`)).body;
  return detail.stock.find((s) => s.location_id === locationId)?.quantity ?? 0;
};

before(reset);
beforeEach(async () => {
  await reset();
  api = await client();
  mainId = (await api.get('/locations')).body[0].id;
  shopId = (await api.post('/locations', { name: 'Kollupitiya' })).body.id;
});
after(async () => {
  await db.pool.end();
});

test('reads Excel rows, WhatsApp messages and plain lines', () => {
  const text = [
    'Item\tQty\tPrice',
    'DIOR SAUVAGE\t2\t25000',
    'ARMAF CLUB   2   18500',
    '[06/10/2026, 9:15 am] Nimal: 3. LATTAFA ASAD 4 pcs',
    'AFNAN 9AM - 2',
    'RASASI MAX x 3',
    '* YARA x 3',
    '2 x CLUB DE NUIT',
    'ARMAF 200 ML',
    'Total 16',
    'Soap 0',
  ].join('\n');
  const { rows, skipped } = parsePaste(text);
  assert.deepEqual(rows.map((r) => [r.name, r.quantity]), [
    ['DIOR SAUVAGE', 2], ['ARMAF CLUB', 2], ['LATTAFA ASAD', 4], ['AFNAN 9AM', 2], ['RASASI MAX', 3], ['YARA', 3], ['CLUB DE NUIT', 2],
  ]);
  assert.deepEqual(skipped.map((s) => [s.line, s.reason]), [
    [1, 'looks like a heading'], [9, 'no quantity on this line'], [10, 'totals row'], [11, 'quantity is 0'],
  ]);
});

test('a pasted purchase adds stock at the main shop and creates new items', async () => {
  const body = { action: 'receive', text: 'Rice\t10\nSalt - 4\nRice 2' };
  const preview = await api.post('/paste/preview', body);
  assert.equal(preview.status, 200);
  assert.equal(preview.body.to.location_id, mainId);
  assert.deepEqual(preview.body.lines.map((l) => [l.name, l.quantity, l.new_item, l.lines]), [
    ['Rice', 12, true, [1, 3]], ['Salt', 4, true, [2]],
  ]);
  assert.equal(preview.body.summary.received, 16);
  assert.equal((await api.get('/items')).body.length, 0);

  const saved = await api.post('/paste', body);
  assert.equal(saved.status, 201);
  assert.equal(saved.body.filename, 'Pasted purchase (Main Shop)');
  assert.equal(await stockAt('Rice', mainId), 12);

  await api.post('/paste', { action: 'receive', text: 'rice 3', location_id: shopId });
  assert.equal(await stockAt('Rice', shopId), 3);
  assert.equal((await api.get('/items')).body.length, 2);
  const history = (await api.get('/uploads')).body;
  assert.equal(history.length, 2);
});

test('a pasted transfer moves stock from the main shop to the branch', async () => {
  await api.post('/paste', { action: 'receive', text: 'Rice 10\nSalt 1' });
  const body = { action: 'transfer', text: 'Rice 4\nSalt 5\nSugar 1', to_location_id: shopId };
  const preview = (await api.post('/paste/preview', body)).body;
  assert.deepEqual(preview.lines.map((l) => [l.item_name, l.quantity]), [['Rice', 4]]);
  assert.deepEqual(preview.skipped.map((s) => s.reason), ['only 1 at Main Shop, 5 asked for', 'not in the app']);

  const saved = await api.post('/paste', body);
  assert.equal(saved.status, 201);
  assert.equal(saved.body.filename, 'Pasted transfer (Main Shop → Kollupitiya)');
  assert.equal(await stockAt('Rice', mainId), 6);
  assert.equal(await stockAt('Rice', shopId), 4);
  assert.equal(await stockAt('Salt', mainId), 1);

  const same = await api.post('/paste/preview', { ...body, to_location_id: mainId });
  assert.equal(same.status, 400);
  assert.equal((await api.post('/paste/preview', { action: 'transfer', text: 'Rice 1' })).status, 400);
});

test('a pasted sale takes stock off the shop and shows in the sales report', async () => {
  await api.post('/paste', { action: 'receive', text: 'Rice 5\nRice Flour 2', location_id: shopId });

  const preview = (await api.post('/paste/preview', { action: 'sale', text: 'Rice 3\nRice Floor 1', location_id: shopId })).body;
  assert.match(preview.skipped[0].reason, /Did you mean: Rice Flour/);

  const saved = await api.post('/paste', { action: 'sale', text: 'Rice 3', location_id: shopId });
  assert.equal(saved.status, 201);
  assert.equal(await stockAt('Rice', shopId), 2);
  assert.equal(saved.body.alerts.length, 1);
  assert.equal(sent[0].itemName, 'Rice');
  const report = (await api.get('/reports/sales')).body;
  assert.equal(report.total, 3);

  assert.equal((await api.post('/paste', { action: 'sale', text: 'Rice 3', location_id: shopId })).status, 400);
  assert.equal((await api.post('/paste/preview', { action: 'sale', text: 'Rice 1' })).status, 400);
  assert.equal((await api.post('/paste/preview', { action: 'refund', text: 'Rice 1' })).status, 400);
});

test('a bulk move list names the branch on its first line, and unknown names can be picked', async () => {
  const dehiwala = (await api.post('/locations', { name: 'Dehiwala' })).body.id;
  await api.post('/paste', { action: 'receive', text: 'PACIFIC AURA 100 ML 5\nRASASI HAWAS ICE 100 ML 4\nANGHAM 3', location_id: shopId });
  const aura = await itemByName('PACIFIC AURA 100 ML');
  const text = 'Dehiwela\n\nPacific aura 2\nHawas ice 2\nAngham 1\n\nTotal 5..';
  const body = { action: 'transfer', text, location_id: shopId };

  const preview = (await api.post('/paste/preview', body)).body;
  assert.equal(preview.to.location_id, dehiwala);
  assert.deepEqual(preview.lines.map((l) => [l.item_name, l.quantity]), [['ANGHAM', 1]]);
  assert.deepEqual(preview.skipped.map((s) => s.reason.split('.')[0]), [
    'place name (Dehiwala)', 'not in the app', 'not in the app', 'totals row',
  ]);
  assert.deepEqual(preview.skipped[1].similar_ids, [aura.id]);

  const matches = { 'Pacific aura': aura.id, 'Hawas ice': (await itemByName('RASASI HAWAS ICE 100 ML')).id };
  const saved = await api.post('/paste', { ...body, matches });
  assert.equal(saved.status, 201);
  assert.equal(saved.body.summary.transferred, 5);
  assert.equal(await stockAt('PACIFIC AURA 100 ML', dehiwala), 2);
  assert.equal(await stockAt('RASASI HAWAS ICE 100 ML', shopId), 2);

  // Remembered: the same list matches by itself next time.
  const again = (await api.post('/paste/preview', body)).body;
  assert.deepEqual(again.lines.map((l) => l.item_name), ['PACIFIC AURA 100 ML', 'RASASI HAWAS ICE 100 ML', 'ANGHAM']);
  assert.equal((await api.post('/paste/preview', { ...body, matches: ['x'] })).status, 400);
});
