#!/bin/bash
# Install the privileged half of the NextDNS bar widget.
#
#   ./install.sh              install or update it
#   ./install.sh --check      report what is in place, change nothing
#   ./install.sh --uninstall  hand DNS back, then remove what this installed
#
# Run it as your normal user from the plugin folder
# (~/.config/omarchy/plugins/blacksheep.nextdns); it calls sudo where it needs
# to. Re-run it after `omarchy plugin update`, because the root-owned copies in
# /usr/local/bin do not update themselves.
#
# Needs the nextdns CLI first (AUR): yay -S --needed nextdns
#
# What it installs, all root-owned:
#   /usr/local/bin/nextdns-toggle, nextdns-apply           0755
#   /etc/NetworkManager/dispatcher.d/90-nextdns-portal     0755
#   /etc/systemd/system/nextdns-auto.service, .timer       0644, enabled
#   /etc/systemd/system/nextdns.service                    0644, only if absent
#   /etc/sudoers.d/99-nextdns-toggle                       0440, checked by visudo
#   /etc/nextdns.conf                                      0644, only if absent,
#                                                          with the profile id you enter
#   /var/lib/nextdns-toggle/{override,provider}            0644

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

MODE=install
case "${1:-}" in
"") ;;
--check) MODE=check ;;
--uninstall) MODE=uninstall ;;
*)
  echo "usage: install.sh [--check|--uninstall]" >&2
  exit 1
  ;;
esac

if ((EUID == 0)); then
  echo "Run this as your normal user, not root — it calls sudo where it needs to." >&2
  exit 1
fi
# The account name goes into a sudoers rule, so it must be a plain name.
[[ $USER =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "unexpected user name: $USER" >&2; exit 1; }

SCRIPTS=(nextdns-toggle nextdns-apply)
DISPATCH=90-nextdns-portal
SUDOERS=99-nextdns-toggle
UNITS=(nextdns-auto.service nextdns-auto.timer)
VERBS=("nextdns-toggle toggle" "nextdns-toggle on" "nextdns-toggle off" "nextdns-toggle auto"
  "nextdns-toggle provider Cloudflare" "nextdns-toggle provider Google"
  "nextdns-toggle provider DHCP")

ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; }

# `sudo -l` alone only answers "is this permitted", which a blanket wheel rule
# says yes to. The long listing prints the matched entry's tags, so
# !authenticate proves the grant is ours and the widget will not be stopped by
# a password prompt it has no terminal to show.
check_verbs() {
  local verb
  for verb in "${VERBS[@]}"; do
    # shellcheck disable=SC2086
    if sudo -n -l -l /usr/local/bin/$verb 2>/dev/null | grep -q '!authenticate'; then
      ok "sudo -n $verb"
    else
      bad "sudo -n $verb"
    fi
  done
}

# ---------------------------------------------------------------- check mode

if [[ $MODE == check ]]; then
  echo "==> nextdns"
  command -v nextdns >/dev/null && ok "$(nextdns version 2>/dev/null | head -1)" ||
    bad "nextdns CLI not installed (yay -S --needed nextdns)"
  echo "==> Scripts"
  for f in "${SCRIPTS[@]}"; do
    [[ -x /usr/local/bin/$f ]] && ok "/usr/local/bin/$f" || bad "/usr/local/bin/$f missing"
    [[ -x /usr/local/bin/$f ]] && ! cmp -s "system/bin/$f" "/usr/local/bin/$f" &&
      bad "/usr/local/bin/$f differs from this plugin's copy — re-run install.sh"
  done
  echo "==> Dispatcher"
  [[ -x /etc/NetworkManager/dispatcher.d/$DISPATCH ]] && ok "$DISPATCH" || bad "$DISPATCH missing"
  echo "==> Units"
  echo "  nextdns.service:    $(systemctl is-enabled nextdns.service 2>&1)"
  echo "  nextdns-auto.timer: $(systemctl is-enabled nextdns-auto.timer 2>&1)"
  echo "==> Profile"
  if grep -qE '^profile [0-9a-f]+' /etc/nextdns.conf 2>/dev/null; then
    ok "/etc/nextdns.conf has a profile id"
  else
    bad "/etc/nextdns.conf has no profile id"
  fi
  echo "==> Passwordless verbs"
  check_verbs
  exit 0
fi

# ------------------------------------------------------------ uninstall mode

if [[ $MODE == uninstall ]]; then
  # Hand DNS back first. Removing the scripts while the system still points at
  # 127.0.0.1 would leave every lookup going to a daemon nobody manages.
  echo "==> Handing DNS back"
  if [[ -x /usr/local/bin/nextdns-toggle ]]; then
    sudo /usr/local/bin/nextdns-toggle off && ok "switched to the fallback resolver"
  fi
  sudo systemctl disable --now nextdns-auto.timer 2>/dev/null && ok "nextdns-auto.timer stopped" || true
  echo "==> Removing"
  sudo rm -f "/etc/sudoers.d/$SUDOERS" && ok "/etc/sudoers.d/$SUDOERS"
  sudo rm -f "/etc/NetworkManager/dispatcher.d/$DISPATCH" && ok "$DISPATCH"
  for u in "${UNITS[@]}"; do
    sudo rm -f "/etc/systemd/system/$u" && ok "/etc/systemd/system/$u"
  done
  sudo systemctl daemon-reload
  for f in "${SCRIPTS[@]}"; do
    sudo rm -f "/usr/local/bin/$f" && ok "/usr/local/bin/$f"
  done
  sudo rm -rf /var/lib/nextdns-toggle /run/nextdns-toggle && ok "state"
  cat <<'LEFT'

DNS is now on the fallback resolver, set through Omarchy's own omarchy-dns.
Change it any time in Omarchy's settings.

Left in place, because they are yours rather than this plugin's:
  /etc/nextdns.conf                     your profile id
  /etc/systemd/system/nextdns.service   the NextDNS daemon (stopped)
  the nextdns package

Then remove the widget itself:
  omarchy plugin remove blacksheep.nextdns
LEFT
  exit 0
fi

# ------------------------------------------------------------------ packages

# Check the AUR prerequisite before installing anything, so a failed run
# leaves nothing behind.
if ! command -v nextdns >/dev/null; then
  echo "  The nextdns CLI is not installed. It's in the AUR:"
  echo "    yay -S --needed nextdns"
  echo "  Then re-run this script."
  exit 1
fi

echo "==> Packages"
omarchy pkg add python curl 2>/dev/null ||
  sudo pacman -S --needed --noconfirm python curl
ok "nextdns $(nextdns version 2>/dev/null | head -1)"

# ------------------------------------------------------------------- profile

echo "==> Profile"
if grep -qE '^profile [0-9a-f]+' /etc/nextdns.conf 2>/dev/null; then
  ok "/etc/nextdns.conf already has a profile id"
else
  echo "  Your NextDNS profile id is the short code on my.nextdns.io (e.g. abc123)."
  read -rp "  NextDNS profile id (blank to skip): " profile
  if [[ -n $profile ]]; then
    [[ $profile =~ ^[0-9a-f]{6}$ ]] || { echo "  that is not a NextDNS profile id" >&2; exit 1; }
    tmp=$(mktemp)
    sed -E "s/^profile .*/profile $profile/" system/examples/nextdns.conf.example >"$tmp"
    sudo install -o root -g root -m 0644 "$tmp" /etc/nextdns.conf
    rm -f "$tmp"
    ok "/etc/nextdns.conf written"
  else
    echo "  Skipped. Write /etc/nextdns.conf from system/examples/nextdns.conf.example"
    echo "  later; until then NextDNS cannot start and the widget stays on the fallback."
  fi
fi

# ------------------------------------------------------------------- scripts

echo "==> Scripts"
for f in "${SCRIPTS[@]}"; do
  sudo install -o root -g root -m 0755 "system/bin/$f" "/usr/local/bin/$f"
  ok "/usr/local/bin/$f"
done
sudo install -o root -g root -m 0755 "system/dispatcher.d/$DISPATCH" \
  "/etc/NetworkManager/dispatcher.d/$DISPATCH"
ok "/etc/NetworkManager/dispatcher.d/$DISPATCH"

# ------------------------------------------------------------------- sudoers

# Never install a sudoers file that does not parse: a broken drop-in locks sudo
# out entirely, and there is no second chance on a machine with no root shell.
echo "==> Sudoers rule for '$USER'"
tmp=$(mktemp)
sed "s/@USER@/$USER/g" "system/sudoers.d/$SUDOERS" >"$tmp"
sudo install -o root -g root -m 0440 "$tmp" "/etc/sudoers.d/.$SUDOERS.new"
rm -f "$tmp"
if sudo visudo -c -f "/etc/sudoers.d/.$SUDOERS.new" >/dev/null; then
  sudo mv "/etc/sudoers.d/.$SUDOERS.new" "/etc/sudoers.d/$SUDOERS"
  ok "/etc/sudoers.d/$SUDOERS"
else
  sudo rm -f "/etc/sudoers.d/.$SUDOERS.new"
  echo "sudoers rule failed validation; nothing installed" >&2
  exit 1
fi

# --------------------------------------------------------------------- state

echo "==> State"
# World-readable: the bar runs unprivileged and reads these to draw the widget.
sudo install -d -o root -g root -m 0755 /var/lib/nextdns-toggle
[[ -f /var/lib/nextdns-toggle/override ]] ||
  echo auto | sudo tee /var/lib/nextdns-toggle/override >/dev/null
[[ -f /var/lib/nextdns-toggle/provider ]] ||
  echo Cloudflare | sudo tee /var/lib/nextdns-toggle/provider >/dev/null
sudo chmod 0644 /var/lib/nextdns-toggle/{override,provider}
ok "override $(cat /var/lib/nextdns-toggle/override), fallback $(cat /var/lib/nextdns-toggle/provider)"

# --------------------------------------------------------------------- units

echo "==> Units"
# nextdns.service is the unit `nextdns install` generates. Install ours only
# when there is none, so an existing setup keeps its own.
if [[ -e /etc/systemd/system/nextdns.service ]]; then
  ok "nextdns.service already present; left as it is"
else
  sudo install -o root -g root -m 0644 system/systemd/nextdns.service /etc/systemd/system/
  ok "nextdns.service installed"
fi
for u in "${UNITS[@]}"; do
  sudo install -o root -g root -m 0644 "system/systemd/$u" /etc/systemd/system/
done
sudo systemctl daemon-reload
sudo systemctl enable --now nextdns.service nextdns-auto.timer
ok "nextdns.service    $(systemctl is-active nextdns.service)"
ok "nextdns-auto.timer $(systemctl is-active nextdns-auto.timer)"

# ------------------------------------------------------------------ checking

echo
echo "==> Checking"
check_verbs
echo
echo "  nextdns-stats: $(scripts/nextdns-stats)"
cat <<'NEXT'

If any verb above says FAIL, look at what else is in /etc/sudoers.d: sudo
applies the LAST matching rule, so a file that sorts after 99-nextdns-toggle
and grants the same commands with a password wins over this one.

Never use Omarchy's DNS provider picker while this is installed: it rewrites
the resolver settings wholesale and drops NextDNS. The widget's own Off and
fallback choices go through the same omarchy-dns command safely.

If the widget is not on the bar yet:
  omarchy plugin enable blacksheep.nextdns
NEXT
