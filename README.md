# NextDNS — an Omarchy bar widget

Whether NextDNS is the system resolver, which resolver replaces it when it is
off, and an automatic fallback for networks that block it, such as captive
portals and guest Wi-Fi.

Installs as the bar widget `blacksheep.nextdns`.

## What you need

- A NextDNS account and its profile id (the short code on my.nextdns.io).
- The `nextdns` CLI, from the AUR: `yay -S --needed nextdns`.

## Install

The widget is only the UI. Switching the system resolver needs root, so a small
privileged half ships in `system/` and `install.sh` puts it in place. Read it
first: it is short, and every file it installs is listed at the top.

```bash
# 1. The NextDNS CLI
yay -S --needed nextdns

# 2. The widget
omarchy plugin add https://github.com/jonspinks/omarchy-nextdns --enable

# 3. Its privileged half. Asks for your profile id if /etc/nextdns.conf has none.
~/.config/omarchy/plugins/blacksheep.nextdns/install.sh

omarchy restart shell
```

`install.sh --check` reports what is in place and changes nothing.

**Don't use Omarchy's DNS provider picker** (Settings, or the shortcut in the
Wi-Fi panel) while this is installed. It rewrites the resolver settings
wholesale and drops NextDNS. Use the widget's Off and "When off" choices
instead; they go through the same `omarchy-dns` command safely.

## Update

```bash
omarchy plugin update blacksheep.nextdns
~/.config/omarchy/plugins/blacksheep.nextdns/install.sh   # refresh the root-owned copies
```

`install.sh --check` says when an installed script differs from the plugin's.

## Remove

```bash
~/.config/omarchy/plugins/blacksheep.nextdns/install.sh --uninstall
omarchy plugin remove blacksheep.nextdns
omarchy restart shell
```

`--uninstall` moves DNS to the fallback resolver **first**, so nothing is left
pointed at a daemon nobody manages, then removes every file `install.sh` put in
place. It leaves `/etc/nextdns.conf`, the NextDNS daemon's own unit and the
`nextdns` package, because those are yours.

## How it works

NextDNS runs as a local DNS-over-HTTPS proxy on `127.0.0.1:53`, and the system
resolver points at it. All resolver changes go through Omarchy's own
`omarchy-dns`, so the widget and Omarchy's settings never disagree about what
is configured.

`90-nextdns-portal`, a NetworkManager dispatcher script, re-evaluates on every
network change, and `nextdns-auto.timer` re-evaluates every 30 s. The timer
exists because **no NetworkManager event fires when you sign in to a captive
portal**: something has to notice you are through and switch back.

`nextdns-apply auto` tells two look-alike failures apart. Both show up as
"127.0.0.1:53 stopped answering":

- **The daemon has wedged**: alive and bound, but it has lost its upstream
  connections and never rebuilds them. The fix is a restart.
- **The network blocks DNS-over-HTTPS**: a captive portal, or a guest network
  that only allows its own resolver. A restart achieves nothing; the fix is to
  step aside to Cloudflare, Google or the network's own resolver until NextDNS
  is reachable again.

Checking whether NextDNS's own endpoint is reachable, by IP so the check never
depends on the resolver it is diagnosing, separates them exactly.

`nextdns-toggle` is the panel's manual override (`toggle`, `on`, `off`, `auto`),
plus which resolver "off" falls back to.

## Privilege model

The bar runs as you. It reads state from world-readable files
(`/var/lib/nextdns-toggle/`, `/run/nextdns-toggle/last-result`, the resolver
config Omarchy writes, and `/etc/nextdns.conf` for the profile id it shows)
through `scripts/nextdns-stats`, which runs from the plugin folder as a fixed
command.

Everything that needs root goes through one `sudoers` drop-in,
[`system/sudoers.d/99-nextdns-toggle`](system/sudoers.d/99-nextdns-toggle),
which lists every command with its exact arguments and has **no wildcards**:
`nextdns-toggle toggle|on|off|auto`, and `nextdns-toggle provider` with only
`Cloudflare`, `Google` or `DHCP`, never an arbitrary server.

The scripts it grants are installed root-owned in `/usr/local/bin`, never run
from the plugin folder, so nothing you can write is ever run as root. They keep
their state and locks in root-owned directories, never in a shared temporary
one. `install.sh` fills in your account name, validates the drop-in with
`visudo -c` in a temporary location and only then moves it into place: a
sudoers file that does not parse locks sudo out entirely.

The drop-in is named `99-` because sudo applies the **last** matching rule, so a
blanket `%wheel ALL=(ALL:ALL) ALL` sorting after it would bring the password
prompt back.

## Design notes

- "Active" is read from the file `omarchy-dns` writes
  (`/etc/NetworkManager/conf.d/20-omarchy-dns.conf`), not from the widget's own
  override. The first click after an automatic change has to go the way you
  see, not the way the widget last asked.
- The failure worth catching is a daemon that stays `active` and bound to
  `127.0.0.1:53` while answering nothing, which `systemctl is-active` cannot
  see. The stats script sends one real DNS query to decide.
- The "When off" row is a `Ui/ButtonGroup` with `focusable: false`, so it does
  not swallow the panel's own `h`/`l` and Enter.

## License

MIT — see [LICENSE](LICENSE).
