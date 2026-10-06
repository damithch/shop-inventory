-- Stock sheets uploaded from the app (or imported with the script). Each
-- movement an upload creates points back to it.
CREATE TABLE stock_uploads (
  id           SERIAL PRIMARY KEY,
  filename     TEXT NOT NULL,
  summary      JSONB NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE stock_movements ADD COLUMN upload_id INTEGER REFERENCES stock_uploads(id);

-- For the daily sales report.
CREATE INDEX stock_movements_type_created ON stock_movements (type, created_at);
