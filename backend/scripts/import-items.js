#!/usr/bin/env node
// Imports items, and optionally their starting stock, from a CSV or .xlsx file.
// Shows a preview by default; nothing is written without --apply.
//
//   node --env-file=.env scripts/import-items.js items.xlsx [--sheet Sheet1]
//        [--map "Header=field" ...] [--apply]
//
// See "Importing items from a file" in README.md.
const path = require('path');

// Only DATABASE_URL matters here; the API's other settings aren't used.
process.env.ADMIN_PASSWORD ||= 'unused-by-import';
process.env.JWT_SECRET ||= 'unused-by-import';

const USAGE = `Usage: node --env-file=.env scripts/import-items.js <file.csv|file.xlsx> [options]

Options:
  --apply                 Write to the database (without it, only a preview is shown)
  --sheet <name>          Sheet to read from an .xlsx file (default: the first)
  --map "<header>=<field>" Say what a column is. field: name, sku, unit, stock
                          (main shop), stock:<location name>, or ignore. Repeatable.`;

function parseArgs(argv) {
  const opts = { file: null, sheet: null, apply: false, map: {} };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--apply') opts.apply = true;
    else if (arg === '--sheet') opts.sheet = argv[++i];
    else if (arg === '--map') {
      const spec = argv[++i] ?? '';
      const eq = spec.lastIndexOf('=');
      if (eq <= 0) throw new Error(`--map needs "Header=field", got "${spec}"`);
      opts.map[spec.slice(0, eq).trim()] = spec.slice(eq + 1).trim();
    } else if (arg === '--help' || arg === '-h') {
      console.log(USAGE);
      process.exit(0);
    } else if (arg.startsWith('--')) throw new Error(`Unknown option ${arg}`);
    else if (!opts.file) opts.file = arg;
    else throw new Error(`Unexpected argument ${arg}`);
  }
  if (!opts.file) throw new Error(USAGE);
  return opts;
}

function printPlan({ mapping, plan, headerIndex }, rows) {
  const col = (index) => (index === null ? '(none)' : `"${rows[headerIndex][index]}"`);
  console.log(`Header found on row ${headerIndex + 1}.`);
  console.log('Columns:');
  console.log(`  item name  <- ${col(mapping.name)}`);
  console.log(`  SKU        <- ${col(mapping.sku)}`);
  console.log(`  unit       <- ${col(mapping.unit)}${mapping.unit === null ? ' (every item gets "pcs")' : ''}`);
  for (const s of mapping.stock) console.log(`  stock at ${s.location.name} <- "${s.header}"`);
  if (!mapping.stock.length) console.log('  no stock columns: items are created with 0 stock');
  for (const c of mapping.ignored) console.log(`  NOT IMPORTED: "${c.header}" (${c.reason})`);

  const units = plan.create.reduce((sum, e) => sum + e.stock.reduce((a, s) => a + s.quantity, 0), 0);
  console.log(`\nNew items: ${plan.create.length} (total starting stock ${units})`);
  for (const e of plan.create.slice(0, 15)) {
    const stock = e.stock.map((s) => `${s.location.name}: ${s.quantity}`).join(', ') || 'no stock';
    console.log(`  row ${e.row}: ${e.name}${e.sku ? ` [${e.sku}]` : ''} (${e.unit}) - ${stock}`);
  }
  if (plan.create.length > 15) console.log(`  ... and ${plan.create.length - 15} more`);

  console.log(`\nSkipped rows: ${plan.skipped.length}`);
  for (const s of plan.skipped) console.log(`  row ${s.row}: ${s.item} - ${s.reason}`);
  if (plan.blankRows) console.log(`(${plan.blankRows} empty rows ignored)`);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const db = require('../src/db');
  const migrate = require('../src/migrate');
  const { readTable, findHeaderRow, mapColumns, planImport, loadContext, applyPlan } = require('../src/import/items');

  try {
    const rows = await readTable(opts.file, { sheet: opts.sheet });
    const headerIndex = findHeaderRow(rows, opts.map);
    if (headerIndex < 0) {
      throw new Error('Could not find a header row with an item name column in the first 20 rows. '
        + 'Name the column with --map "<header>=name".');
    }
    await migrate();
    const { locations, items } = await loadContext(db);
    const { mapping, errors } = mapColumns(rows[headerIndex], locations, opts.map);
    if (errors.length) {
      throw new Error(`${errors.join('\n')}\nColumns in the file: ${rows[headerIndex].filter(Boolean).join(', ')}`);
    }
    const plan = planImport(rows, headerIndex, mapping, items);
    printPlan({ mapping, plan, headerIndex }, rows);

    // A column we couldn't place may be stock for a location that doesn't
    // exist yet. Items that go in without it would be skipped on a re-run.
    const unplaced = mapping.ignored.filter((c) => c.reason !== 'ignored with --map');
    if (opts.apply && unplaced.length) {
      throw new Error(`\nNot importing: these columns would be left out: ${unplaced.map((c) => `"${c.header}"`).join(', ')}.\n`
        + 'If one is stock for a location, add that location in the app first (or use --map "<header>=stock:<location>").\n'
        + 'Otherwise confirm it can be left out with --map "<header>=ignore".');
    }
    if (!opts.apply) {
      console.log('\nPreview only, nothing was saved. Run again with --apply to import.');
      return;
    }
    if (!plan.create.length) {
      console.log('\nNothing to import.');
      return;
    }
    const result = await applyPlan(db, plan, `Imported from ${path.basename(opts.file)}`);
    console.log(`\nImported ${result.items} items with ${result.movements} stock entries.`);
  } finally {
    await db.pool.end();
  }
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
