// Vercel entry point. Every request is routed here (see vercel.json).
// Pending migrations run once per instance before the first request is served.
const express = require('express');
const migrate = require('../src/migrate');
const app = require('../src/app');

let ready = null;

const handler = express();
handler.use(async (req, res, next) => {
  try {
    ready ??= migrate();
    await ready;
    next();
  } catch (err) {
    ready = null; // try again on the next request
    console.error(err);
    res.status(503).json({ error: 'Server is starting up, please try again' });
  }
});
handler.use(app);

module.exports = handler;
