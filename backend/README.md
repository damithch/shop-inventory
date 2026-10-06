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
| POST | `/items` | `{ name, sku?, unit? }` | |
| GET | `/items/:id` | | Item with its stock at every location |
| PATCH | `/items/:id` | `{ name?, sku?, unit?, archived? }` | |
| POST | `/stock/receive` | `{ item_id, quantity, location_id?, note? }` | |
| POST | `/stock/transfer` | `{ item_id, to_location_id, quantity, from_location_id?, note? }` | From the main shop unless `from_location_id` is given |
| POST | `/stock/sale` | `{ item_id, location_id, quantity, note? }` | |
| POST | `/stock/adjust` | `{ item_id, location_id, new_quantity, note? }` | |
| PUT | `/stock/threshold` | `{ item_id, location_id, threshold }` | `threshold: null` goes back to the default |
| GET | `/stock/low` | `?location_id=` | Everything at or below its alert level |
| GET | `/stock/movements` | `?item_id=&location_id=&limit=&before_id=` | Newest first |
| GET / PUT | `/settings` | `{ default_threshold }` | |
| POST | `/devices` | `{ token, platform? }` | Registers a phone's FCM token |
| DELETE | `/devices/:token` | | |
| GET | `/alerts` | `?limit=&before_id=` | Alert history, newest first |

Stock endpoints return `{ movement, levels, alerts }` so the app can update its
screen and show any alert straight away.

Errors are `{ "error": "message" }` with a 400, 401, 404 or 409 status. The
messages are written to be shown to the user as they are.

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
safe. The import is all or nothing: if anything fails while saving, nothing is
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
