// Firebase push sender, with Google's servers faked. Needs no database.
require('./helpers'); // test environment variables
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const jwt = require('jsonwebtoken');
const { parseServiceAccount, createFcmNotifier } = require('../src/services/push');

const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  publicKeyEncoding: { type: 'spki', format: 'pem' },
});

const account = {
  type: 'service_account',
  project_id: 'shop-test',
  client_email: 'push@shop-test.iam.gserviceaccount.com',
  private_key: privateKey,
  token_uri: 'https://oauth2.googleapis.com/token',
};

const alert = {
  itemId: 7, itemName: 'Rice 5kg', locationId: 2, locationName: 'Kandy Branch', locationType: 'branch', quantity: 3, threshold: 3,
};

function fakeGoogle({ failFor = {} } = {}) {
  const calls = { tokenRequests: 0, sent: [] };
  const fetch = async (url, init) => {
    if (url === account.token_uri) {
      calls.tokenRequests += 1;
      const assertion = new URLSearchParams(init.body).get('assertion');
      const claims = jwt.verify(assertion, publicKey, { algorithms: ['RS256'] });
      assert.equal(claims.iss, account.client_email);
      assert.equal(claims.scope, 'https://www.googleapis.com/auth/firebase.messaging');
      return Response.json({ access_token: 'access-1', expires_in: 3600 });
    }
    assert.equal(url, 'https://fcm.googleapis.com/v1/projects/shop-test/messages:send');
    assert.equal(init.headers.Authorization, 'Bearer access-1');
    const { message } = JSON.parse(init.body);
    calls.sent.push(message);
    const fail = failFor[message.token];
    if (fail) return Response.json(fail.body, { status: fail.status });
    return Response.json({ name: 'projects/shop-test/messages/1' });
  };
  return { fetch, calls };
}

function memoryTokens(list) {
  const tokens = { list: async () => [...list], remove: async (gone) => { list = list.filter((t) => !gone.includes(t)); } };
  return { tokens, current: () => list };
}

test('reads the key file as pasted or base64-encoded', () => {
  const json = JSON.stringify(account);
  assert.equal(parseServiceAccount(json).client_email, account.client_email);
  assert.equal(parseServiceAccount(Buffer.from(json).toString('base64')).project_id, 'shop-test');
  assert.equal(parseServiceAccount(''), null);
  assert.throws(() => parseServiceAccount('{"project_id":"x"}'), /missing "client_email"/);
  assert.throws(() => parseServiceAccount('{not json'), /not valid JSON/);
});

test('sends each alert to every registered phone', async () => {
  const google = fakeGoogle();
  const { tokens } = memoryTokens(['phone-a', 'phone-b']);
  const send = createFcmNotifier(account, { fetch: google.fetch, tokens });
  await send([alert]);

  assert.deepEqual(google.calls.sent.map((m) => m.token).sort(), ['phone-a', 'phone-b']);
  const message = google.calls.sent[0];
  assert.equal(message.notification.title, 'Low stock: Rice 5kg');
  assert.equal(message.notification.body, 'Kandy Branch: 3 left (alert level 3)');
  assert.deepEqual(message.data, { type: 'low_stock', item_id: '7', location_id: '2' });

  // The sign-in token is reused for later alerts.
  await send([{ ...alert, locationType: 'main', locationName: 'Main Shop' }]);
  assert.equal(google.calls.tokenRequests, 1);
  assert.equal(google.calls.sent.at(-1).notification.body, 'Main shop: 3 left (alert level 3)');
});

test('forgets phones that no longer have the app', async () => {
  const google = fakeGoogle({
    failFor: {
      'phone-gone': { status: 404, body: { error: { status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } } },
      'phone-busy': { status: 503, body: { error: { message: 'unavailable' } } },
    },
  });
  const store = memoryTokens(['phone-ok', 'phone-gone', 'phone-busy']);
  const send = createFcmNotifier(account, { fetch: google.fetch, tokens: store.tokens });
  await send([alert]);
  assert.deepEqual(store.current(), ['phone-ok', 'phone-busy']);
});

test('does nothing when no phone is registered', async () => {
  const google = fakeGoogle();
  const send = createFcmNotifier(account, { fetch: google.fetch, tokens: memoryTokens([]).tokens });
  await send([alert]);
  assert.equal(google.calls.tokenRequests, 0);
});
