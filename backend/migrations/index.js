// Migrations in the order they run. Add new ones to the end of this list.
// Each file is read with a fixed path so Vercel's bundler includes it.
const fs = require('fs');
const path = require('path');

module.exports = [
  { name: '001_init.sql', sql: fs.readFileSync(path.join(__dirname, '001_init.sql'), 'utf8') },
  { name: '002_uploads.sql', sql: fs.readFileSync(path.join(__dirname, '002_uploads.sql'), 'utf8') },
  { name: '003_item_aliases.sql', sql: fs.readFileSync(path.join(__dirname, '003_item_aliases.sql'), 'utf8') },
];
