# Push notifications and the APK

This is the last bit of setup: Firebase sends a notification to the phone when
stock runs low, and GitHub builds the app file (APK) to install on the phone.
You do steps 1 to 4 once. Nothing here costs money.

The app already points at the live server
(`https://backend-eight-lemon-fwgmzqzwyt.vercel.app`), so there is nothing to
type on the phone except the password.

## 1. Create the Firebase project

1. Go to [console.firebase.google.com](https://console.firebase.google.com)
   and sign in with the Google account that should own the project.
2. Click **Create a project** (or **Add project**). Name it `Shop Inventory`.
   You can turn Google Analytics **off**. Click **Create project**, then
   **Continue**.

## 2. Add the Android app and download `google-services.json`

1. On the project's home page, click the **Android** icon (or **Add app** >
   **Android**).
2. **Android package name**: type exactly `com.shopinventory.shop_inventory`.
   Leave the other boxes empty and click **Register app**.
3. Click **Download google-services.json** and keep the file.
4. Click **Next** through the remaining steps and then **Continue to console**.
   The code changes those steps describe are already done.

## 3. Give the server its Firebase key (Vercel)

1. In Firebase, click the gear icon next to **Project Overview** >
   **Project settings** > **Service accounts** tab.
2. Click **Generate new private key** > **Generate key**. A `.json` file
   downloads. Treat it like a password: don't email it or put it on GitHub.
3. Open that file in Notepad, press **Ctrl+A** then **Ctrl+C** to copy all of it.
4. In [vercel.com](https://vercel.com), open the backend project > **Settings**
   > **Environment Variables**. Add:
   - Key: `FIREBASE_SERVICE_ACCOUNT`
   - Value: paste (Ctrl+V) the whole file

   Click **Save**.
5. Go to **Deployments**, click the **...** next to the newest one and choose
   **Redeploy**. Wait for it to finish. (Before step 7 below, merge the pull
   requests first; merging also redeploys.)

## 4. Give GitHub the app's Firebase settings

1. On GitHub, open the `shop-inventory` repo > **Settings** >
   **Secrets and variables** > **Actions** > **New repository secret**.
2. Name: `GOOGLE_SERVICES_JSON`. Secret: open `google-services.json` from step 2
   in Notepad, copy all of it and paste it here. Click **Add secret**.

## 5. Build the APK

1. On GitHub, open the **Actions** tab, click **Build APK** on the left, then
   **Run workflow** > **Run workflow** (branch `main`).
2. Wait for the run to get a green tick (about 5 to 10 minutes). Click it.
3. Under **Artifacts** at the bottom, click **shop-inventory-apk**. A zip
   downloads; inside is `app-release.apk`.

It also builds by itself every time app changes are merged into `main`.

## 6. Install it on the phone

1. Copy `app-release.apk` to the phone (USB cable, Google Drive, or WhatsApp to
   yourself) and tap it.
2. If Android asks, allow installing apps from that source, then **Install**.
3. Open **Shop Inventory**, sign in with the shop password, and tap **Allow**
   when it asks to send notifications.

To check push works: on an item, set the alert level at a location to a number
above its current stock (tap the location on the item page). The phone should
get a "Low stock" notification within a few seconds. Close the app first to see
it as a normal notification; while the app is open it shows at the bottom of
the screen instead.

Every phone signed in to the app gets the alerts.

**Installing a newer APK later:** each GitHub build is signed with a new
temporary key for now, so Android refuses to install it over the old one.
Uninstall the old app first (nothing is lost; all data is on the server), then
install the new one and sign in again. A permanent signing key will fix this
before handing the app to the client.

## Building on your own computer instead

Only if you already have Flutter and Android Studio installed:

1. Put `google-services.json` in `app/android/app/`.
2. In a terminal:

   ```sh
   cd app
   flutter pub get
   flutter build apk --release
   ```

3. The APK is at `app/build/app/outputs/flutter-apk/app-release.apk`.

## If notifications don't arrive

- In Vercel, open the latest deployment > **Logs**. `Push notifications are
  off: ...` means the `FIREBASE_SERVICE_ACCOUNT` value is wrong; paste the whole
  file again and redeploy. `FIREBASE_SERVICE_ACCOUNT not set` means it is
  missing or you haven't redeployed since adding it.
- If the APK build shows a yellow warning about `GOOGLE_SERVICES_JSON`, the
  secret from step 4 is missing; add it and run the build again.
- On the phone: **Settings > Apps > Shop Inventory > Notifications** must be on.
- An alert is sent once when an item drops to its alert level, not again while
  it stays low. Refill it above the level to get a new alert next time.
