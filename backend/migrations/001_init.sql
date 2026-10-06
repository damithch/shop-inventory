-- Locations: exactly one main shop plus any number of branches.
CREATE TABLE locations (
  id          SERIAL PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  type        TEXT NOT NULL CHECK (type IN ('main', 'branch')),
  archived    BOOLEAN NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX one_main_location ON locations (type) WHERE type = 'main';
INSERT INTO locations (name, type) VALUES ('Main Shop', 'main');

CREATE TABLE items (
  id          SERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  sku         TEXT UNIQUE,
  unit        TEXT NOT NULL DEFAULT 'pcs',
  archived    BOOLEAN NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Current balance of each item at each location. Only ever changed in the
-- same transaction that writes a stock_movements row, so the two always agree.
CREATE TABLE stock_levels (
  item_id      INTEGER NOT NULL REFERENCES items(id),
  location_id  INTEGER NOT NULL REFERENCES locations(id),
  quantity     INTEGER NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  -- NULL means "use the global default threshold" from settings.
  threshold    INTEGER CHECK (threshold >= 0),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (item_id, location_id)
);

-- Every change to stock. quantity is always positive; from/to say where it moved.
--   receive:  new stock arrives at a location (to_location_id)
--   transfer: from_location_id -> to_location_id
--   sale:     stock leaves a location (from_location_id)
--   adjust:   stock count correction; from (decrease) or to (increase)
CREATE TABLE stock_movements (
  id                SERIAL PRIMARY KEY,
  item_id           INTEGER NOT NULL REFERENCES items(id),
  type              TEXT NOT NULL CHECK (type IN ('receive', 'transfer', 'sale', 'adjust')),
  quantity          INTEGER NOT NULL CHECK (quantity > 0),
  from_location_id  INTEGER REFERENCES locations(id),
  to_location_id    INTEGER REFERENCES locations(id),
  note              TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (from_location_id IS NOT NULL OR to_location_id IS NOT NULL)
);
CREATE INDEX stock_movements_item ON stock_movements (item_id, created_at DESC);
CREATE INDEX stock_movements_from ON stock_movements (from_location_id, created_at DESC);
CREATE INDEX stock_movements_to ON stock_movements (to_location_id, created_at DESC);

CREATE TABLE settings (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
);
INSERT INTO settings (key, value) VALUES ('default_threshold', '3');

-- Phones registered for push notifications (FCM tokens).
CREATE TABLE device_tokens (
  token       TEXT PRIMARY KEY,
  platform    TEXT NOT NULL DEFAULT 'android',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Log of low-stock alerts raised, so the app can show a history.
CREATE TABLE low_stock_alerts (
  id           SERIAL PRIMARY KEY,
  item_id      INTEGER NOT NULL REFERENCES items(id),
  location_id  INTEGER NOT NULL REFERENCES locations(id),
  quantity     INTEGER NOT NULL,
  threshold    INTEGER NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX low_stock_alerts_created ON low_stock_alerts (created_at DESC);
