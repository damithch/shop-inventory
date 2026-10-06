const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { db } = require('./helpers');
const migrate = require('../src/migrate');

after(async () => {
  await db.pool.end();
});

async function emptyDatabase() {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
}

test('migrations can run from several instances at once', async () => {
  await emptyDatabase();
  await Promise.all([migrate(), migrate(), migrate()]);
  const { rows } = await db.query("SELECT count(*)::int AS n FROM locations WHERE type = 'main'");
  assert.equal(rows[0].n, 1);
});

test('the Vercel handler sets up the database on its first request', async () => {
  await emptyDatabase();
  const handler = require('../api');
  const login = await request(handler).post('/auth/login').send({ password: 'test-password' });
  assert.equal(login.status, 200);
  const res = await request(handler).get('/locations').set('Authorization', `Bearer ${login.body.token}`);
  assert.equal(res.status, 200);
  assert.equal(res.body[0].name, 'Main Shop');
});
