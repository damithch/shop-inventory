function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable ${name}`);
  return value;
}

module.exports = {
  port: Number(process.env.PORT) || 3000,
  databaseUrl: required('DATABASE_URL'),
  // Set DATABASE_SSL=false for a local Postgres without SSL.
  databaseSsl: process.env.DATABASE_SSL !== 'false',
  adminPassword: required('ADMIN_PASSWORD'),
  jwtSecret: required('JWT_SECRET'),
  tokenTtl: process.env.TOKEN_TTL || '30d',
  // The shop's time zone, so "today's sales" means the shop's day.
  timeZone: process.env.SHOP_TIMEZONE || 'Asia/Colombo',
  // Contents of the Firebase service account key file, for push notifications.
  firebaseServiceAccount: process.env.FIREBASE_SERVICE_ACCOUNT || null,
  // Settings > Reset and delete (every /reset endpoint, the backup too) is
  // off unless RESET_ENABLED=true. Read on every request so tests can switch it.
  get resetEnabled() {
    return process.env.RESET_ENABLED === 'true';
  },
  // Export to Excel/CSV in the app is off unless EXPORTS_ENABLED=true. Read on
  // every request so tests can switch it.
  get exportsEnabled() {
    return process.env.EXPORTS_ENABLED === 'true';
  },
};
