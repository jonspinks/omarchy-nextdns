# NextDNS — an Omarchy bar widget

Whether NextDNS is the system resolver, which resolver replaces it when it is
off, and an automatic fallback for networks that block it.

## Requires a privileged half

This widget is only the UI. It reads
`~/.config/omarchy/bar/scripts/nextdns-stats` and calls
`/usr/local/bin/nextdns-toggle`, neither of which ships here — install
[`omarchy-netconfig`](https://github.com/jonspinks/omarchy-netconfig) **first**.

## Install

```bash
# 1. the privileged half
git clone https://github.com/jonspinks/omarchy-netconfig ~/Projects/omarchy-netconfig
~/Projects/omarchy-netconfig/install.sh

# 2. this widget
omarchy plugin add https://github.com/jonspinks/omarchy-nextdns --enable
```

Update later with `omarchy plugin update blacksheep.nextdns`.

## Design notes

- "Active" is read from the file `omarchy-dns` writes
  (`/etc/NetworkManager/conf.d/20-omarchy-dns.conf`), not from our own override.
  The first click after an automatic change has to go the way the user sees, not
  the way we last asked.
- The failure worth catching is a daemon that stays `active` and bound to
  `127.0.0.1:53` while answering nothing, which `systemctl is-active` cannot
  see. The stats script sends one real DNS query to decide.
- The "When off" row is a `Ui/ButtonGroup` with `focusable: false`, so it does
  not swallow the panel's own `h`/`l` and Enter.
