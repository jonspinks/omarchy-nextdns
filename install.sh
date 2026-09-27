#!/bin/bash
# Install the privileged half of the NextDNS bar widget.
#
#   ./install.sh              install or update it
#   ./install.sh --check      report what is in place, change nothing
#   ./install.sh --uninstall  hand DNS back, then remove what this installed, and nothing else
#
# Run it as your normal user from the plugin folder
# (~/.config/omarchy/plugins/blacksheep.nextdns); it calls sudo where it needs
# to. Re-run it after `omarchy plugin update`, because the root-owned copies do
# not update themselves.
#
# Needs the nextdns CLI first (AUR): yay -S --needed nextdns
#
# Everything it installs is under a name that belongs to this plugin:
#   /usr/local/libexec/blacksheep.nextdns/nextdns-toggle, nextdns-apply   0755
#   /etc/NetworkManager/dispatcher.d/90-blacksheep-nextdns                0755
#   /etc/systemd/system/blacksheep-nextdns-auto.service, .timer          0644, timer enabled
#   /etc/sudoers.d/99-blacksheep-nextdns                                 0440, checked by visudo
#   /var/lib/blacksheep.nextdns/     0755: override, provider, and the ownership record
# and, only when there is none already:
#   /etc/systemd/system/nextdns.service   the NextDNS daemon's unit, enabled
#   /etc/nextdns.conf                     with the profile id you enter; yours, never removed
#
# OWNERSHIP. The installer records a SHA-256 of every file it installs in
# /var/lib/blacksheep.nextdns/installed. It replaces a file only if the file is
# absent, is its own recorded copy unchanged, or is already byte-identical to
# what it would install; anything else stops the install before it changes a
# thing. --uninstall removes only files that still match their record, and
# leaves anything changed since in place. It never guesses from a file name.
# An existing nextdns.service or /etc/nextdns.conf is never recorded, so it is
# never replaced or removed.

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

NS=blacksheep.nextdns
LIBEXEC=/usr/local/libexec/$NS
VAR=/var/lib/$NS
RUN=/run/$NS
RECORD=$VAR/installed
UNITDIR=/etc/systemd/system
DISPATCH=/etc/NetworkManager/dispatcher.d/90-blacksheep-nextdns
SUDOERS=/etc/sudoers.d/99-blacksheep-nextdns
DAEMON_UNIT=$UNITDIR/nextdns.service
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
    if sudo -n -l -l $LIBEXEC/$verb 2>/dev/null | grep -q '!authenticate'; then
      ok "sudo -n $verb"
    else
      bad "sudo -n $verb"
    fi
  done
}

# ---------------------------------------------------------- ownership record

# One "sha256  path" line per installed file. The record is root-owned and
# world-readable; only root can change it.
declare -A OWNED=()
load_record() {
  local sum path
  [[ -r $RECORD ]] || return 0
  while read -r sum path; do
    [[ -n $path ]] && OWNED[$path]=$sum
  done <"$RECORD"
}
# Most targets are world-readable; the sudoers drop-in is 0440, so it takes sudo.
sum_of() {
  { sha256sum "$1" 2>/dev/null || sudo sha256sum "$1" 2>/dev/null; } | cut -d' ' -f1
}
# `test -e` follows symlinks, so a dangling link would read as absent. Every
# check here asks about the path itself: a symlink is never ours, whatever it
# points at, and is never followed, replaced or removed.
is_link() { sudo test -L "$1"; }
present() { sudo test -e "$1" || sudo test -L "$1"; }

# This plugin's own directories must be real, root-owned directories, and the
# files it writes only when absent (or rewrites in place) must not be links.
DIRS=("$LIBEXEC" "$VAR" "$RUN")
NOLINK=("$RECORD" "$VAR/override" "$VAR/provider" /etc/nextdns.conf "$DAEMON_UNIT")
ours() { [[ -n ${OWNED[$1]:-} && $(sum_of "$1") == "${OWNED[$1]}" ]]; }

# The files this install would place: "source|target|mode". The sudoers source
# is generated for this account, so it is staged in a temporary file first.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
sed "s/@USER@/$USER/g" system/sudoers.d/99-blacksheep-nextdns >"$STAGE/sudoers"
PLAN=(
  "system/bin/nextdns-toggle|$LIBEXEC/nextdns-toggle|0755"
  "system/bin/nextdns-apply|$LIBEXEC/nextdns-apply|0755"
  "system/dispatcher.d/90-blacksheep-nextdns|$DISPATCH|0755"
  "system/systemd/blacksheep-nextdns-auto.service|$UNITDIR/blacksheep-nextdns-auto.service|0644"
  "system/systemd/blacksheep-nextdns-auto.timer|$UNITDIR/blacksheep-nextdns-auto.timer|0644"
  "$STAGE/sudoers|$SUDOERS|0440"
)

# Stop before changing anything if a target is somebody else's.
preflight() {
  local entry src target mode have d f conflicts=0
  for d in "${DIRS[@]}"; do
    if is_link "$d"; then
      echo "  STOP $d is a symbolic link"; conflicts=1
    elif sudo test -e "$d" && [[ $(sudo stat -c '%F %U' "$d") != "directory root" ]]; then
      echo "  STOP $d exists and is not a root-owned directory"; conflicts=1
    fi
  done
  for f in "${NOLINK[@]}"; do
    if is_link "$f"; then
      echo "  STOP $f is a symbolic link"; conflicts=1
    elif sudo test -d "$f"; then
      echo "  STOP $f is a directory"; conflicts=1
    fi
  done
  for entry in "${PLAN[@]}"; do
    IFS='|' read -r src target mode <<<"$entry"
    if is_link "$target"; then
      echo "  STOP $target is a symbolic link"; conflicts=1; continue
    fi
    present "$target" || continue
    if sudo test -d "$target"; then
      echo "  STOP $target is a directory"; conflicts=1; continue
    fi
    have=$(sum_of "$target")
    [[ $have == "$(sha256sum "$src" | cut -d' ' -f1)" ]] && continue
    [[ -n ${OWNED[$target]:-} && $have == "${OWNED[$target]}" ]] && continue
    echo "  STOP $target exists and was not installed by this plugin (or has changed since)"
    conflicts=1
  done
  if ((conflicts)); then
    echo
    echo "Nothing was changed. Move the files above aside yourself if they are safe" >&2
    echo "to replace, then run install.sh again." >&2
    exit 1
  fi
}

write_record() {
  local path
  for path in "${!OWNED[@]}"; do
    printf '%s  %s\n' "${OWNED[$path]}" "$path"
  done | sort -k2 >"$STAGE/record"
  sudo install -o root -g root -m 0644 "$STAGE/record" "$RECORD"
}

place() { # source target mode
  local src=$1 target=$2 mode=$3 tmp
  # Into place through a dot-named temporary in the same directory: sudo skips
  # dot files in sudoers.d, and the rename is atomic for every other reader.
  tmp=$(sudo mktemp -p "$(dirname "$target")" ".$(basename "$target").XXXXXX")
  sudo install -o root -g root -m "$mode" "$src" "$tmp"
  if [[ $target == "$SUDOERS" ]] && ! sudo visudo -c -f "$tmp" >/dev/null; then
    sudo rm -f "$tmp"
    echo "sudoers rule failed validation in place; not installed" >&2
    exit 1
  fi
  sudo mv -f -T "$tmp" "$target"
  OWNED[$target]=$(sha256sum "$src" | cut -d' ' -f1)
  write_record
  ok "$target"
}

# ---------------------------------------------------------------- check mode

if [[ $MODE == check ]]; then
  load_record
  echo "==> nextdns"
  command -v nextdns >/dev/null && ok "$(nextdns version 2>/dev/null | head -1)" ||
    bad "nextdns CLI not installed (yay -S --needed nextdns)"
  echo "==> Installed files"
  ((${#OWNED[@]})) || bad "no ownership record at $RECORD — not installed"
  for entry in "${PLAN[@]}"; do
    IFS='|' read -r src target mode <<<"$entry"
    # /etc/sudoers.d can't be read without a password; the verbs below prove
    # the rule is in place instead.
    if [[ $target == "$SUDOERS" ]]; then
      echo "  --   $target (checked through the passwordless verbs below)"
    elif [[ -L $target ]]; then
      bad "$target is a symbolic link, not this plugin's file"
    elif [[ ! -e $target ]]; then
      bad "$target missing"
    elif [[ $(sum_of "$target") != "$(sha256sum "$src" | cut -d' ' -f1)" ]]; then
      bad "$target differs from this plugin's copy — re-run install.sh"
    else
      ok "$target"
    fi
  done
  echo "==> Units"
  echo "  nextdns.service:                $(systemctl is-enabled nextdns.service 2>&1)$([[ -n ${OWNED[$DAEMON_UNIT]:-} ]] && echo ' (installed by this plugin)')"
  echo "  blacksheep-nextdns-auto.timer:  $(systemctl is-enabled blacksheep-nextdns-auto.timer 2>&1)"
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
  load_record
  if ((${#OWNED[@]} == 0)); then
    echo "No ownership record at $RECORD, so there is nothing this script knows it"
    echo "installed. Nothing was removed."
    exit 0
  fi
  # Hand DNS back first. Removing the scripts while the system still points at
  # 127.0.0.1 would leave every lookup going to a daemon nobody manages.
  echo "==> Handing DNS back"
  if ours "$LIBEXEC/nextdns-toggle"; then
    sudo "$LIBEXEC/nextdns-toggle" off && ok "switched to the fallback resolver"
  fi
  if ours "$UNITDIR/blacksheep-nextdns-auto.timer"; then
    sudo systemctl disable --now blacksheep-nextdns-auto.timer 2>/dev/null && ok "policy timer stopped"
  fi
  if ours "$DAEMON_UNIT"; then
    sudo systemctl disable --now nextdns.service 2>/dev/null && ok "nextdns.service stopped"
  fi
  echo "==> Removing what this plugin installed"
  # The sudoers rule goes first, so the grant never outlives the scripts it names.
  for path in "$SUDOERS" $(printf '%s\n' "${!OWNED[@]}" | grep -vxF "$SUDOERS" | sort); do
    [[ -n ${OWNED[$path]:-} ]] || continue
    if is_link "$path"; then
      echo "  KEEP $path is a symbolic link, not what this plugin installed; left in place"
    elif ! present "$path"; then
      ok "$path (already gone)"
    elif [[ $(sum_of "$path") == "${OWNED[$path]}" ]]; then
      sudo rm -f "$path" && ok "removed $path"
    else
      echo "  KEEP $path has changed since install; left in place"
    fi
  done
  sudo systemctl daemon-reload
  sudo rmdir "$LIBEXEC" 2>/dev/null || true
  # State: only the files this plugin writes, inside its own directories.
  sudo rm -f "$VAR/override" "$VAR/provider" "$RECORD" "$RUN/last-result" "$RUN/lock"
  sudo rmdir "$VAR" "$RUN" 2>/dev/null || true
  cat <<'LEFT'

DNS is now on the fallback resolver, set through Omarchy's own omarchy-dns.
Change it any time in Omarchy's settings.

Left in place, because they are yours rather than this plugin's:
  /etc/nextdns.conf     your profile id
  the nextdns package, and any nextdns.service you had before installing

Then remove the widget itself:
  omarchy plugin remove blacksheep.nextdns
LEFT
  exit 0
fi

# -------------------------------------------------------------- install mode

# Check the AUR prerequisite before installing anything, so a failed run
# leaves nothing behind.
if ! command -v nextdns >/dev/null; then
  echo "  The nextdns CLI is not installed. It's in the AUR:"
  echo "    yay -S --needed nextdns"
  echo "  Then re-run this script."
  exit 1
fi

load_record
echo "==> Checking for files this plugin doesn't own"
preflight
ok "no conflicts"

echo "==> Packages"
omarchy pkg add python curl 2>/dev/null ||
  sudo pacman -S --needed --noconfirm python curl
ok "nextdns $(nextdns version 2>/dev/null | head -1)"

# Your data: written only when absent, never recorded, never removed.
echo "==> Profile"
if grep -qE '^profile [0-9a-f]+' /etc/nextdns.conf 2>/dev/null; then
  ok "/etc/nextdns.conf already has a profile id"
elif [[ -e /etc/nextdns.conf ]]; then
  echo "  /etc/nextdns.conf exists but has no profile id. It is yours, so it is left"
  echo "  alone: add a 'profile <id>' line to it (sudoedit /etc/nextdns.conf)."
else
  echo "  Your NextDNS profile id is the short code on my.nextdns.io (e.g. abc123)."
  read -rp "  NextDNS profile id (blank to skip): " profile
  if [[ -n $profile ]]; then
    [[ $profile =~ ^[0-9a-f]{6}$ ]] || { echo "  that is not a NextDNS profile id" >&2; exit 1; }
    sed -E "s/^profile .*/profile $profile/" system/examples/nextdns.conf.example >"$STAGE/nextdns.conf"
    sudo install -o root -g root -m 0644 "$STAGE/nextdns.conf" /etc/nextdns.conf
    ok "/etc/nextdns.conf written"
  else
    echo "  Skipped. Write /etc/nextdns.conf from system/examples/nextdns.conf.example"
    echo "  later; until then NextDNS cannot start and the widget stays on the fallback."
  fi
fi

echo "==> Installing"
sudo install -d -o root -g root -m 0755 "$LIBEXEC" "$VAR"
for entry in "${PLAN[@]}"; do
  IFS='|' read -r src target mode <<<"$entry"
  place "$src" "$target" "$mode"
done

# nextdns.service is the unit `nextdns install` generates. Install ours only
# when there is none; an existing one is used exactly as it is, never enabled,
# replaced or removed by this script. nextdns-apply starts it when it is needed.
own_daemon=0
if [[ -n ${OWNED[$DAEMON_UNIT]:-} ]] && ours "$DAEMON_UNIT"; then
  own_daemon=1
elif [[ ! -e $DAEMON_UNIT ]]; then
  place system/systemd/nextdns.service "$DAEMON_UNIT" 0644
  own_daemon=1
else
  ok "nextdns.service is yours; used as it is"
fi
echo "  note this widget starts, stops and restarts nextdns.service to switch NextDNS"
echo "       on and off and to repair a wedged daemon; that is what it is for."

echo "==> State"
# World-readable: the bar runs unprivileged and reads these to draw the widget.
sudo test -f "$VAR/override" || echo auto | sudo tee "$VAR/override" >/dev/null
sudo test -f "$VAR/provider" || echo Cloudflare | sudo tee "$VAR/provider" >/dev/null
sudo chmod 0644 "$VAR/override" "$VAR/provider"
ok "override $(cat "$VAR/override"), fallback $(cat "$VAR/provider")"

echo "==> Units"
sudo systemctl daemon-reload
((own_daemon)) && sudo systemctl enable --now nextdns.service
sudo systemctl enable --now blacksheep-nextdns-auto.timer
ok "nextdns.service               $(systemctl is-active nextdns.service)"
ok "blacksheep-nextdns-auto.timer $(systemctl is-active blacksheep-nextdns-auto.timer)"

echo
echo "==> Checking"
check_verbs
echo
echo "  nextdns-stats: $(scripts/nextdns-stats)"
cat <<'NEXT'

If any verb above says FAIL, look at what else is in /etc/sudoers.d: sudo
applies the LAST matching rule, so a file that sorts after
99-blacksheep-nextdns and grants the same commands with a password wins.

Never use Omarchy's DNS provider picker while this is installed: it rewrites
the resolver settings wholesale and drops NextDNS. The widget's own Off and
fallback choices go through the same omarchy-dns command safely.

If the widget is not on the bar yet:
  omarchy plugin enable blacksheep.nextdns
NEXT
