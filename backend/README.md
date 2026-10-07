# Inventory API

Node.js + Express API on Postgres for one main shop and its branches.

## How stock works

Stock is never edited directly. Every change is a **movement**, and the current
count at each location (`stock_levels`) is updated in the same database
transaction, so the counts always match the history.

| Movement   | What it means                               | Endpoint               |
|------------|---------------------------------------------|------------------------|
| `receive`  | New stock arrives (main shop by default)    | `POST /stock/receive`  |
| `transfer` | Move stock from one location to another     | `POST /stock/transfer` |
| `sale`     | Stock sold or used at a location            | `POST /stock/sale`     |
| `adjust`   | Correct the count after a physical check    | `POST /stock/adjust`   |

Stock can never go below zero; asking to move or sell more than is there
returns `409` and changes nothing.

### Low-stock alerts

Each item at each location has an alert level. It defaults to **3** (changeable
with `PUT /settings`), and can be set per item per location with
`PUT /stock/threshold`. When a change takes an item from above its level to at
or below it, the API records an alert and calls the push notification hook in
`src/services/notifier.js`. It alerts once per drop, not on every sale while
already low.

When `FIREBASE_SERVICE_ACCOUNT` is set, each alert is pushed through Firebase
Cloud Messaging to every phone registered with `POST /devices`
(`src/services/push.js`); phones that uninstalled the app are dropped
automatically. Without it, alerts are only logged. Setup steps are in
[docs/push-and-apk.md](../docs/push-and-apk.md).

## API

All endpoints except `/health` and `/auth/login` need `Authorization: Bearer <token>`.

| Method | Path | Body / query | Notes |
|---|---|---|---|
| POST | `/auth/login` | `{ password }` | Returns `{ token }` |
| GET | `/health` | | |
| GET | `/locations` | `?include_archived=true` | Main shop first, with item counts |
| POST | `/locations` | `{ name }` | Adds a branch |
| PATCH | `/locations/:id` | `{ name?, archived? }` | |
| GET | `/locations/:id/stock` | | Every item's quantity, alert level and `low` flag there |
| GET | `/items` | `?q=search&include_archived=true` | With `main_quantity` and `total_quantity` |
| POST | `/items` | `{ name, sku?, unit?, price? }` | `price` is the selling price in rupees, optional |
| GET | `/items/:id` | | Item with its stock at every location |
| PATCH | `/items/:id` | `{ name?, sku?, unit?, price?, archived? }` | `price: null` clears it |
| POST | `/stock/receive` | `{ item_id, quantity, location_id?, note? }` | |
| POST | `/stock/transfer` | `{ item_id, to_location_id, quantity, from_location_id?, note? }` | From the main shop unless `from_location_id` is given |
| POST | `/stock/sale` | `{ item_id, location_id, quantity, unit_price?, note? }` | Without `unit_price`, the item's price is kept with the sale |
| POST | `/stock/adjust` | `{ item_id, location_id, new_quantity, note? }` | |
| PUT | `/stock/threshold` | `{ item_id, location_id, threshold }` | `threshold: null` goes back to the default |
| GET | `/stock/low` | `?location_id=` | Everything at or below its alert level |
| GET | `/stock/movements` | `?item_id=&location_id=&limit=&before_id=` | Newest first |
| GET / PUT | `/settings` | `{ default_threshold }` | |
| POST | `/devices` | `{ token, platform? }` | Registers a phone's FCM token |
| DELETE | `/devices/:token` | | |
| GET | `/alerts` | `?limit=&before_id=` | Alert history, newest first |
| POST | `/uploads/preview` | file as the body, `?filename=&location_id=&matches=` | What a stock sheet would change; saves nothing |
| POST | `/uploads` | same | Saves the stock sheet (see below) |
| GET | `/uploads` | `?limit=` | Past uploads with their summary |
| POST | `/paste/preview` | `{ action, text, location_id?, to_location_id?, matches?, no_match?, prices? }` | What a pasted list would change; saves nothing |
| POST | `/paste` | same | Saves the pasted list (see below) |
| GET | `/exports/stock` | `?location_id=&format=xlsx\|csv` | Stock at one location, or every location without `location_id` (see below) |
| GET | `/exports/items` | `?format=xlsx\|csv` | Every item with its total stock and the date it was added |
| GET | `/reports/sales` | `?date=YYYY-MM-DD&location_id=` | What sold that day (default today), per item and location, with rupee totals |
| GET | `/reports/sales/pdf` | same | The same report as a PDF (see below) |

Stock endpoints return `{ movement, levels, alerts }` so the app can update its
screen and show any alert straight away.

Errors are `{ "error": "message" }` with a 400, 401, 404 or 409 status. The
messages are written to be shown to the user as they are.

## Password

The owner signs in with `ADMIN_PASSWORD`. The app has no option to change it;
change it on Vercel (Environment Variables, then Redeploy).

A short-lived version of the app could change the password in the app, which
stored it in the database (`settings` row `admin_password`, scrypt-hashed).
If that row exists, its password is the one that works and `ADMIN_PASSWORD`
does not.

To go back to `ADMIN_PASSWORD`, run this in Supabase's SQL editor:

```sql
DELETE FROM settings WHERE key = 'admin_password';
```

## Exports

`/exports/stock` and `/exports/items` download a spreadsheet, named like
`stock-kandy-branch-2026-10-07.xlsx` (the shop's date). `format` is `xlsx`
(default) or `csv`; CSV files start with a byte order mark so Excel reads
non-English letters correctly. Archived items and locations are left out.

- One location: item name, SKU, unit, `Qty`, alert level and a "Yes" when
  low. These columns read back as a stock sheet, so a counted copy can be
  uploaded for that location.
- All locations: one row per item with a column per location and the total.
  The Excel file also has a sheet for each location, as above.

## Reset and delete

For starting over or clearing out a place. Each needs the owner's password
again in `password` (a wrong one answers `403` and doesn't sign the phone
out). Add `"dry_run": true` to check the password and get the same summary
without changing anything; the app does that, then saves an Excel backup,
then runs it for real.

| Endpoint                       | Body                     | Does                                          |
|--------------------------------|--------------------------|-----------------------------------------------|
| `POST /reset/stock`            | `location_id` (optional) | Every count at that place, or everywhere, to 0 |
| `POST /reset/delete-item`      | `item_id`                | The item's stock everywhere to 0, then archives it |
| `POST /reset/delete-all-items` |                          | Every item's stock to 0, then archives them all |
| `POST /reset/delete-branch`    | `location_id`            | The branch's stock to 0, then archives it (not the main shop) |

Answers `{ items, units, dry_run }` (items and units taken to zero) plus
`location`, `item` or `deleted_items`. Nothing is wiped:
- Each count taken away is an `adjust` movement noted "Reset to zero", so
  item history shows what was there. Resets never raise low-stock alerts.
- Sales history and the sales report are untouched; deleted items and
  branches are archived, so old reports keep their names. Stock sheets and pasted lists never match a deleted item: its name
  on a sheet becomes a new item.
- A deleted item's SKU is cleared and its other sheet names forgotten, so
  a new item can take the SKU and name. A deleted branch is renamed
  "Kandy Branch (deleted 2026-10-07)" so its name can be used again.

## Stock sheets uploaded from the app

The app can upload a stock sheet (`.xlsx` or `.csv`), for example the shop's
stock list each morning and again at the end of the day. Send the file as the
raw request body (`Content-Type: application/octet-stream`) with its name in
`?filename=`. `/uploads/preview` shows what would change; `/uploads` saves it.

- Columns are read the same way as the import script below. A plain quantity
  column (Qty, Stock, ...) is the stock at `location_id`, or the main shop if
  that isn't given. A sheet with no header row works too when it's just names
  and counts.
- Items not in the app yet are created, with their count as stock received.
- For items already in the app, the count in the sheet becomes the stock at
  that location. A lower count than the app has is recorded as a **sale**, a
  higher one as stock **received**. Each movement has `upload_id` set, and
  the note "Stock sheet <file name>".
- Items missing from the sheet, and blank quantity cells, leave stock as it is.
- Names match ignoring case, spaces and punctuation. New items whose name is
  part of an existing one (or the other way round) are listed with
  `similar_to` and `similar_ids`, so the app can warn before a short name
  becomes a duplicate.
- `?matches=7:12,9:40` says sheet row 7 is item 12 and row 9 is item 40, for
  names the app didn't recognise ("HAWAS ICE" for "RASASI HAWAS ICE 100 ML").
  Saving remembers each picked name (`item_aliases`), so later sheets and
  pasted lists match it by themselves.
- Rows that can't be used (no name, negative or fractional count, totals row,
  duplicate) are listed in `skipped` and change nothing.
- Sales that take an item to its alert level send the usual low-stock alert.

`/reports/sales` adds up sales on one day in the shop's time zone
(`SHOP_TIMEZONE`, default `Asia/Colombo`), from both stock sheets and sales
entered in the app.

## Lists pasted into the app

Purchases, transfers and sales can also be pasted as text: rows copied from
Excel, or the same list forwarded through WhatsApp. `/paste/preview` shows what
would change; `/paste` saves it. `action` is one of:

- `receive`: purchases. Stock is added at `location_id` (default the main
  shop). Items not in the app yet are created.
- `transfer`: stock moves from `location_id` (default the main shop) to
  `to_location_id`, or to the place a line of the list names (a list headed
  "Dehiwela" goes to Dehiwala; one wrong letter is allowed).
- `sale`: stock is sold at `location_id`.

Each line is an item and how many: `Rice 5`, `Rice - 5`, `Rice x5`,
`5 x Rice`, `Rice 5 pcs`, or Excel cells (the first cell with letters is the
name, the first whole number after it the quantity, so a price column further
right is ignored). Excel rows sent through WhatsApp, where the tabs become
runs of spaces, are read the same way. WhatsApp's `[date, time] Name:` prefix and list numbers
like `1.` are dropped. Lines for the same item are added together.

Names the app doesn't know can be matched to an item with
`matches: { "Pacific aura": 12 }`. Saving remembers them (as for stock sheets),
so the next list matches by itself; unknown names in `skipped` carry `name`,
`similar_to` and `similar_ids` to pick from.

A short name that is part of exactly one item's name ("Floriana" for
`RAYHAAN FLORIANA`) matches that item by itself, with `auto_matched: true` on
the line. If it's wrong, send the name in `no_match: ["Floriana"]` to treat it
as unknown. When two items hold the name, it stays unknown so someone picks.

Lines that can't be used change nothing and come back in `skipped` with the
line number and why: headings, totals, no quantity, an item that isn't in the
app (for transfers and sales, with close names under "Did you mean"), or not
enough stock where it is leaving from. Stock is checked again when saving, so
nothing goes below zero. A saved paste shows in `GET /uploads` as "Pasted
purchase", "Pasted transfer" or "Pasted sale", its sales count in
`/reports/sales`, and low-stock alerts go out as usual.

## Prices and the end-of-day report

Items can have a selling price in rupees (`price`, optional). Each sale keeps
the price it was sold at (`stock_movements.unit_price`), so changing a price
later doesn't change past days' totals. A sale recorded without a price
takes the item's price at that moment; sales recorded before prices existed
use the item's current price in reports.

A pasted sale can carry `prices: { "<item_id>": 2450 }` (or `null` for no
price). Preview lines then have `price`, and the summary has `amount` (rupees
for the priced lines) and `unpriced_units`. Saving keeps those prices on the
sales and remembers them as the items' prices. The app's **End of day sales**
uses this for one branch's WhatsApp list.

`/reports/sales` gives each line `amount` and `unit_price` (null when some
of its units have no price), plus `total_amount` and `unpriced_units`.
`/reports/sales/pdf` is the same report as an A4 PDF, named like
`sales-kandy-branch-2026-10-07.pdf`: the place and date, items, units and
total in LKR, and a table of what sold (one section per place when it's for
all places). Price columns are left out when nothing has a price. It uses the
PDF's built-in Helvetica font, so letters outside English (Sinhala, Tamil)
show as `?`.

## Importing items from a file

`scripts/import-items.js` adds items, and optionally their starting stock,
from a `.csv` or `.xlsx` file. Starting stock goes in as `receive` movements
(note "Imported from <file>"), the same as receiving stock in the app.

Templates to send the client: `templates/items-template.xlsx` and
`templates/items-template.csv`.

| Column | Required | Also recognised as |
|---|---|---|
| Item name | yes | Name, Item, Product, Description, Particulars |
| SKU | no | Code, Item code, Barcode, Part no |
| Unit | no, default `pcs` | Units, UOM |
| Qty | no | Quantity, Stock, Opening stock, On hand, Balance (main shop) |
| `<location name>` | no | Stock at that location, e.g. `Kandy Branch` or `Kandy Branch Qty` |

Header matching ignores case, spaces and punctuation, and title rows above the
header are skipped. Location columns must match a location that already exists
in the app, so add the branches first.

Run it from `backend/` with a `.env` whose `DATABASE_URL` is the database to
import into (the Supabase Session pooler string for the live app):

```sh
node --env-file=.env scripts/import-items.js items.xlsx           # preview only
node --env-file=.env scripts/import-items.js items.xlsx --apply   # import
```

The preview shows which column was read as what, columns that are not
imported, the new items, and every skipped row with the reason. Rows are
skipped when they have no name, a quantity that isn't a whole number of 0 or
more, or an item that is already in the app (same SKU, or same name when there
is no SKU) or earlier in the file. That makes running the same file twice
safe. `--apply` refuses to run while any column would be left out, because
that is usually stock for a location that hasn't been added yet; once you're
sure a column isn't needed, pass `--map "<header>=ignore"`. The import is all or nothing: if anything fails while saving, nothing is
saved.

If a column isn't recognised, say what it is with `--map`, as often as needed:

```sh
node --env-file=.env scripts/import-items.js items.xlsx \
  --map "Prod Desc=name" --map "Bal=stock" --map "Shop 2=stock:Kandy Branch" --map "Notes=ignore"
```

Use `--sheet "Sheet name"` to read a sheet other than the first. Old `.xls`
files need saving as `.xlsx` or `.csv` first.

## Run locally

Needs Node 22 and a Postgres database.

```sh
cd backend
cp .env.example .env      # then fill it in
npm install
node --env-file=.env src/server.js
```

Migrations listed in `migrations/index.js` run automatically on startup. A "Main Shop"
location is created on first run; rename it with `PATCH /locations/:id`.

Tests run against a real Postgres database, which they wipe:

```sh
TEST_DATABASE_URL=postgres://user:pass@localhost:5432/inventory_test npm test
```

## Deploy (Supabase + Vercel, both free)

Sign up for both with the project's own Gmail account, not a personal one, so
the whole thing can be handed over to the client.

**1. Database on Supabase**

1. Create a new project at [supabase.com](https://supabase.com). Pick the
   region closest to the shop and save the database password.
2. Open **Connect** (top bar) and copy the **Transaction pooler** connection
   string (the one on port **6543**). On Vercel the API runs as short-lived
   functions that open many brief connections, which is what the transaction
   pooler is built for.
3. Put your database password into that string in place of `[YOUR-PASSWORD]`.

**2. API on Vercel**

1. At [vercel.com](https://vercel.com), sign up with GitHub and allow it to
   see this repo.
2. **Add New > Project**, then **Import** this repo.
3. Next to **Root Directory**, click **Edit** and choose `backend`. Leave
   Framework Preset as **Other**.
4. Open **Environment Variables** and add:
   - `DATABASE_URL`: the Supabase string from step 1
   - `ADMIN_PASSWORD`: the password the shop owner will log in with
   - `JWT_SECRET`: a long random string, for example from
     `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`
     or any password generator (40+ characters)
   - `FIREBASE_SERVICE_ACCOUNT` (optional, for push notifications): the
     whole Firebase service account key file, see
     [docs/push-and-apk.md](../docs/push-and-apk.md)
5. Click **Deploy**. When it finishes, open
   `https://<your-project>.vercel.app/health`. It should show `{"ok":true}`.
   That URL is what the mobile app points at.

The database tables are created automatically on the first request. Every
push to `main` redeploys. If you change an environment variable later, go to
**Deployments**, open the latest one and choose **Redeploy** so it takes
effect.

`vercel.json` runs the API in Vercel's Singapore region (`sin1`), next to a
Supabase project in Southeast Asia. If your Supabase project is elsewhere,
change it to the [nearest region](https://vercel.com/docs/regions).

Things to know about the free plans:

- The first request after a quiet spell takes a second or two longer while
  the function starts.
- Supabase pauses a free project after a week with no activity. Daily use of
  the app keeps it awake; if it does pause, restore it from the Supabase
  dashboard.
- Vercel's free Hobby plan is meant for non-commercial use. For a paying
  client the Pro plan (about $20/month) is the safe choice; check Vercel's
  current terms before handover.
