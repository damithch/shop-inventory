-- Other names an item goes by on stock sheets, e.g. the home sheet's
-- "HAWAS ICE" for "RASASI HAWAS ICE 100 ML". Saved when someone picks the
-- matching item in an upload preview, so the next sheet matches by itself.
CREATE TABLE item_aliases (
  name_key    TEXT PRIMARY KEY,  -- the name in lowercase letters and digits only
  name        TEXT NOT NULL,
  item_id     INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
