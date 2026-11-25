# AJM Reborn POS — Windows Desktop

The Windows desktop edition wraps the existing root `index.html` in Electron.
It does not rebuild or redesign the POS interface; the HTML, login flow,
Supabase integration, local browser storage, reports, and transaction logic
remain the source of truth.

## Build

- Windows installer: `dist/AJM-Reborn-POS-1.0.0-x64.exe`
- Portable executable: `dist/AJM-Reborn-POS-Portable-1.0.0-x64.exe`

Run:

```sh
npm install
npm run build:win
```

## Printer notes

The existing Windows code path detects Windows and uses QZ Tray for USB
printing. Install and run the same QZ Tray service and the AJM local print
signer already used by the Windows browser setup. The app does not embed or
publish the private signing key. Bluetooth, USB device and serial-port
selection prompts are handled by the desktop host.

## Data and network

Electron keeps its application profile between launches and upgrades, so
localStorage data is retained when the same app ID is used. The app still
needs internet access for the existing CDN libraries and Supabase/cloud
features. The root `index.html` is packaged into the installer, so the app
shell itself does not depend on GitHub Pages being online.

## Security and distribution

Node integration is disabled in the page, context isolation and Chromium web
security remain enabled, and external links open in the default browser.
The installer is currently unsigned; Windows SmartScreen may show an
unknown-publisher warning until a code-signing certificate is configured.

## Automatic updates

The installed NSIS edition checks the GitHub prerelease feed after startup and
then every six hours. New installer packages download in the background.
When the download is complete, the user is asked whether to install and restart
now or defer it. Updates are published by the Windows Actions workflow together
with `latest.yml` and blockmap metadata required by electron-updater.

The portable EXE does not self-update; download the latest portable build
manually. The first installation that includes the updater must also be
installed manually over the existing NSIS installation. Subsequent NSIS
releases can update in-app. The app uses the same Electron app ID and user-data
directory, so app profile data is retained across normal in-place upgrades.
