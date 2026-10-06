// Lists of items pasted into the app (copied from Excel, often passed along
// through WhatsApp): purchases received, transfers between locations, and
// sales. Each line is an item and how many. Reading and planning touch
// nothing; only applyPaste writes, inside the caller's transaction.
const { normalize } = require('./items');
const { receiveIn, transferIn, saleIn } = require('../services/stock');

const ACTIONS = ['receive', 'transfer', 'sale'];

// "[06/10/2026, 9:15 am] Nimal: " in front of a forwarded WhatsApp message.
const WHATSAPP_PREFIX = /^\[[^\]]{4,40}\]\s*[^:]{1,40}:\s*/;
const SERIAL = /^\d{1,4}\s*[.)]\s+/;
const UNIT_WORDS = '(?:pcs?|pieces?|nos?|units?|bottles?|qty)';
const hasLetter = (s) => /[a-z]/i.test(s);
const toInt = (s) => (/^\d[\d,]*$/.test(s) ? Number(s.replace(/,/g, '')) : null);

// Splits one pasted line into an item name and quantity, or null.
function parseLine(raw) {
  const text = raw.replace(WHATSAPP_PREFIX, '').trim();
  if (text.includes('\t')) {
    // Excel cells: the first cell with letters is the name, the first whole
    // number after it is the quantity (later numbers are usually prices).
    const cells = text.split('\t').map((c) => c.trim());
    const nameAt = cells.findIndex(hasLetter);
    if (nameAt < 0) return null;
    const qtyCell = cells.slice(nameAt + 1).map((c) => toInt(c.replace(new RegExp(`\\s*${UNIT_WORDS}\\.?$`, 'i'), '')))
      .find((n) => n !== null);
    return qtyCell === undefined ? { name: cells[nameAt], quantity: null } : { name: cells[nameAt], quantity: qtyCell };
  }
  // Plain text: "AFNAN 9AM - 2", "AFNAN 9AM x2", "AFNAN 9AM 2 pcs", or "2 x AFNAN 9AM".
  const trailing = text.match(new RegExp(`^(.*[a-z].*)(?:\\s*[-–:=×*@]\\s*|\\s+x\\s*|\\s+)(\\d[\\d,]*)\\s*${UNIT_WORDS}?\\.?$`, 'i'));
  if (trailing) return { name: trailing[1].replace(SERIAL, ''), quantity: toInt(trailing[2]) };
  const leading = text.match(new RegExp(`^(\\d[\\d,]*)\\s*(?:x|×|${UNIT_WORDS})?\\s+(.*[a-z].*)$`, 'i'));
  if (leading) return { name: leading[2], quantity: toInt(leading[1]) };
  return hasLetter(text) ? { name: text, quantity: null } : null;
}

// Drops bullets and the separator left before the quantity ("YARA x", "YARA -"),
// but never a letter that is part of the name ("RASASI MAX").
const cleanName = (name) => name
  .replace(/\s+/g, ' ')
  .replace(/^[-–:*•\s]+/, '')
  .replace(/[-–:=×*@\s]+$/, '')
  .replace(/\s+[x×]$/i, '')
  .trim();
const TOTALS = /^(grand\s*|sub\s*)?total\b/i;

// Every non-empty line ends up in rows or skipped, with the line number.
function parsePaste(text) {
  const rows = [];
  const skipped = [];
  String(text ?? '').split(/\r?\n/).forEach((raw, i) => {
    const line = i + 1;
    if (!raw.trim()) return;
    const parsed = parseLine(raw);
    const name = parsed ? cleanName(parsed.name) : '';
    if (!parsed || !name) {
      skipped.push({ line, text: raw.trim(), reason: 'no item name' });
    } else if (TOTALS.test(name)) {
      skipped.push({ line, text: raw.trim(), reason: 'totals row' });
    } else if (parsed.quantity === null) {
      const heading = rows.length === 0 && /\b(item|items|qty|quantity|description|name|product)\b/i.test(raw);
      skipped.push({ line, text: raw.trim(), reason: heading ? 'looks like a heading' : 'no quantity on this line' });
    } else if (parsed.quantity <= 0) {
      skipped.push({ line, text: raw.trim(), reason: 'quantity is 0' });
    } else {
      rows.push({ line, text: raw.trim(), name, quantity: parsed.quantity });
    }
  });
  return { rows, skipped };
}

function distance(a, b) {
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const row = [i];
    for (let j = 1; j <= b.length; j++) {
      row[j] = Math.min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    prev = row;
  }
  return prev[b.length];
}

// Items whose names contain the pasted name (or the other way round), or are a
// typo or two away from it, closest first.
function similarNames(name, items) {
  const n = normalize(name);
  if (n.length < 4) return [];
  return items
    .filter((i) => !i.archived && normalize(i.name).length >= 4)
    .map((i) => ({ name: i.name, n: normalize(i.name) }))
    .map((i) => ({ ...i, d: distance(n, i.n) }))
    .filter((i) => i.n.includes(n) || n.includes(i.n) || i.d <= Math.max(1, Math.floor(n.length / 6)))
    .sort((a, b) => a.d - b.d)
    .slice(0, 3)
    .map((i) => i.name);
}

// Matches each pasted line to an item and checks there is enough stock.
// from is where stock leaves (transfer, sale); to is where it arrives
// (receive, transfer). Lines for the same item are added together.
function planPaste(action, parsed, { items, levels }, { from = null, to = null } = {}) {
  const byName = new Map(items.map((i) => [normalize(i.name), i]));
  const current = new Map(levels.map((l) => [`${l.item_id}:${l.location_id}`, l.quantity]));
  const merged = new Map();
  for (const row of parsed.rows) {
    const key = normalize(row.name);
    const entry = merged.get(key);
    if (entry) {
      entry.quantity += row.quantity;
      entry.lines.push(row.line);
    } else {
      merged.set(key, { name: row.name, quantity: row.quantity, lines: [row.line] });
    }
  }
  const lines = [];
  const skipped = [...parsed.skipped];
  for (const [key, entry] of merged) {
    const item = byName.get(key);
    const skip = (reason) => skipped.push({ line: entry.lines[0], text: `${entry.name} ${entry.quantity}`, reason });
    if (item?.archived) {
      skip(`"${item.name}" is archived in the app`);
      continue;
    }
    if (!item && action !== 'receive') {
      const similar = similarNames(entry.name, items);
      skip(similar.length ? `not in the app. Did you mean: ${similar.join(', ')}?` : 'not in the app');
      continue;
    }
    if (item && from) {
      const available = current.get(`${item.id}:${from.id}`) ?? 0;
      if (available < entry.quantity) {
        skip(`only ${available} at ${from.name}, ${entry.quantity} asked for`);
        continue;
      }
    }
    lines.push({
      lines: entry.lines,
      name: entry.name,
      quantity: entry.quantity,
      item_id: item?.id ?? null,
      item_name: item?.name ?? entry.name,
      new_item: !item,
      similar_to: item ? [] : similarNames(entry.name, items),
    });
  }
  skipped.sort((a, b) => a.line - b.line);
  const units = lines.reduce((s, l) => s + l.quantity, 0);
  return {
    action,
    from: from && { location_id: from.id, location_name: from.name },
    to: to && { location_id: to.id, location_name: to.name },
    lines,
    skipped,
    // Same keys as a stock sheet upload, so upload history can show both.
    summary: {
      kind: action,
      new_items: lines.filter((l) => l.new_item).length,
      new_stock: lines.filter((l) => l.new_item).reduce((s, l) => s + l.quantity, 0),
      changed_items: lines.filter((l) => !l.new_item).length,
      received: action === 'receive' ? units : 0,
      transferred: action === 'transfer' ? units : 0,
      sold: action === 'sale' ? units : 0,
      unchanged_items: 0,
      skipped_rows: skipped.length,
    },
  };
}

// Saves a planned paste. Returns low-stock alerts to send after commit.
async function applyPaste(client, plan, { note, uploadId }) {
  const alerts = [];
  for (const l of plan.lines) {
    let itemId = l.item_id;
    if (l.new_item) {
      const { rows } = await client.query("INSERT INTO items (name, unit) VALUES ($1, 'pcs') RETURNING id", [l.name]);
      itemId = rows[0].id;
    }
    const common = { itemId, quantity: l.quantity, note, uploadId };
    if (plan.action === 'receive') {
      await receiveIn(client, { ...common, locationId: plan.to.location_id });
    } else if (plan.action === 'transfer') {
      const r = await transferIn(client, { ...common, fromLocationId: plan.from.location_id, toLocationId: plan.to.location_id });
      alerts.push(...r.alerts);
    } else {
      const r = await saleIn(client, { ...common, locationId: plan.from.location_id });
      alerts.push(...r.alerts);
    }
  }
  return alerts;
}

module.exports = { ACTIONS, parseLine, parsePaste, planPaste, applyPaste };
