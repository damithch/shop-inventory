// Sends low-stock alerts to every registered phone through Firebase Cloud
// Messaging (the HTTP v1 API). Uses the Firebase service account key from the
// FIREBASE_SERVICE_ACCOUNT environment variable; without it, alerts are only
// logged (see notifier.js).
const jwt = require('jsonwebtoken');
const db = require('../db');

const SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';

// Accepts the key file's JSON as pasted, or base64-encoded.
function parseServiceAccount(raw) {
  if (!raw) return null;
  let text = raw.trim();
  if (!text.startsWith('{')) text = Buffer.from(text, 'base64').toString('utf8');
  let account;
  try {
    account = JSON.parse(text);
  } catch {
    throw new Error('FIREBASE_SERVICE_ACCOUNT is not valid JSON. Paste the whole service account key file.');
  }
  for (const key of ['project_id', 'client_email', 'private_key']) {
    if (!account[key]) throw new Error(`FIREBASE_SERVICE_ACCOUNT is missing "${key}". Is it a service account key file?`);
  }
  return account;
}

function alertMessage(alert) {
  const where = alert.locationType === 'main' ? 'Main shop' : alert.locationName;
  return {
    notification: {
      title: `Low stock: ${alert.itemName}`,
      body: `${where}: ${alert.quantity} left (alert level ${alert.threshold})`,
    },
    data: {
      type: 'low_stock',
      item_id: String(alert.itemId),
      location_id: String(alert.locationId),
    },
    android: {
      priority: 'HIGH',
      // A newer alert for the same item and place replaces the older one.
      notification: { tag: `low-stock-${alert.itemId}-${alert.locationId}` },
    },
  };
}

function isUnregistered(body) {
  const details = body?.error?.details ?? [];
  return details.some((d) => d.errorCode === 'UNREGISTERED');
}

const dbTokens = {
  async list() {
    const { rows } = await db.query('SELECT token FROM device_tokens');
    return rows.map((r) => r.token);
  },
  async remove(tokens) {
    await db.query('DELETE FROM device_tokens WHERE token = ANY($1)', [tokens]);
  },
};

function createFcmNotifier(account, { fetch = globalThis.fetch, tokens = dbTokens } = {}) {
  const tokenUri = account.token_uri || 'https://oauth2.googleapis.com/token';
  const sendUrl = `https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`;
  let cached = null;

  async function accessToken() {
    const now = Math.floor(Date.now() / 1000);
    if (cached && cached.expiresAt - 60 > now) return cached.token;
    const assertion = jwt.sign(
      { iss: account.client_email, scope: SCOPE, aud: tokenUri, iat: now, exp: now + 3600 },
      account.private_key,
      { algorithm: 'RS256' },
    );
    const res = await fetch(tokenUri, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion }).toString(),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(`Firebase sign-in failed (${res.status}): ${body.error_description || body.error || ''}`);
    cached = { token: body.access_token, expiresAt: now + (body.expires_in || 3600) };
    return cached.token;
  }

  return async function sendLowStockPush(alerts) {
    const deviceTokens = await tokens.list();
    if (!deviceTokens.length) return;
    const auth = `Bearer ${await accessToken()}`;
    const stale = new Set();

    await Promise.all(alerts.flatMap((alert) => deviceTokens.map(async (token) => {
      const res = await fetch(sendUrl, {
        method: 'POST',
        headers: { Authorization: auth, 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: { token, ...alertMessage(alert) } }),
      });
      if (res.ok) return;
      const body = await res.json().catch(() => ({}));
      // The app was uninstalled or the phone got a new token.
      if (res.status === 404 || isUnregistered(body)) {
        stale.add(token);
      } else {
        console.error(`Push to a phone failed (${res.status}): ${body?.error?.message || ''}`);
      }
    })));

    if (stale.size) await tokens.remove([...stale]);
  };
}

module.exports = { parseServiceAccount, createFcmNotifier, alertMessage };
