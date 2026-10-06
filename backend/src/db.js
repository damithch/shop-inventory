const { Pool } = require('pg');
const config = require('./config');

// On Vercel each function instance gets its own small pool, and idle
// connections are closed quickly so suspended instances don't hold them.
const serverless = Boolean(process.env.VERCEL);

const pool = new Pool({
  connectionString: config.databaseUrl,
  ssl: config.databaseSsl ? { rejectUnauthorized: false } : false,
  max: serverless ? 3 : 5,
  idleTimeoutMillis: serverless ? 5000 : 10000,
});

async function withTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

module.exports = { pool, query: (text, params) => pool.query(text, params), withTransaction };
