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
};
