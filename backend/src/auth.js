const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const config = require('./config');
const { HttpError } = require('./errors');

function passwordMatches(given) {
  const a = crypto.createHash('sha256').update(String(given)).digest();
  const b = crypto.createHash('sha256').update(config.adminPassword).digest();
  return crypto.timingSafeEqual(a, b);
}

function login(req, res) {
  if (!req.body || !passwordMatches(req.body.password ?? '')) {
    throw new HttpError(401, 'Wrong password');
  }
  const token = jwt.sign({ role: 'owner' }, config.jwtSecret, { expiresIn: config.tokenTtl });
  res.json({ token, expires_in: config.tokenTtl });
}

function requireAuth(req, res, next) {
  const header = req.get('authorization') || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) throw new HttpError(401, 'Sign in required');
  try {
    req.user = jwt.verify(token, config.jwtSecret);
  } catch {
    throw new HttpError(401, 'Session expired, sign in again');
  }
  next();
}

module.exports = { login, requireAuth };
