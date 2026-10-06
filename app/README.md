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
- **Item**: stock at every location, total, recent changes. Tap a location to set the
  alert level for that item there (or go back to the default).
- **Low stock**: everything at or below its alert level, with a one-tap refill from
  the main shop (or add stock, for the main shop itself).
- **Settings**: the default alert level (3 to start), alert history, sign out.

When a stock change takes something down to its alert level, the app shows a
"Low stock" warning straight away. Push notifications to the phone come later
through Firebase Cloud Messaging.

## Run it

Needs Flutter 3.47 or newer.

```sh
cd app
flutter pub get
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000   # Android emulator to a local API
```

`API_BASE_URL` sets the server the app starts with. Without it the app uses
`http://10.0.2.2:3000`, which is your computer's `localhost` as seen from the
Android emulator. On a real phone, use your computer's LAN address or the
deployed Render URL. Either way it can be changed on the sign-in screen.

## Build the APK

```sh
flutter build apk --release --dart-define=API_BASE_URL=https://<your-service>.onrender.com
```

The file is `build/app/outputs/flutter-apk/app-release.apk`. (Release signing is
set up in a later step; for now it uses the debug key.)

## Tests

```sh
flutter analyze
flutter test
```

The tests run the app against an in-memory copy of the API (`test/fake_backend.dart`).
