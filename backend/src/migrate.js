const { pool } = require('./db');
const migrations = require('../migrations');

// Arbitrary constant so only one process applies migrations at a time.
const LOCK_ID = 727274;

// Applies any pending migrations in one transaction. Safe to call from many
// serverless instances at once: the transaction-scoped advisory lock makes
// the others wait, and they then find nothing left to do. Transaction-scoped
// locks also work through Supabase's transaction pooler.
async function migrate() {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock($1)', [LOCK_ID]);
    await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
      name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())`);
    const { rows } = await client.query('SELECT name FROM schema_migrations');
    const applied = new Set(rows.map((r) => r.name));
    for (const { name, sql } of migrations) {
      if (applied.has(name)) continue;
      try {
        await client.query(sql);
      } catch (err) {
        throw new Error(`Migration ${name} failed: ${err.message}`);
      }
      await client.query('INSERT INTO schema_migrations (name) VALUES ($1)', [name]);
      console.log(`Applied migration ${name}`);
    }
    await client.query('COMMIT');
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

module.exports = migrate;

if (require.main === module) {
  migrate()
    .then(() => pool.end())
    .catch((err) => {
      console.error(err.message);
      process.exit(1);
    });
}
