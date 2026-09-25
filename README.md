# Varlatch for Omarchy

Shows your [Varlatch](https://github.com/varlatch/varlatch) sessions in the
Omarchy bar: which servers you are signed in to, when each credential
expires, and one-click sign-in, renewal, and sign-out. Everything it shows
comes from `varlatch status --json`.

## What it shows

The Varlatch mark, icon only, with its state told by color:

- **theme foreground:** at least one live session
- **amber:** less than 20% of a credential's lifetime remains
- **red:** signed out, or a credential has expired
- **red, dimmed:** the `varlatch` CLI is missing or too old

A left click opens a panel under the widget with one row per session: a
live countdown, sign-out and sign-in per server, a **renew** button for
every live session, and buttons to verify credentials and open the
dashboard. A middle click opens the **Varlatch** submenu of the Omarchy
menu, which SUPER+SPACE also finds. The widget keeps that submenu in step
with your sessions. After a full sign-out, "Log in" still targets the last
server you used, remembered in `~/.local/state/varlatch-omarchy/servers.json`.

"Verify" runs `varlatch status --probe`: one authenticated request per
stored credential, to check that it is still valid and its server
reachable.

Moving into *expiring* or *expired* triggers one desktop notification each,
with a **Renew now** or **Log in** button.

Renewing means signing in again to the same server. From Varlatch 0.10.0 on,
the CLI revokes the credential it replaces only after the new one is
verified and saved, so a cancelled or failed browser sign-in never signs you
out.

Signing in needs no terminal window. The CLI opens your browser for the
passkey prompt, and while it waits the panel shows "Signing in to …" with
**open link**, for when the page opens in the wrong browser, and **cancel**.
The result arrives as a notification.

## Privacy

The widget polls `varlatch status --json` on a timer, which reads local
files only (`~/.config/varlatch/credentials.json` and repository-local
state). It never uses a stored credential on its own; the only network
requests are the ones you start with a click.

## Settings

Set these on the widget's entry in `~/.config/omarchy/shell.json`:

- `refreshIntervalSec`: how often to poll, in seconds (default 30, minimum
  15).
- `varlatchCommand`: the CLI to run (default `varlatch` on your `PATH`). For
  a development build, use for example
  `node /path/to/varlatch/apps/cli/dist/main.js`.
- `notifyExpiry`: `on` or `off`.
- `showWhenLoggedOut`: `on` or `off`. With `off`, the widget hides entirely
  when no credentials are stored.
- `showLocalhost`: `on` or `off` (default `off`). With `off`, sessions on
  `localhost` or `127.*` are ignored everywhere: the bar color, the panel,
  the menu, notifications, and the sign-in and dashboard targets.

## Install

1. Clone this repository into `~/.config/omarchy/plugins/varlatch`.
2. Add `{ "id": "varlatch" }` to a bar section in
   `~/.config/omarchy/shell.json`.
3. Append the entries from `menu-entries.jsonc.example` to
   `~/.config/omarchy/extensions/omarchy-menu.jsonc`, replacing
   `/home/USER` with your home directory. The widget rewrites that block
   from then on.

Requires `jq` and the Varlatch CLI 0.8.0 or newer. With a CLI before 0.10.0,
the widget works out the *expiring* state itself.

## License

Copyright © 2026 Robotsson. Licensed under the Apache License 2.0; see
[`LICENSE`](LICENSE).
