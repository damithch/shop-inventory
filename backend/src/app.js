const express = require('express');
const { login, requireAuth } = require('./auth');
const { HttpError } = require('./errors');
const config = require('./config');
const { setNotifier } = require('./services/notifier');
const { parseServiceAccount, createFcmNotifier } = require('./services/push');

// Push notifications through Firebase, when its key is configured.
try {
  const account = parseServiceAccount(config.firebaseServiceAccount);
  if (account) setNotifier(createFcmNotifier(account));
  else console.log('FIREBASE_SERVICE_ACCOUNT not set: low-stock alerts are logged, not pushed');
} catch (err) {
  console.error(`Push notifications are off: ${err.message}`);
}

const app = express();
app.use(express.json());

app.get('/health', (req, res) => res.json({ ok: true }));
app.post('/auth/login', login);

app.use(requireAuth);
app.use('/locations', require('./routes/locations'));
app.use('/items', require('./routes/items'));
app.use('/stock', require('./routes/stock'));
app.use('/uploads', require('./routes/uploads'));
app.use('/reports', require('./routes/reports'));
app.use('/paste', require('./routes/paste'));
app.use('/', require('./routes/misc'));

app.use((req, res) => res.status(404).json({ error: 'Not found' }));

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  if (err instanceof HttpError) return res.status(err.status).json({ error: err.message });
  if (err.type === 'entity.parse.failed') return res.status(400).json({ error: 'Invalid JSON' });
  console.error(err);
  res.status(500).json({ error: 'Something went wrong' });
});

module.exports = app;
