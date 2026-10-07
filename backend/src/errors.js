class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

const badRequest = (msg) => new HttpError(400, msg);
const notFound = (msg) => new HttpError(404, msg);
const conflict = (msg) => new HttpError(409, msg);

// Validation helpers for request bodies.
function positiveInt(value, field) {
  const n = Number(value);
  if (!Number.isInteger(n) || n <= 0) throw badRequest(`${field} must be a positive whole number`);
  return n;
}

function nonNegativeInt(value, field) {
  const n = Number(value);
  if (!Number.isInteger(n) || n < 0) throw badRequest(`${field} must be zero or a positive whole number`);
  return n;
}

// A price in rupees: null clears it, otherwise 0 or more with at most 2 decimals.
function optionalPrice(value, field) {
  if (value === null || value === '') return null;
  const n = typeof value === 'string' ? Number(value.replace(/,/g, '')) : value;
  if (typeof n !== 'number' || !Number.isFinite(n) || n < 0 || n > 1e9 || Math.abs(Math.round(n * 100) - n * 100) > 1e-6) {
    throw badRequest(`${field} must be a price like 1500 or 1499.50`);
  }
  return Math.round(n * 100) / 100;
}

function nonEmptyString(value, field) {
  if (typeof value !== 'string' || !value.trim()) throw badRequest(`${field} is required`);
  return value.trim();
}

function optionalString(value) {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') throw badRequest('Expected text');
  return value.trim() || null;
}

module.exports = { HttpError, badRequest, notFound, conflict, positiveInt, nonNegativeInt, nonEmptyString, optionalString, optionalPrice };
