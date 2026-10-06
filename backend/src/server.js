const config = require('./config');
const migrate = require('./migrate');
const app = require('./app');

migrate()
  .then(() => {
    app.listen(config.port, () => console.log(`Inventory API listening on port ${config.port}`));
  })
  .catch((err) => {
    console.error(err.message);
    process.exit(1);
  });
