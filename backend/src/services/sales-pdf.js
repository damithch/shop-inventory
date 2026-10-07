// A day's sales report as an A4 PDF: the place and date, totals, and a table
// of what sold. Uses pdf-lib's built-in Helvetica, so no font files are needed.
const { PDFDocument, StandardFonts, rgb } = require('pdf-lib');

const PAGE = [595.28, 841.89]; // A4 in points
const MARGIN = 40;
const ROW = 18;
const GREY = rgb(0.4, 0.4, 0.4);
const LINE = rgb(0.8, 0.8, 0.8);

const money = (n) => n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const count = (n, one, many) => `${n.toLocaleString('en-US')} ${n === 1 ? one : many}`;

function longDate(iso) {
  const d = new Date(`${iso}T00:00:00Z`);
  return d.toLocaleDateString('en-GB', { timeZone: 'UTC', weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
}

async function salesPdf(report, { generatedAt } = {}) {
  const pdf = await PDFDocument.create();
  pdf.setTitle(`Sales ${report.location_name ?? 'all places'} ${report.date}`);
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const charset = new Set(font.getCharacterSet());
  // Helvetica only has Latin letters; anything else would stop the PDF.
  const safe = (text) => [...String(text)].map((c) => (charset.has(c.codePointAt(0)) ? c : '?')).join('');
  const fit = (text, f, size, width) => {
    let t = safe(text);
    if (f.widthOfTextAtSize(t, size) <= width) return t;
    while (t.length > 1 && f.widthOfTextAtSize(`${t}…`, size) > width) t = t.slice(0, -1);
    return `${t.trimEnd()}…`;
  };

  const priced = report.items.some((i) => i.amount !== null) || report.total_amount > 0;
  const right = PAGE[0] - MARGIN;
  // Column right edges for numbers; the item name fills the space left of them.
  const cols = priced
    ? { qty: right - 190, price: right - 95, amount: right }
    : { qty: right };
  const nameX = MARGIN + 26;
  const nameWidth = (priced ? cols.qty - 50 : cols.qty - 60) - nameX;

  let page;
  let y;
  const text = (t, x, size = 10, f = font, color = rgb(0, 0, 0)) => page.drawText(safe(t), { x, y, size, font: f, color });
  const textRight = (t, x, size = 10, f = font, color) => text(t, x - f.widthOfTextAtSize(safe(t), size), size, f, color);
  const rule = (thickness = 0.5, color = LINE) => page.drawLine({
    start: { x: MARGIN, y: y - 5 }, end: { x: right, y: y - 5 }, thickness, color,
  });

  const tableHeader = () => {
    text('#', MARGIN, 9, bold, GREY);
    text('Item', nameX, 9, bold, GREY);
    textRight('Qty', cols.qty, 9, bold, GREY);
    if (priced) {
      textRight('Unit price', cols.price, 9, bold, GREY);
      textRight('Amount (LKR)', cols.amount, 9, bold, GREY);
    }
    rule(0.8, GREY);
    y -= ROW + 2;
  };
  const newPage = (withHeader) => {
    page = pdf.addPage(PAGE);
    y = PAGE[1] - MARGIN;
    if (withHeader) tableHeader();
  };
  // Starts a new page when fewer than `rows` rows fit.
  const room = (rows = 1) => {
    if (y - rows * ROW < MARGIN + 20) newPage(true);
  };

  newPage(false);
  text('Sales report', MARGIN, 20, bold);
  y -= 24;
  text(`${report.location_name ?? 'All places'}  ·  ${longDate(report.date)}`, MARGIN, 12);
  y -= 16;
  if (generatedAt) text(`Made ${generatedAt}`, MARGIN, 9, font, GREY);
  y -= 28;

  // Totals
  const summary = [
    ['Items', count(report.items.length ? new Set(report.items.map((i) => i.item_id)).size : 0, 'item', 'items')],
    ['Units sold', count(report.total, 'unit', 'units')],
  ];
  if (priced) summary.push(['Total sales', `LKR ${money(report.total_amount)}`]);
  for (const [label, value] of summary) {
    text(label, MARGIN, 11, font, GREY);
    text(value, MARGIN + 110, label === 'Total sales' ? 14 : 11, bold);
    y -= label === 'Total sales' ? 20 : 16;
  }
  if (priced && report.unpriced_units > 0) {
    text(`${count(report.unpriced_units, 'unit has', 'units have')} no price and ${report.unpriced_units === 1 ? 'is' : 'are'} not in the total.`, MARGIN, 9, font, GREY);
    y -= 14;
  }
  y -= 14;

  if (!report.items.length) {
    text('No sales were recorded for this day.', MARGIN, 11);
    return finish(pdf, font);
  }

  // One section per place (just one when the report is for a branch).
  const sections = new Map();
  for (const item of report.items) {
    if (!sections.has(item.location_name)) sections.set(item.location_name, []);
    sections.get(item.location_name).push(item);
  }
  tableHeader();
  for (const [place, items] of sections) {
    if (sections.size > 1) {
      room(3);
      text(place, MARGIN, 11, bold);
      y -= ROW;
    }
    items.forEach((item, i) => {
      room();
      text(String(i + 1), MARGIN, 10, font, GREY);
      text(fit(item.item_name, font, 10, nameWidth), nameX, 10);
      textRight(`${item.quantity}`, cols.qty, 10);
      if (priced) {
        textRight(item.unit_price === null ? '-' : money(item.unit_price), cols.price, 10);
        textRight(item.amount === null ? '-' : money(item.amount), cols.amount, 10);
      }
      rule();
      y -= ROW;
    });
    if (sections.size > 1) {
      room();
      const units = items.reduce((s, i) => s + i.quantity, 0);
      text(`${place} total`, nameX, 10, bold);
      textRight(`${units}`, cols.qty, 10, bold);
      if (priced) textRight(money(items.reduce((s, i) => s + (i.amount ?? 0), 0)), cols.amount, 10, bold);
      y -= ROW + 8;
    }
  }
  room(2);
  y -= 4;
  page.drawLine({ start: { x: MARGIN, y: y + 12 }, end: { x: right, y: y + 12 }, thickness: 1, color: rgb(0, 0, 0) });
  text('Total', nameX, 11, bold);
  textRight(`${report.total}`, cols.qty, 11, bold);
  if (priced) textRight(money(report.total_amount), cols.amount, 11, bold);
  return finish(pdf, font);
}

// Page numbers, then the file's bytes.
async function finish(pdf, font) {
  const pages = pdf.getPages();
  pages.forEach((p, i) => {
    const label = `Page ${i + 1} of ${pages.length}`;
    p.drawText(label, { x: PAGE[0] - MARGIN - font.widthOfTextAtSize(label, 8), y: MARGIN / 2, size: 8, font, color: GREY });
  });
  return pdf.save();
}

module.exports = { salesPdf };
