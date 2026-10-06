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
already low. For now the hook only logs; push notifications through Firebase
Cloud Messaging plug in there.

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

## Run locally

Needs Node 20+ and a Postgres database.

```sh
cd backend
cp .env.example .env      # then fill it in
npm install
node --env-file=.env src/server.js
```

Migrations in `migrations/` run automatically on startup. A "Main Shop"
location is created on first run; rename it with `PATCH /locations/:id`.

Tests run against a real Postgres database, which they wipe:

```sh
TEST_DATABASE_URL=postgres://user:pass@localhost:5432/inventory_test npm test
```

## Deploy (Supabase + Render, both free)

Sign up for both with the project's own Gmail account, not a personal one, so
the whole thing can be handed over to the client.

**1. Database on Supabase**

1. Create a new project at [supabase.com](https://supabase.com). Pick the
   region closest to the shop and save the database password.
2. Open **Connect** (top bar) and copy the **Session pooler** connection
   string. Use the pooler, not the direct connection: Render can't reach
   Supabase's direct address.
3. Put your database password into that string in place of `[YOUR-PASSWORD]`.

**2. API on Render**

1. Push this repo to GitHub and connect that GitHub account at
   [render.com](https://render.com).
2. Choose **New > Blueprint** and pick this repo. Render reads `render.yaml`
   and sets up the service from `backend/`.
3. When it asks, fill in `DATABASE_URL` (the Supabase string) and
   `ADMIN_PASSWORD` (the password the shop owner will log in with).
   `JWT_SECRET` is generated for you.
4. Once it's live, open `https://<your-service>.onrender.com/health`. It
   should show `{"ok":true}`. That URL is what the mobile app points at.

Things to know about the free plans:

- Render's free service sleeps after 15 minutes without requests. The first
  request after that takes up to about a minute while it wakes. A paid
  instance (about $7/month) stays awake if the client finds that annoying.
- Supabase pauses a free project after a week with no activity. Daily use of
  the app keeps it awake; if it does pause, restore it from the Supabase
  dashboard.
