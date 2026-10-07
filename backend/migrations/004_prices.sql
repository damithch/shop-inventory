-- Selling price per item in rupees (LKR), optional. Each sale keeps the price
-- it was sold at, so a later price change doesn't change past days' totals.
ALTER TABLE items ADD COLUMN price NUMERIC(12, 2) CHECK (price >= 0);
ALTER TABLE stock_movements ADD COLUMN unit_price NUMERIC(12, 2) CHECK (unit_price >= 0);
