# Changelog

## 0.4.0 (2026-10-07)

- **First run.** Without the `varlatch` CLI, the panel and the menu offer
  to install it: a terminal asks for your server's address to install the
  CLI version it runs, checks the download like an update, installs it as
  `~/.local/bin/varlatch`, and offers the first sign-in. With no server known
  yet, the panel asks for its address; **add server** signs in to another.
- **Sign in from another device** (CLI 0.14.0 or newer), for when the
  browser here has no passkey: the panel shows an address, a code, and a QR
  code of the address. Start it with **other device** on a waiting sign-in,
  **Log in from another device** in the menu, or the buttons on a failed
  sign-in's and the expiry notifications.
- **Session length:** the `sessionHours` setting (1 to 24; 0 keeps the
  server's default of 12 hours) applies to every sign-in the widget starts.
- **Fresher release check:** opening the panel checks again when the last
  check is over an hour old, and a cache older than the installed CLI is
  checked again; never more than once an hour.
- **Fix:** a sign-in whose process died before it could clean up (killed,
  or from before a reboot) no longer stays on the panel with a cancel that
  did nothing.
- The renew rows in the menu have a glyph.
- Offline tests (`tests/run.sh`) and CI: shellcheck, the manifest, and the
  helper's menu, sign-in, device sign-in, release check, and install paths.

## 0.3.0 (2026-10-07)

- Install with `omarchy plugin add`; the widget adds its own submenu to the
  Omarchy menu and keeps it in step with your sessions.
- The repository is public; release checks and downloads are anonymous.

## 0.2.0 (2026-09-28)

- The panel shows the CLI version and, with `checkUpdates` on, newer
  releases, with release notes and a checked update of the release CLI.
- The CLI version is read again when the panel opens.

## 0.1.0 (2026-09-25)

- First release: sessions, expiry, and sign-in, renewal, and sign-out in the
  Omarchy bar, read offline from `varlatch status --json`.
