# Shop Inventory app

Flutter app for the shop owner. It talks to the API in `../backend`.

## Screens

- **Sign in**: the owner password (`ADMIN_PASSWORD` on the server). "Server address"
  under the button changes which API the app talks to; it is remembered on the phone.
- **Main shop**: every item and how many are in the main shop. Search, filter to low
  stock, tap an item for details. The **Stock** button adds stock, moves stock to a
  branch, records a sale, corrects a count, or adds a new item.
- **Branches**: list of branches with item and unit counts; add a branch. Open one to
  see its stock, record a sale there, move stock out, rename or remove it.
  From any place (the main shop too), **Stock > Move a list of items** pastes a
  list to move in one go; a line naming a branch ("Dehiwela") picks where it
  goes. **Record sales from a list** does the same for sales. Tap a name the
  app doesn't know to pick the item it is; the app remembers it.
- **Item**: stock at every location, total, recent changes. Tap a location to set the
  alert level for that item there (or go back to the default).
- **Low stock**: everything at or below its alert level, with a one-tap refill from
  the main shop (or add stock, for the main shop itself).
- **Sales**: what sold on a day, per item and location (chips filter to one place), with arrows and a date
  picker to change the day. **Add list** > **Upload stock sheet** picks an Excel (.xlsx) or
  CSV stock count from the phone and the location it's for, shows what would
  change (new items, sold, received, rows that can't be used, new items that
  look like existing ones), and saves it on **Save**. Tap a new item to say
  which item already in the app it is ("HAWAS ICE" is "RASASI HAWAS ICE 100 ML");
  the app remembers it for later sheets and pasted lists. Upload the shop's count
  each evening: drops since the last count are recorded as sales. Past uploads
  are under the history button. **Add list** > **Paste list** takes a list copied from Excel
  or WhatsApp: choose Purchase (stock added at Home), Transfer (from Home to
  a shop) or Sale (at a shop), paste, check the preview, then **Save**.
  **Add list** > **End of day sales** is the same Sale list for one branch,
  with prices: tap a line's price to set it (it's remembered for next time),
  and the preview shows the day's total in rupees. Saving offers the day's
  PDF report to share or save. The PDF button at the top of Sales makes the
  report for the day shown, for one place or all places.
- **Settings**: the default alert level (3 to start), alert history,
  **Export** (stock at one place or all places, or the item list, as Excel or
  CSV, then Share or Save to phone), **Change password** (other phones are
  signed out), sign out.

When a stock change takes something down to its alert level, the app shows a
"Low stock" warning straight away, and every signed-in phone gets a push
notification through Firebase Cloud Messaging (also when the change was made
on another phone). The app registers for push after sign-in and unregisters on
sign-out (`lib/push.dart`, `lib/session.dart`). Built without
`android/app/google-services.json`, the app works the same minus push.

## Run it

Needs Flutter 3.47 or newer.

```sh
cd app
flutter pub get
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000   # Android emulator to a local API
```

`API_BASE_URL` sets the server the app starts with. Without it the app uses the
live server, `https://backend-eight-lemon-fwgmzqzwyt.vercel.app`. For the
emulator talking to an API on your computer, use `http://10.0.2.2:3000` as
above. Either way it can be changed on the sign-in screen.

## Build the APK

GitHub builds it: **Actions > Build APK > Run workflow**, then download
`shop-inventory-apk` from the finished run. Full steps, including the Firebase
setup for push notifications, are in [docs/push-and-apk.md](../docs/push-and-apk.md).

To build locally instead, put `google-services.json` in `android/app/` and run:

```sh
flutter build apk --release
```

The file is `build/app/outputs/flutter-apk/app-release.apk`. (Release signing is
set up in a later step; for now it uses the debug key.)

## Tests

```sh
flutter analyze
flutter test
```

The tests run the app against an in-memory copy of the API (`test/fake_backend.dart`).
