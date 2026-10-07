const crypto = require('crypto');
const { promisify } = require('util');
const jwt = require('jsonwebtoken');
const config = require('./config');
const db = require('./db');
const { HttpError, badRequest } = require('./errors');

const scrypt = promisify(crypto.scrypt);
const MIN_PASSWORD_LENGTH = 6;

// The owner's password lives in settings as "admin_password" once it has been
// changed in the app. Until then ADMIN_PASSWORD from the environment is the
// password. Deleting that settings row brings the environment password back.
//
// Tokens carry the password's version ("pv"): the stored hash's salt, or
// "env". Changing the password signs out every phone except the one that
// changed it, which gets a new token.

// Each instance remembers the stored password briefly, so most requests skip
// the database. A change made on another instance is seen within this time.
const CACHE_MS = 30_000;
let cached = null;

async function storedPassword() {
  if (cached && Date.now() - cached.at < CACHE_MS) return cached.value;
  const { rows } = await db.query("SELECT value FROM settings WHERE key = 'admin_password'");
  let value = null;
  if (rows.length) {
    const [, salt, hash] = rows[0].value.split('$');
    value = { salt, hash };
  }
  cached = { at: Date.now(), value };
  return value;
}

function sameBytes(a, b) {
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

async function hashPassword(password, salt) {
  return Buffer.from(await scrypt(String(password), Buffer.from(salt, 'hex'), 32));
}

// Returns the password version when the password is right, else null.
async function checkPassword(given) {
  const stored = await storedPassword();
  if (stored) {
    return sameBytes(await hashPassword(given, stored.salt), Buffer.from(stored.hash, 'hex')) ? stored.salt : null;
  }
  const a = crypto.createHash('sha256').update(String(given)).digest();
  const b = crypto.createHash('sha256').update(config.adminPassword).digest();
  return crypto.timingSafeEqual(a, b) ? 'env' : null;
}

function issueToken(version) {
  return jwt.sign({ role: 'owner', pv: version }, config.jwtSecret, { expiresIn: config.tokenTtl });
}

async function login(req, res) {
  const version = req.body ? await checkPassword(req.body.password ?? '') : null;
  if (!version) throw new HttpError(401, 'Wrong password');
  res.json({ token: issueToken(version), expires_in: config.tokenTtl });
}

async function changePassword(req, res) {
  const current = req.body?.current_password;
  const next = req.body?.new_password;
  if (typeof current !== 'string' || !current) throw badRequest('Enter your current password');
  if (typeof next !== 'string' || next.length < MIN_PASSWORD_LENGTH) {
    throw badRequest(`The new password must be at least ${MIN_PASSWORD_LENGTH} characters`);
  }
  cached = null;
  if (!(await checkPassword(current))) throw badRequest('The current password is wrong');
  if (next === current) throw badRequest('The new password is the same as the current one');

  const salt = crypto.randomBytes(16).toString('hex');
  const hash = (await hashPassword(next, salt)).toString('hex');
  await db.query(
    `INSERT INTO settings (key, value) VALUES ('admin_password', $1)
     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
    [`scrypt$${salt}$${hash}`],
  );
  cached = null;
  res.json({ token: issueToken(salt), expires_in: config.tokenTtl });
}

async function requireAuth(req, res, next) {
  const header = req.get('authorization') || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) throw new HttpError(401, 'Sign in required');
  try {
    req.user = jwt.verify(token, config.jwtSecret);
  } catch {
    throw new HttpError(401, 'Session expired, sign in again');
  }
  // Tokens from before versions existed belong to the environment password.
  const current = (await storedPassword())?.salt ?? 'env';
  if ((req.user.pv ?? 'env') !== current) throw new HttpError(401, 'The password was changed, sign in again');
  next();
}

// For tests, which wipe the database between runs.
function forgetCachedPassword() {
  cached = null;
}

module.exports = { login, changePassword, requireAuth, checkPassword, forgetCachedPassword };
