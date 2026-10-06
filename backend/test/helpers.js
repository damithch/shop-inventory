// Tests run against a real, throwaway Postgres database.
// Set TEST_DATABASE_URL, e.g. postgres://inv:inv@localhost:5432/inventory_test
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || 'postgres://inv:inv@localhost:5432/inventory_test';
process.env.DATABASE_SSL = 'false';
process.env.ADMIN_PASSWORD = 'test-password';
process.env.JWT_SECRET = 'test-secret';

const request = require('supertest');
const db = require('../src/db');
const migrate = require('../src/migrate');
const app = require('../src/app');
const { setNotifier } = require('../src/services/notifier');

const sent = [];
setNotifier(async (alerts) => sent.push(...alerts));

async function reset() {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await migrate();
  sent.length = 0;
}

async function client() {
  const res = await request(app).post('/auth/login').send({ password: 'test-password' });
  const auth = { Authorization: `Bearer ${res.body.token}` };
  const wrap = (method) => (url, body) => request(app)[method](url).set(auth).send(body);
  return { get: wrap('get'), post: wrap('post'), put: wrap('put'), patch: wrap('patch'), delete: wrap('delete') };
}

module.exports = { app, db, reset, client, sent };
