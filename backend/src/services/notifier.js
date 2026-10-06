// Hook for push notifications. The default implementation only logs; the
// FCM integration replaces it with setNotifier() at startup.
//
// A notifier receives an array of alerts, each:
//   { itemId, itemName, locationId, locationName, locationType, quantity, threshold }
// It is called after the stock change has been committed, and errors are
// logged rather than failing the request.

let notifier = async (alerts) => {
  for (const a of alerts) {
    console.log(`[low-stock] ${a.itemName} at ${a.locationName}: ${a.quantity} left (alert level ${a.threshold})`);
  }
};

function setNotifier(fn) {
  notifier = fn;
}

async function notifyLowStock(alerts) {
  if (!alerts.length) return;
  try {
    await notifier(alerts);
  } catch (err) {
    console.error('Failed to send low-stock notification:', err);
  }
}

module.exports = { setNotifier, notifyLowStock };
