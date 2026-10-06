const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');
const { promisify } = require('util');
const { db, reset, client } = require('./helpers');
const { readTable, findHeaderRow, mapColumns, planImport, loadContext, applyPlan } = require('../src/import/items');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'import-test-'));
let api;

function writeCsv(name, text) {
  const file = path.join(tmp, name);
  fs.writeFileSync(file, text);
  return file;
}

async function planFor(file, overrides = {}) {
  const rows = await readTable(file);
  const headerIndex = findHeaderRow(rows, overrides);
  const { locations, items } = await loadContext(db);
  const { mapping, errors } = mapColumns(rows[headerIndex], locations, overrides);
  return { rows, headerIndex, mapping, errors, plan: errors.length ? null : planImport(rows, headerIndex, mapping, items) };
}

before(reset);
beforeEach(async () => {
  await reset();
  api = await client();
  await api.post('/locations', { name: 'Kandy Branch' });
});
after(async () => {
  fs.rmSync(tmp, { recursive: true, force: true });
  await db.pool.end();
});

test('imports the sample template with stock as receive movements', async () => {
  const { plan } = await planFor(path.join(__dirname, '..', 'templates', 'items-template.xlsx'));
  assert.equal(plan.create.length, 3);
  assert.equal(plan.skipped.length, 0);
  await db.withTransaction((c) => applyPlan(c, plan, { note: 'Imported from test' }));

  const items = (await api.get('/items')).body;
  const rice = items.find((i) => i.sku === 'RICE5');
  assert.equal(rice.unit, 'bag');
  assert.equal(rice.main_quantity, 20);
  assert.equal(rice.total_quantity, 25);
  const moves = (await api.get(`/stock/movements?item_id=${rice.id}`)).body;
  assert.deepEqual(moves.map((m) => m.type), ['receive', 'receive']);
  assert.equal(moves[0].note, 'Imported from test');
});

test('matches loosely named columns and finds the header below title rows', async () => {
  const file = writeCsv('loose.csv', [
    'ABC Traders stock list;;;',
    ';;;',
    'Product Name;Item Code;UOM;Qty;Kandy Branch Stock',
    'Tea 100g;TEA100;pack;"1,200";3',
  ].join('\n'));
  const { headerIndex, mapping, plan } = await planFor(file);
  assert.equal(headerIndex, 2);
  assert.equal(mapping.stock.length, 2);
  assert.deepEqual(plan.create[0].stock.map((s) => s.quantity), [1200, 3]);
  assert.equal(plan.create[0].sku, 'TEA100');
});

test('reports every skipped row and unknown column', async () => {
  await api.post('/items', { name: 'Rice 5kg', sku: 'RICE5' });
  const file = writeCsv('bad.csv', [
    'Name,SKU,Qty,Price,Galle Branch',
    'Rice 5kg,RICE5,4,100,1',
    ',X1,4,,',
    'Salt,SALT,two,,',
    'Salt,SALT2,-1,,',
    'Dhal,DHAL,5,,',
    'Dhal 2,DHAL,5,,',
    ',,,,',
    'Soap,,0,,',
    'Total,,9,,',
  ].join('\n'));
  const { mapping, plan } = await planFor(file);
  assert.deepEqual(mapping.ignored.map((c) => c.header), ['Price', 'Galle Branch']);
  assert.deepEqual(plan.create.map((e) => e.name), ['Dhal', 'Soap']);
  assert.deepEqual(plan.skipped.map((s) => s.row), [2, 3, 4, 5, 7, 10]);
  assert.match(plan.skipped[5].reason, /totals row/);
  assert.match(plan.skipped[0].reason, /already in the app/);
  assert.match(plan.skipped[1].reason, /no item name/);
  assert.match(plan.skipped[2].reason, /not a whole number/);
  assert.match(plan.skipped[4].reason, /same SKU DHAL as row 6/);
  assert.equal(plan.blankRows, 1);
  assert.deepEqual(plan.create[1].stock, []);
});

test('--map overrides say what a column is', async () => {
  const file = writeCsv('mapped.csv', 'Desc,Bal,Shop 2\nGlue,7,2\n');
  assert.equal(findHeaderRow(await readTable(file)), -1);
  const { plan, errors } = await planFor(file, { Desc: 'name', Bal: 'stock', 'Shop 2': 'stock:Kandy Branch' });
  assert.deepEqual(errors, []);
  assert.deepEqual(plan.create[0].stock.map((s) => [s.location.name, s.quantity]), [['Main Shop', 7], ['Kandy Branch', 2]]);
});

test('the command previews by default and writes only with --apply', async () => {
  const run = promisify(execFile);
  const script = path.join(__dirname, '..', 'scripts', 'import-items.js');
  const file = path.join(__dirname, '..', 'templates', 'items-template.csv');
  const env = { ...process.env, DATABASE_URL: process.env.DATABASE_URL, DATABASE_SSL: 'false' };

  const preview = await run('node', [script, file], { env });
  assert.match(preview.stdout, /New items: 3/);
  assert.match(preview.stdout, /Preview only/);
  assert.equal((await api.get('/items')).body.length, 0);

  const applied = await run('node', [script, file, '--apply'], { env });
  assert.match(applied.stdout, /Imported 3 items with 5 stock entries/);
  assert.equal((await api.get('/items')).body.length, 3);

  const extra = writeCsv('extra.csv', 'Name,Qty,Galle\nGlue,1,2\n');
  await assert.rejects(run('node', [script, extra, '--apply'], { env }), /left out: "Galle"/);
  assert.equal((await api.get('/items')).body.length, 3);
  await run('node', [script, extra, '--apply', '--map', 'Galle=ignore'], { env });
  assert.equal((await api.get('/items')).body.length, 4);

  const again = await run('node', [script, file], { env });
  assert.match(again.stdout, /New items: 0/);
  assert.match(again.stdout, /Skipped rows: 3/);
});
