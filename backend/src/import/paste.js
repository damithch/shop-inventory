// Lists of items pasted into the app (copied from Excel, often passed along
// through WhatsApp): purchases received, transfers between locations, and
// sales. Each line is an item and how many. Reading and planning touch
// nothing; only applyPaste writes, inside the caller's transaction.
const { normalize, saveAlias } = require('./items');
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
  // Excel cells are split by tabs, or by runs of spaces once WhatsApp has
  // turned the tabs into spaces.
  const separator = text.includes('\t') ? '\t' : / {2,}/.test(text) ? / {2,}/ : null;
  if (separator) {
    // The first cell with letters is the name, the first whole number after
    // it is the quantity (later numbers are usually prices).
    const cells = text.split(separator).map((c) => c.trim());
    const nameAt = cells.findIndex(hasLetter);
    if (nameAt < 0) return null;
    const qtyCell = cells.slice(nameAt + 1).map((c) => toInt(c.replace(/^[-–:=×*@x\s]+/i, '').replace(new RegExp(`\\s*${UNIT_WORDS}\\.?$`, 'i'), '')))
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
function similarItems(name, items) {
  const n = normalize(name);
  if (n.length < 4) return [];
  return items
    .filter((i) => !i.archived && normalize(i.name).length >= 4)
    .map((i) => ({ id: i.id, name: i.name, n: normalize(i.name) }))
    .map((i) => ({ ...i, d: distance(n, i.n) }))
    .filter((i) => i.n.includes(n) || n.includes(i.n) || i.d <= Math.max(1, Math.floor(n.length / 6)))
    .sort((a, b) => a.d - b.d)
    .slice(0, 3)
    .map(({ id, name: itemName }) => ({ id, name: itemName }));
}

const words = (s) => String(s).toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);

// The one item whose name holds the pasted words in a row, like "Floriana"
// for "RAYHAAN FLORIANA" or "Hawas ice" for "RASASI HAWAS ICE 100 ML". Null
// when no item or more than one does, so the user picks.
function containingItem(name, items) {
  const w = words(name);
  if (normalize(name).length < 4 || !w.length) return null;
  const found = items.filter((i) => {
    if (i.archived) return false;
    const iw = words(i.name);
    for (let start = 0; start + w.length <= iw.length; start++) {
      if (w.every((x, k) => iw[start + k] === x)) return true;
    }
    return false;
  });
  return found.length === 1 ? found[0] : null;
}

// The location a line names, like "Dehiwela" heading a list of items to send
// there. Allows a typo in longer names.
function namedLocation(text, locations) {
  const n = normalize(text);
  if (n.length < 3) return null;
  return locations.find((l) => {
    const m = normalize(l.name);
    return m === n || (n.length >= 5 && distance(m, n) <= 1);
  }) ?? null;
}

// Matches each pasted line to an item and checks there is enough stock.
// from is where stock leaves (transfer, sale); to is where it arrives
// (receive, transfer). Lines for the same item are added together. matches
// maps a pasted name (normalized) to the item someone picked for it; saving
// remembers those as aliases. A name found inside exactly one item's name is
// matched to it automatically (auto_matched), unless noMatch (normalized
// names) says it isn't that item.
// prices maps an item id to the price it sold at (sales only; null for no
// price); other items use their saved price.
function planPaste(action, parsed, { items, levels, aliases = [] }, {
  from = null, to = null, matches = new Map(), noMatch = new Set(), prices = new Map(),
} = {}) {
  const byId = new Map(items.map((i) => [i.id, i]));
  // Archived items go first so a live item with the same name wins.
  const byName = new Map([...items.filter((i) => i.archived), ...items.filter((i) => !i.archived)].map((i) => [normalize(i.name), i]));
  // Names picked for items on uploaded sheets or earlier pastes match too.
  for (const a of aliases) if (!byName.has(a.name_key) && byId.has(a.item_id)) byName.set(a.name_key, byId.get(a.item_id));
  const current = new Map(levels.map((l) => [`${l.item_id}:${l.location_id}`, l.quantity]));
  // Group the pasted rows by the item they are (or, for unknown names, by name).
  const merged = new Map();
  const newAliases = [];
  for (const row of parsed.rows) {
    const key = normalize(row.name);
    const picked = matches.has(key) ? byId.get(matches.get(key)) : null;
    const known = picked ?? byName.get(key) ?? null;
    const auto = known || noMatch.has(key) ? null : containingItem(row.name, items);
    const item = known ?? auto;
    if (picked && normalize(picked.name) !== key && !newAliases.some((a) => normalize(a.name) === key)) {
      newAliases.push({ name: row.name, item_id: picked.id });
    }
    const group = item ? `item:${item.id}` : `name:${key}`;
    const entry = merged.get(group);
    if (entry) {
      entry.quantity += row.quantity;
      entry.lines.push(row.line);
      if (!entry.names.includes(row.name)) entry.names.push(row.name);
      if (!auto) entry.auto = false;
    } else {
      merged.set(group, { item, auto: Boolean(auto), name: row.name, names: [row.name], quantity: row.quantity, lines: [row.line] });
    }
  }
  const lines = [];
  const skipped = [...parsed.skipped];
  for (const entry of merged.values()) {
    const { item } = entry;
    const skip = (reason, extra = {}) => skipped.push({ line: entry.lines[0], text: `${entry.name} ${entry.quantity}`, reason, ...extra });
    if (item?.archived) {
      skip(`"${item.name}" is archived in the app`);
      continue;
    }
    if (!item && action !== 'receive') {
      const similar = similarItems(entry.name, items);
      skip(similar.length ? `not in the app. Did you mean: ${similar.map((i) => i.name).join(', ')}?` : 'not in the app', {
        name: entry.name, similar_to: similar.map((i) => i.name), similar_ids: similar.map((i) => i.id),
      });
      continue;
    }
    if (item && from) {
      const available = current.get(`${item.id}:${from.id}`) ?? 0;
      if (available < entry.quantity) {
        skip(`only ${available} at ${from.name}, ${entry.quantity} asked for`);
        continue;
      }
    }
    const similar = item && !entry.auto ? [] : similarItems(entry.name, items).filter((i) => i.id !== item?.id);
    lines.push({
      lines: entry.lines,
      name: entry.name,
      pasted_names: entry.names,
      quantity: entry.quantity,
      item_id: item?.id ?? null,
      item_name: item?.name ?? entry.name,
      new_item: !item,
      auto_matched: entry.auto,
      similar_to: similar.map((i) => i.name),
      similar_ids: similar.map((i) => i.id),
      ...(action === 'sale' && { price: prices.has(item.id) ? prices.get(item.id) : (item.price ?? null) }),
    });
  }
  skipped.sort((a, b) => a.line - b.line);
  const units = lines.reduce((s, l) => s + l.quantity, 0);
  const priced = lines.filter((l) => l.price !== undefined && l.price !== null);
  return {
    action,
    from: from && { location_id: from.id, location_name: from.name },
    to: to && { location_id: to.id, location_name: to.name },
    lines,
    skipped,
    aliases: newAliases,
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
      ...(action === 'sale' && {
        amount: Math.round(priced.reduce((s, l) => s + l.quantity * l.price * 100, 0)) / 100,
        unpriced_units: units - priced.reduce((s, l) => s + l.quantity, 0),
      }),
    },
  };
}

// Saves a planned paste. Returns low-stock alerts to send after commit.
async function applyPaste(client, plan, { note, uploadId, prices = new Map() }) {
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
      const r = await saleIn(client, { ...common, locationId: plan.from.location_id, unitPrice: l.price });
      alerts.push(...r.alerts);
      // A price typed in for this sale becomes the item's price for next time.
      if (prices.has(l.item_id)) await client.query('UPDATE items SET price = $2 WHERE id = $1', [l.item_id, l.price]);
    }
  }
  for (const a of plan.aliases ?? []) await saveAlias(client, a.name, a.item_id);
  return alerts;
}

module.exports = { ACTIONS, parseLine, parsePaste, planPaste, applyPaste, namedLocation };
