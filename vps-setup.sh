#!/usr/bin/env bash
# =============================================================================
#  vps-setup.sh — hardened Debian 13 VPS for container apps, one user only
#
#  `sudo bash vps-setup.sh init --config vps.conf` turns a fresh Debian 13
#  (trixie) server into:
#
#    • One user      your login: SSH key only, sudo, and owner of every
#                    container — no switching between accounts
#    • Containers    rootless Podman + Quadlet (systemd); no daemon, no root
#    • Proxy         Traefik v3, automatic HTTPS (Let's Encrypt) and HTTP/3;
#                    new apps are picked up from their container labels
#    • Deploys       git push → GitHub Actions builds → GHCR → the server turns
#                    the repo's compose.yaml into Quadlet units with Podlet,
#                    starts them, waits until healthy, rolls back on failure
#    • Hardening     nftables firewall, fail2ban, automatic security updates,
#                    kernel/network sysctls, modern SSH crypto
#    • Efficiency    zram swap, BBR, capped logs, per-container limits,
#                    only changed services are restarted on deploy
#
#  Re-running init is safe (idempotent). Afterwards the script is installed as
#  `vps`; run `vps help` as your user (no sudo needed for app commands).
# =============================================================================

# Backticks inside single quotes are literal on purpose (Traefik rules, docs).
# shellcheck disable=SC2016

set -Eeuo pipefail
shopt -s inherit_errexit nullglob
umask 022

readonly VPS_VERSION="1.2.3"
readonly INSTALL_PATH="/usr/local/bin/vps"
readonly CONFIG_DIR="/etc/vps"
readonly CONFIG_PATH="$CONFIG_DIR/vps.conf"
readonly QUADLET_BIN="/usr/libexec/podman/quadlet"
readonly RESERVED_NAMES=" traefik web podman vps "

# Podlet release, pinned by checksum (supply-chain safety). Bump both together.
readonly PODLET_VERSION="0.3.2"
declare -rA PODLET_SHA256=(
  [x86_64-unknown-linux-gnu]="d28975df717ce20374a6dc4176670ce6faf8dcb3ab4af761a39fdd2f863d03f6"
  [aarch64-unknown-linux-gnu]="ff9f25b72c4871b0507fe1e6f31c8ef6836dcaf5151bb0d424f81a79832ce2e1"
)

readonly -a CONFIG_KEYS=(
  USER_NAME SSH_PUBLIC_KEY GITHUB_KEYS_USER SUDO_NOPASSWD SSH_PORT
  SERVER_HOSTNAME TIMEZONE AUTO_REBOOT AUTO_REBOOT_TIME ZRAM_PERCENT
  ACME_EMAIL ACME_STAGING TRAEFIK_IMAGE ACCESS_LOG TRUSTED_PROXY_IPS
  RATE_LIMIT_AVERAGE RATE_LIMIT_BURST
  GITHUB_OWNER ALLOWED_IMAGES DEFAULT_MEMORY DEFAULT_CPUS DEFAULT_PIDS
  KEEP_RELEASES SETTLE_SECONDS
)

ASSUME_YES=no
WRITE_CHANGED=0
HOOK_AUTHFILE=""
HOOK_COMPOSE=""
HOOK_CI_IMAGE=""
GHCR_PREFIX=""
IMAGE_ALLOWLIST=""
declare -a ADMIN_KEYS=()

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------
if [[ -t 2 ]]; then
  C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m' C_RESET=$'\e[0m'
else
  C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_RESET=""
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET" >&2; }
info() { printf '    %s\n' "$*" >&2; }
ok() { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() {
  printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

on_error() {
  local code=$? line=$1 cmd=$2
  ((BASH_SUBSHELL == 0)) || return 0
  printf '%serror:%s line %s: `%s` exited with %s\n' "$C_RED" "$C_RESET" "$line" "$cmd" "$code" >&2
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
is_yes() { [[ ${1,,} =~ ^(1|y|yes|true|on)$ ]]; }

need_value() {
  if [[ $# -lt 2 || -z ${2-} ]]; then die "$1 requires a value"; fi
}

confirm() {
  local answer
  if is_yes "$ASSUME_YES"; then return 0; fi
  if [[ ! -t 0 ]]; then die "no terminal to confirm '$1' — re-run with --yes"; fi
  read -r -p "$1 [y/N] " answer
  [[ ${answer,,} == y* ]]
}

valid_port() { [[ ${1-} =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_username() { [[ ${1-} =~ ^[a-z_][a-z0-9_-]{0,31}$ && $1 != root ]]; }
valid_app_name() { [[ ${1-} =~ ^[a-z][a-z0-9-]{0,30}[a-z0-9]$ && $RESERVED_NAMES != *" $1 "* ]]; }

# Fully qualified image reference: registry/path[:tag][@sha256:digest]
valid_image_ref() {
  local re='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?/[a-z0-9]+([._/-][a-z0-9]+)*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?(@sha256:[a-f0-9]{64})?$'
  local registry=${1%%/*}
  [[ ${1-} =~ $re ]] && [[ $registry == *.* || $registry == *:* || $registry == localhost ]]
}

# write_file PATH MODE [OWNER] — content from stdin, replaced atomically.
# Sets WRITE_CHANGED=1 when the content differs from what was there.
write_file() {
  local path=$1 mode=$2 owner=${3:-$(id -un)} dir tmp group
  dir=${path%/*}
  group=$(id -gn "$owner")
  if [[ ! -d $dir ]]; then
    if [[ $EUID -eq 0 ]]; then install -d -m 0755 -o "$owner" -g "$group" "$dir"; else install -d -m 0755 "$dir"; fi
  fi
  tmp=$(mktemp "$dir/.vps.XXXXXX")
  cat >"$tmp"
  chmod "$mode" "$tmp"
  if [[ $EUID -eq 0 ]]; then chown "$owner:$group" "$tmp"; fi
  if [[ -f $path ]] && cmp -s "$tmp" "$path"; then WRITE_CHANGED=0; else WRITE_CHANGED=1; fi
  mv -f "$tmp" "$path"
}

os_release() {
  # shellcheck source=/dev/null
  (. /etc/os-release && printf '%s' "${!1:-}")
}

# true when $1 is an IPv4 address the internet can route to
is_public_ipv4() {
  local a b c d
  [[ ${1-} =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
  c=$((10#${BASH_REMATCH[3]})) d=$((10#${BASH_REMATCH[4]}))
  ((a <= 255 && b <= 255 && c <= 255 && d <= 255)) || return 1
  ((a == 0 || a == 10 || a == 127 || a >= 224)) && return 1
  ((a == 100 && b >= 64 && b <= 127)) && return 1 # CGNAT, Tailscale
  ((a == 169 && b == 254)) && return 1            # link-local
  ((a == 172 && b >= 16 && b <= 31)) && return 1
  ((a == 192 && b == 168)) && return 1
  return 0
}

# The address the internet reaches this server on. Behind 1:1 NAT (common at cloud
# providers) the interface only has a private address, so ask Cloudflare instead.
public_ip() {
  local addr ext
  addr=$({ ip -4 route get 1.1.1.1 2>/dev/null || true; } | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')
  if [[ -z $addr ]]; then addr=$({ hostname -I 2>/dev/null || true; } | awk '{print $1}'); fi
  if ! is_public_ipv4 "$addr"; then
    ext=$({ curl -4 -fsS --proto '=https' --max-time 5 https://1.1.1.1/cdn-cgi/trace 2>/dev/null || true; } | sed -n 's/^ip=//p')
    if is_public_ipv4 "$ext"; then addr=$ext; fi
  fi
  printf '%s' "${addr:-<server-ip>}"
}

# -----------------------------------------------------------------------------
# Configuration
#
#   environment variables  >  --config FILE  >  /etc/vps/vps.conf  >  defaults
#
# Files are parsed as KEY="value" lines — never sourced or executed.
# -----------------------------------------------------------------------------
load_config_file() {
  local file=$1 line key val
  local -n _skip=$2
  # KEY="value" | KEY='value' | KEY=value — each optionally followed by "# comment"
  local re_dq='^"([^"]*)"[[:space:]]*(#.*)?$'
  local re_sq="^'([^']*)'[[:space:]]*(#.*)?\$"
  local re_bare=$'^([^#[:space:]"\']([^#"\']*[^#[:space:]"\'])?)?[[:space:]]*(#.*)?$'
  [[ -f $file ]] || return 0
  [[ -r $file ]] || die "cannot read config: $file"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[2]}
    val=${val#"${val%%[![:space:]]*}"}
    val=${val%"${val##*[![:space:]]}"}
    if [[ $val =~ $re_dq || $val =~ $re_sq || $val =~ $re_bare ]]; then
      val=${BASH_REMATCH[1]}
    else
      warn "$file: cannot parse the value of $key (put it in double quotes)"
      continue
    fi
    if [[ " ${CONFIG_KEYS[*]} " != *" $key "* ]]; then
      warn "$file: unknown key $key (ignored)"
      continue
    fi
    [[ -z ${_skip[$key]:-} ]] || continue
    printf -v "$key" '%s' "$val"
  done <"$file"
}

resolve_config() {
  local file=${1:-} key
  local -A from_env=() # read through a nameref in load_config_file
  for key in "${CONFIG_KEYS[@]}"; do
    # shellcheck disable=SC2034
    if [[ -v $key ]]; then from_env[$key]=1; fi
  done
  load_config_file "$CONFIG_PATH" from_env
  if [[ -n $file ]]; then
    [[ -f $file ]] || die "config file not found: $file"
    load_config_file "$file" from_env
  fi

  : "${USER_NAME:=}" "${SSH_PUBLIC_KEY:=}" "${GITHUB_KEYS_USER:=}" "${SUDO_NOPASSWD:=no}" "${SSH_PORT:=22}"
  : "${SERVER_HOSTNAME:=}" "${TIMEZONE:=UTC}" "${AUTO_REBOOT:=yes}" "${AUTO_REBOOT_TIME:=04:00}" "${ZRAM_PERCENT:=50}"
  : "${ACME_EMAIL:=}" "${ACME_STAGING:=no}" "${TRAEFIK_IMAGE:=docker.io/library/traefik:v3.7}" "${ACCESS_LOG:=no}"
  : "${TRUSTED_PROXY_IPS:=}" "${RATE_LIMIT_AVERAGE:=100}" "${RATE_LIMIT_BURST:=200}"
  : "${GITHUB_OWNER:=}" "${ALLOWED_IMAGES:=}" "${DEFAULT_MEMORY:=512m}" "${DEFAULT_CPUS:=1}" "${DEFAULT_PIDS:=512}"
  : "${KEEP_RELEASES:=5}" "${SETTLE_SECONDS:=5}"

  GHCR_PREFIX=""
  if [[ -n $GITHUB_OWNER ]]; then GHCR_PREFIX="ghcr.io/${GITHUB_OWNER,,}/"; fi
  # Images a compose file deployed from CI may use: your GHCR images + Docker official images
  IMAGE_ALLOWLIST=${ALLOWED_IMAGES:-${GHCR_PREFIX:+$GHCR_PREFIX }docker.io/library/}
  IMAGE_ALLOWLIST=${IMAGE_ALLOWLIST//,/ }
}

render_config() {
  local key
  printf '# Managed by vps-setup.sh %s — edit, then re-run: sudo vps init\n' "$VPS_VERSION"
  for key in "${CONFIG_KEYS[@]}"; do printf '%s="%s"\n' "$key" "${!key}"; done
}

validate_config() {
  local prefix
  valid_username "$USER_NAME" || die "USER_NAME must be a valid Linux username other than root (e.g. USER_NAME=\"rep\")"
  valid_port "$SSH_PORT" || die "invalid SSH_PORT: $SSH_PORT"
  ((SSH_PORT != 80 && SSH_PORT != 443)) || die "SSH_PORT cannot be 80 or 443 (used for HTTP/HTTPS)"
  [[ $ACME_EMAIL =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "ACME_EMAIL is required (your e-mail, for Let's Encrypt)"
  [[ ${ACME_EMAIL,,} != *change-me* && ${ACME_EMAIL,,} != *@example.com ]] || die "set ACME_EMAIL to your real e-mail address"
  [[ $GITHUB_OWNER =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]] || die "GITHUB_OWNER is required: your GitHub user or organization (images come from ghcr.io/<owner>/)"
  [[ -e /usr/share/zoneinfo/$TIMEZONE ]] || die "unknown TIMEZONE: $TIMEZONE"
  [[ $AUTO_REBOOT_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "AUTO_REBOOT_TIME must be HH:MM"
  [[ $ZRAM_PERCENT =~ ^([0-9]|[1-9][0-9]|100)$ ]] || die "ZRAM_PERCENT must be 0-100"
  [[ -z $SERVER_HOSTNAME || $SERVER_HOSTNAME =~ ^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$ ]] || die "invalid SERVER_HOSTNAME"
  [[ $DEFAULT_MEMORY =~ ^[0-9]+[kmgKMG]?$ ]] || die "invalid DEFAULT_MEMORY"
  [[ $DEFAULT_CPUS =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "invalid DEFAULT_CPUS"
  [[ $DEFAULT_PIDS =~ ^[0-9]+$ ]] || die "invalid DEFAULT_PIDS"
  [[ $RATE_LIMIT_AVERAGE =~ ^[0-9]+$ && $RATE_LIMIT_BURST =~ ^[0-9]+$ ]] || die "RATE_LIMIT_* must be integers"
  [[ $KEEP_RELEASES =~ ^[1-9][0-9]*$ && $SETTLE_SECONDS =~ ^[0-9]+$ ]] || die "KEEP_RELEASES / SETTLE_SECONDS must be integers"
  [[ $TRAEFIK_IMAGE == *.*/* ]] || die "TRAEFIK_IMAGE must be fully qualified (registry/name:tag)"
  for prefix in $IMAGE_ALLOWLIST; do
    [[ $prefix == *.*/* && $prefix == */ ]] || die "ALLOWED_IMAGES entries must look like registry/path/ (got: $prefix)"
  done
}

# -----------------------------------------------------------------------------
# The user: SSH login, sudo, and owner of all (rootless) containers
# -----------------------------------------------------------------------------
load_user_ctx() {
  id "$USER_NAME" &>/dev/null || die "user '$USER_NAME' does not exist — run: sudo vps init"
  USER_UID=$(id -u "$USER_NAME")
  USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
  QUADLET_DIR="$USER_HOME/.config/containers/systemd"
  USER_UNIT_DIR="$USER_HOME/.config/systemd/user"
  TRAEFIK_DIR="$USER_HOME/.config/traefik"
  APPS_DIR="$USER_HOME/apps"
}

# init (root) → run a command as the user, with its systemd user bus
as_user() {
  (
    cd "$USER_HOME"
    exec runuser -u "$USER_NAME" -- env -i \
      HOME="$USER_HOME" USER="$USER_NAME" LOGNAME="$USER_NAME" SHELL=/bin/bash \
      PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
      XDG_RUNTIME_DIR="/run/user/$USER_UID" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
      "$@"
  )
}

user_systemctl() { as_user systemctl --user "$@"; }

# App commands run as the user (rootless Podman) — never as root.
enter_user_mode() {
  resolve_config ""
  [[ -n $USER_NAME ]] || die "this server isn't set up yet — run: sudo bash vps-setup.sh init --config vps.conf"
  if [[ $EUID -eq 0 ]]; then die "app commands run as $USER_NAME, without sudo (e.g. vps status)"; fi
  [[ $(id -un) == "$USER_NAME" ]] || die "log in as $USER_NAME to manage apps"
  load_user_ctx
  export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$USER_UID}
  export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
  [[ -d $XDG_RUNTIME_DIR ]] || die "$XDG_RUNTIME_DIR is missing — is lingering enabled? run: sudo vps init"
}

# Run the Quadlet generator in dry-run mode; prints its complaints on failure.
validate_quadlets() {
  local out
  if ! out=$(as_user "$QUADLET_BIN" -dryrun -user 2>&1 >/dev/null); then
    printf '%s\n' "$out" | grep -v 'Loading source unit file' >&2 || true
    return 1
  fi
}

unit_image() { sed -n 's/^Image=//p' "$1" 2>/dev/null | head -n 1; }

unit_state() {
  systemctl --user show "$1.service" -p ActiveState -p SubState --value 2>/dev/null | paste -sd' ' || true
}

# =============================================================================
#  init — provision the server (root)
# =============================================================================

# --- preflight ----------------------------------------------------------------
preflight() {
  local os_id os_ver
  [[ $EUID -eq 0 ]] || die "init needs root: sudo bash vps-setup.sh init --config vps.conf"
  os_id=$(os_release ID)
  os_ver=$(os_release VERSION_ID)
  [[ $os_id == debian ]] || die "this script targets Debian (found: ${os_id:-unknown})"
  if [[ -z $os_ver ]]; then
    warn "Debian testing/unstable detected — continuing"
  elif ((${os_ver%%.*} < 13)); then
    die "Debian 13 (trixie) or newer is required, found $os_ver"
  fi
  case $(uname -m) in
    x86_64 | aarch64) ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
  [[ -d /run/systemd/system ]] || die "systemd is required"
  [[ -f /sys/fs/cgroup/cgroup.controllers ]] || die "cgroup v2 is required"
  ok "Debian ${os_ver:-testing} on $(uname -m)"
}

# Validate public keys read from stdin; print the good ones, one per line.
validate_keys() {
  local line key out bits fp type tmp comment
  local key_re='(sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa)[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]][^"]*)?$'
  local -A seen=()
  tmp=$(mktemp)
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ $line =~ $key_re ]] || continue
    key=${BASH_REMATCH[0]} # drops authorized_keys options such as command="..."
    printf '%s\n' "$key" >"$tmp"
    if ! out=$(ssh-keygen -lf "$tmp" 2>/dev/null); then
      warn "skipping invalid key: ${key:0:40}…"
      continue
    fi
    read -r bits fp _ <<<"$out"
    type=${out##*(}
    type=${type%)}
    if [[ $type == RSA ]] && ((bits < 2048)); then
      warn "skipping weak RSA-$bits key $fp"
      continue
    fi
    [[ -z ${seen[$fp]:-} ]] || continue
    seen[$fp]=1
    printf '%s\n' "$key"
    comment=""
    if [[ $key =~ ^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+(.+)$ ]]; then comment=" (${BASH_REMATCH[1]})"; fi
    ok "SSH key: $type $fp$comment"
  done
  rm -f "$tmp"
}

collect_admin_keys() {
  local raw="" out f home
  if [[ -n $SSH_PUBLIC_KEY ]]; then raw+=$SSH_PUBLIC_KEY$'\n'; fi
  if [[ -n $GITHUB_KEYS_USER ]]; then
    out=$(curl -fsSL --proto '=https' --max-time 20 "https://github.com/${GITHUB_KEYS_USER}.keys") ||
      die "could not fetch https://github.com/${GITHUB_KEYS_USER}.keys"
    [[ -n ${out//[[:space:]]/} ]] || warn "github.com/$GITHUB_KEYS_USER has no public SSH keys"
    raw+=$out$'\n'
  fi
  # keys the user already has (re-runs)
  if id "$USER_NAME" &>/dev/null; then
    home=$(getent passwd "$USER_NAME" | cut -d: -f6)
    if [[ -r $home/.ssh/authorized_keys ]]; then raw+=$(grep -v ' vps-ci:' "$home/.ssh/authorized_keys" || true)$'\n'; fi
  fi
  # nothing given: reuse the key(s) of the account running this script
  if [[ -z ${raw//[[:space:]]/} ]]; then
    for f in ${SUDO_USER:+"$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ssh/authorized_keys"} /root/.ssh/authorized_keys; do
      if [[ -r $f ]]; then
        raw+=$(<"$f")$'\n'
        info "using the key(s) from $f"
      fi
    done
  fi
  mapfile -t ADMIN_KEYS < <(validate_keys <<<"$raw")
  ((${#ADMIN_KEYS[@]})) ||
    die "no SSH public key to log in with — set SSH_PUBLIC_KEY in the config (output of: cat ~/.ssh/id_ed25519.pub, on your laptop)"
}

show_plan() {
  step "Plan"
  info "user          $USER_NAME — the only login: SSH key, sudo, owns every container"
  info "ssh           port $SSH_PORT, keys only (passwords and root login disabled)"
  info "https         Traefik ($TRAEFIK_IMAGE), Let's Encrypt <$ACME_EMAIL>$(is_yes "$ACME_STAGING" && echo " [staging]")"
  info "deploys       from ${GHCR_PREFIX}* (GitHub Actions)"
  printf '\n' >&2
  warn "After this, SSH accepts ONLY '$USER_NAME' with the key(s) listed above."
  warn "Keep this session open until 'ssh $USER_NAME@$(public_ip)' works from a NEW terminal."
  confirm "Proceed?" || die "aborted"
}

# --- base system --------------------------------------------------------------
setup_base_system() {
  step "Base system"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  local -a apt=(apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

  "${apt[@]}" update
  "${apt[@]}" full-upgrade
  "${apt[@]}" install --no-install-recommends \
    ca-certificates curl gnupg sudo xz-utils less nano procps iproute2 \
    openssh-server nftables fail2ban python3-systemd \
    unattended-upgrades apt-listchanges needrestart \
    dbus-user-session systemd-container uidmap util-linux python3 python3-yaml
  # Podman with its recommends (crun, passt, netavark, aardvark-dns, catatonit…)
  "${apt[@]}" install podman passt crun netavark aardvark-dns catatonit
  if ! dpkg -s chrony &>/dev/null; then
    "${apt[@]}" install --no-install-recommends systemd-timesyncd
  fi
  ok "packages installed and up to date"

  timedatectl set-ntp true || warn "could not enable NTP"
  timedatectl set-timezone "$TIMEZONE"

  if [[ -n $SERVER_HOSTNAME && $(hostnamectl --static 2>/dev/null) != "$SERVER_HOSTNAME" ]]; then
    hostnamectl set-hostname "$SERVER_HOSTNAME"
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
      sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$SERVER_HOSTNAME/" /etc/hosts
    else
      printf '127.0.1.1\t%s\n' "$SERVER_HOSTNAME" >>/etc/hosts
    fi
    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
      printf 'preserve_hostname: true\n' | write_file /etc/cloud/cloud.cfg.d/99-vps-hostname.cfg 0644
    fi
    ok "hostname: $SERVER_HOSTNAME"
  fi

  write_file /etc/needrestart/conf.d/90-vps.conf 0644 <<'EOF'
# Managed by vps-setup.sh: restart services after library upgrades without asking
$nrconf{restart} = 'a';
EOF

  write_file /etc/systemd/journald.conf.d/90-vps.conf 0644 <<'EOF'
# Managed by vps-setup.sh — container logs land here too (journald log driver)
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=500M
SystemKeepFree=1G
MaxRetentionSec=1month
EOF
  install -d -m 2755 -g systemd-journal /var/log/journal
  systemctl restart systemd-journald

  write_file /etc/systemd/coredump.conf.d/90-vps.conf 0644 <<'EOF'
# Managed by vps-setup.sh: core dumps can leak secrets from memory
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
  ok "time, journald and core dumps configured"
}

# --- the user ---------------------------------------------------------------
install_authorized_keys() {
  local file="$USER_HOME/.ssh/authorized_keys"
  install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" "$USER_HOME/.ssh"
  {
    if [[ -f $file ]]; then cat "$file"; fi
    printf '%s\n' "${ADMIN_KEYS[@]}"
  } | awk 'NF && !seen[$0]++' | write_file "$file" 0600 "$USER_NAME"
}

setup_sudo() {
  local status sudoers=/etc/sudoers.d/90-vps-user
  status=$(passwd -S "$USER_NAME" | awk '{print $2}')
  if is_yes "$SUDO_NOPASSWD"; then
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$USER_NAME" | write_file "$sudoers" 0440
  elif [[ $status == P ]]; then
    rm -f "$sudoers"
  elif [[ -t 0 ]]; then
    info "Choose a password for '$USER_NAME'. It is ONLY for sudo — SSH stays key-only."
    until passwd "$USER_NAME"; do warn "passwords did not match, try again"; done
    rm -f "$sudoers"
  else
    warn "no terminal to set a password for $USER_NAME → passwordless sudo for now"
    warn "harden later with: sudo passwd $USER_NAME && sudo rm $sudoers"
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$USER_NAME" | write_file "$sudoers" 0440
  fi
  if [[ -f $sudoers ]]; then
    visudo -cqf "$sudoers" || {
      rm -f "$sudoers"
      die "generated sudoers file was invalid"
    }
    ok "sudo: passwordless"
  else
    ok "sudo: asks for $USER_NAME's password"
  fi
}

ensure_subids() {
  local f start
  for f in /etc/subuid /etc/subgid; do
    touch "$f"
    if grep -q "^$USER_NAME:" "$f"; then continue; fi
    start=$(awk -F: 'BEGIN { m = 100000 } { e = $2 + $3; if (e > m) m = e } END { print m }' "$f")
    printf '%s:%s:65536\n' "$USER_NAME" "$start" >>"$f"
  done
}

setup_user() {
  step "User $USER_NAME"
  # cgroup v2 delegation, so rootless containers can enforce cpu/io/memory limits
  write_file /etc/systemd/system/user@.service.d/90-vps-delegate.conf 0644 <<'EOF'
# Managed by vps-setup.sh
[Service]
Delegate=cpu cpuset io memory pids
EOF
  systemctl daemon-reload

  if ! id "$USER_NAME" &>/dev/null; then
    useradd --create-home --shell /bin/bash "$USER_NAME"
    ok "created user $USER_NAME"
  fi
  usermod -aG sudo,adm,systemd-journal "$USER_NAME"
  ensure_subids
  load_user_ctx
  install_authorized_keys
  setup_sudo

  local d
  for d in "$USER_HOME/.config" "$USER_HOME/.config/containers" "$QUADLET_DIR" \
    "$USER_HOME/.config/systemd" "$USER_UNIT_DIR" "$TRAEFIK_DIR" "$TRAEFIK_DIR/dynamic" "$APPS_DIR"; do
    install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" "$d"
  done

  # linger: the user's services (all containers) start at boot, without a login
  loginctl enable-linger "$USER_NAME"
  local controllers="/sys/fs/cgroup/user.slice/user-$USER_UID.slice/user@$USER_UID.service/cgroup.controllers"
  if [[ -f $controllers ]] && ! grep -qw io "$controllers"; then
    systemctl restart "user@$USER_UID.service" # pick up the cgroup delegation
  fi
  systemctl start "user@$USER_UID.service"
  for _ in {1..30}; do
    if [[ -S /run/user/$USER_UID/bus ]]; then break; fi
    sleep 1
  done
  [[ -S /run/user/$USER_UID/bus ]] || die "systemd user manager for $USER_NAME did not come up"
  ok "SSH keys, sudo, lingering user services, cgroup delegation"
}

# --- memory: zram or swapfile -------------------------------------------------
setup_memory() {
  step "Memory"
  local mem_mb zram=no size
  mem_mb=$(awk '/^MemTotal/ { print int($2 / 1024) }' /proc/meminfo)

  if ((ZRAM_PERCENT > 0)) && apt-get -y -q install --no-install-recommends systemd-zram-generator >/dev/null 2>&1; then
    write_file /etc/systemd/zram-generator.conf 0644 <<EOF
# Managed by vps-setup.sh — compressed swap in RAM: fast, no disk wear
[zram0]
zram-size = min(ram * $ZRAM_PERCENT / 100, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF
    systemctl daemon-reload
    if ((WRITE_CHANGED)); then
      systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
    else
      systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
    fi
    if swapon --show=NAME --noheadings | grep -q zram; then zram=yes; fi
  fi

  if [[ $zram == yes ]]; then
    printf 'vm.swappiness = 100\nvm.page-cluster = 0\n' | write_file /etc/sysctl.d/91-vps-swap.conf 0644
    ok "zram swap: $ZRAM_PERCENT% of ${mem_mb} MiB RAM, zstd"
  else
    if ! swapon --show=NAME --noheadings | grep -q .; then
      size=$((mem_mb < 2048 ? mem_mb : 2048))
      if [[ ! -f /swapfile ]]; then
        fallocate -l "${size}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$size" status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
      fi
      grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
      swapon /swapfile 2>/dev/null || true
    fi
    printf 'vm.swappiness = 10\n' | write_file /etc/sysctl.d/91-vps-swap.conf 0644
    ok "swap: $(swapon --show=NAME --noheadings | paste -sd' ')"
  fi
}

# --- kernel & network ---------------------------------------------------------
setup_kernel() {
  step "Kernel hardening & network tuning"
  printf 'tcp_bbr\n' | write_file /etc/modules-load.d/90-vps-bbr.conf 0644
  modprobe tcp_bbr 2>/dev/null || warn "tcp_bbr unavailable — keeping the default congestion control"

  # A leading "-" makes systemd-sysctl skip keys this kernel doesn't have.
  write_file /etc/sysctl.d/90-vps.conf 0644 <<'EOF'
# Managed by vps-setup.sh

# --- network hardening
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1

# --- kernel hardening
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
-kernel.yama.ptrace_scope = 1
kernel.kexec_load_disabled = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0

# --- rootless containers
# user namespaces must stay enabled for rootless Podman
-kernel.unprivileged_userns_clone = 1
# lets the systemd *user* manager own ports 80/443 for Traefik (socket activation)
net.ipv4.ip_unprivileged_port_start = 80
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024

# --- performance
net.core.default_qdisc = fq
-net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
vm.vfs_cache_pressure = 50
EOF
  systemctl restart systemd-sysctl.service
  ok "sysctls applied (congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null))"
}

# --- automatic security updates -----------------------------------------------
setup_auto_updates() {
  step "Automatic security updates"
  write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  write_file /etc/apt/apt.conf.d/52vps-unattended-upgrades 0644 <<EOF
// Managed by vps-setup.sh
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "$(is_yes "$AUTO_REBOOT" && echo true || echo false)";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "$AUTO_REBOOT_TIME";
Unattended-Upgrade::SyslogEnable "true";
EOF
  systemctl enable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
  ok "unattended-upgrades on$(is_yes "$AUTO_REBOOT" && echo ", reboots at $AUTO_REBOOT_TIME when a kernel update needs it")"
}

# --- podlet -------------------------------------------------------------------
install_podlet() {
  step "Podlet $PODLET_VERSION"
  local target tmp got
  if command -v podlet >/dev/null && [[ $(podlet --version 2>/dev/null) == "podlet $PODLET_VERSION" ]]; then
    ok "already installed"
    return 0
  fi
  case $(uname -m) in
    x86_64) target=x86_64-unknown-linux-gnu ;;
    aarch64) target=aarch64-unknown-linux-gnu ;;
  esac
  tmp=$(mktemp -d)
  curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/podlet.tar.xz" \
    "https://github.com/containers/podlet/releases/download/v${PODLET_VERSION}/podlet-${target}.tar.xz"
  got=$(sha256sum "$tmp/podlet.tar.xz" | awk '{print $1}')
  if [[ $got != "${PODLET_SHA256[$target]}" ]]; then
    rm -rf "$tmp"
    die "podlet checksum mismatch (expected ${PODLET_SHA256[$target]}, got $got)"
  fi
  tar -xJf "$tmp/podlet.tar.xz" -C "$tmp"
  install -m 0755 -o root -g root "$tmp/podlet-$target/podlet" /usr/local/bin/podlet
  rm -rf "$tmp"
  ok "$(podlet --version) installed (sha256 verified)"
}

# --- rootless podman ----------------------------------------------------------
setup_podman() {
  step "Rootless Podman"
  write_file "$USER_HOME/.config/containers/containers.conf" 0644 "$USER_NAME" <<'EOF'
# Managed by vps-setup.sh
[containers]
# stdout/stderr → journald: rotated and size-capped, no log files growing forever
log_driver = "journald"

[engine]
events_logger = "journald"

[network]
default_rootless_network_cmd = "pasta"
EOF

  write_file "$USER_UNIT_DIR/vps-prune.service" 0644 "$USER_NAME" <<'EOF'
# Managed by vps-setup.sh
[Unit]
Description=Remove container images unused for a week

[Service]
Type=oneshot
ExecStart=/usr/bin/podman image prune --all --force --filter until=168h
EOF
  write_file "$USER_UNIT_DIR/vps-prune.timer" 0644 "$USER_NAME" <<'EOF'
# Managed by vps-setup.sh
[Unit]
Description=Weekly container image cleanup

[Timer]
OnCalendar=weekly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  user_systemctl daemon-reload
  # podman.socket: Docker-compatible API Traefik watches for new containers
  # podman-auto-update.timer: daily patch updates of Traefik (AutoUpdate=registry)
  user_systemctl enable --now podman.socket podman-auto-update.timer vps-prune.timer >/dev/null 2>&1
  ok "podman $(as_user podman version --format '{{.Client.Version}}'), API socket and timers enabled"
}

# --- traefik ------------------------------------------------------------------
render_traefik_static() {
  local cidr fwd=""
  # Drop request headers that alias the ones Traefik manages (X_Forwarded_For
  # would reach backends as X-Forwarded-For), and refuse encoded backslash and NUL in
  # paths (path-confusion tricks); %2F, %25, %3B etc. stay allowed for apps.
  local hardening='      aliasHeadersStrategy: delete
      encodedCharacters:
        allowEncodedBackSlash: false
        allowEncodedNullCharacter: false'
  if [[ -n $TRUSTED_PROXY_IPS ]]; then
    fwd=$'    forwardedHeaders:\n      trustedIPs:\n'
    for cidr in ${TRUSTED_PROXY_IPS//,/ }; do fwd+="        - \"$cidr\""$'\n'; done
  fi
  cat <<EOF
# Managed by vps-setup.sh — edit /etc/vps/vps.conf and re-run: sudo vps init
global:
  checkNewVersion: false
  sendAnonymousUsage: false

log:
  level: WARN
  format: json
EOF
  if is_yes "$ACCESS_LOG"; then
    printf '\naccessLog:\n  format: json\n  bufferingSize: 64\n'
  fi
  cat <<EOF

# Entry point names match FileDescriptorName= in the systemd socket units:
# systemd owns :80/:443 and hands them to Traefik (socket activation), so
# client IPs are preserved and nothing is forwarded through rootless networking.
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
${hardening}
${fwd}  websecure:
    address: ":443"
    http3: {}
    http:
      tls:
        certResolver: le
      middlewares:
        - secure@file
${hardening}
${fwd}
providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: web
    watch: true
  file:
    directory: /etc/traefik/dynamic
    watch: true

certificatesResolvers:
  le:
    acme:
      email: "$ACME_EMAIL"
      storage: /acme/acme.json
EOF
  if is_yes "$ACME_STAGING"; then
    printf '      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"\n'
  fi
  cat <<'EOF'
      httpChallenge:
        entryPoint: web

api:
  dashboard: false
EOF
}

render_traefik_dynamic() {
  cat <<EOF
# Managed by vps-setup.sh — applied to every HTTPS route.
# Add your own middlewares in other files in this directory (hot-reloaded).
http:
  middlewares:
    secure:
      chain:
        middlewares:
          - security-headers
          - rate-limit
          - compress
    security-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        contentTypeNosniff: true
        customFrameOptionsValue: SAMEORIGIN
        referrerPolicy: strict-origin-when-cross-origin
        permissionsPolicy: "camera=(), microphone=(), geolocation=(), payment=()"
        customResponseHeaders:
          Server: ""
          X-Powered-By: ""
    rate-limit:
      rateLimit:
        average: $RATE_LIMIT_AVERAGE
        burst: $RATE_LIMIT_BURST
        period: 1s
$(if [[ -n $TRUSTED_PROXY_IPS ]]; then printf '        sourceCriterion:\n          ipStrategy:\n            depth: 1'; fi)
    compress:
      compress:
        minResponseBodyBytes: 1024

tls:
  options:
    default:
      minVersion: VersionTLS12
      sniStrict: true
      cipherSuites:
        - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
        - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
EOF
}

render_traefik_container() {
  cat <<EOF
# Managed by vps-setup.sh
[Unit]
Description=Traefik reverse proxy (socket-activated)
Requires=traefik-http.socket traefik-https.socket podman.socket
After=traefik-http.socket traefik-https.socket podman.socket

[Container]
Image=$TRAEFIK_IMAGE
ContainerName=traefik
Network=web.network
Notify=true
AutoUpdate=registry
NoNewPrivileges=true
ReadOnly=true
DropCapability=ALL
PidsLimit=256
PodmanArgs=--memory=256m
# Docker-compatible API of rootless Podman: Traefik discovers containers by label
Volume=%t/podman/podman.sock:/var/run/docker.sock
Volume=%h/.config/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
Volume=%h/.config/traefik/dynamic:/etc/traefik/dynamic:ro
Volume=traefik-acme.volume:/acme

[Service]
Sockets=traefik-http.socket traefik-https.socket
Restart=always
TimeoutStartSec=300

[Install]
WantedBy=default.target
EOF
}

setup_traefik() {
  step "Traefik"
  local changed=0 busy

  # Dynamic config is hot-reloaded; the static config and unit need a restart.
  write_file "$TRAEFIK_DIR/dynamic/00-vps.yml" 0644 "$USER_NAME" < <(render_traefik_dynamic)
  write_file "$TRAEFIK_DIR/traefik.yml" 0644 "$USER_NAME" < <(render_traefik_static)
  if ((WRITE_CHANGED)); then changed=1; fi
  write_file "$QUADLET_DIR/traefik.container" 0644 "$USER_NAME" < <(render_traefik_container)
  if ((WRITE_CHANGED)); then changed=1; fi

  write_file "$QUADLET_DIR/web.network" 0644 "$USER_NAME" <<'EOF'
# Managed by vps-setup.sh — shared network between Traefik and public services
[Network]
NetworkName=web
EOF
  write_file "$QUADLET_DIR/traefik-acme.volume" 0644 "$USER_NAME" <<'EOF'
# Managed by vps-setup.sh — Let's Encrypt certificates
[Volume]
VolumeName=traefik-acme
EOF
  write_file "$USER_UNIT_DIR/traefik-http.socket" 0644 "$USER_NAME" <<'EOF'
# Managed by vps-setup.sh
[Unit]
Description=Traefik :80 (HTTP → HTTPS redirect, ACME challenges)

[Socket]
ListenStream=80
FileDescriptorName=web
Service=traefik.service

[Install]
WantedBy=sockets.target
EOF
  write_file "$USER_UNIT_DIR/traefik-https.socket" 0644 "$USER_NAME" <<'EOF'
# Managed by vps-setup.sh
[Unit]
Description=Traefik :443 (HTTPS over TCP, HTTP/3 over UDP)

[Socket]
ListenStream=443
ListenDatagram=443
FileDescriptorName=websecure
Service=traefik.service

[Install]
WantedBy=sockets.target
EOF

  validate_quadlets || die "Quadlet rejected the Traefik units in $QUADLET_DIR"
  busy=$(ss -Hltnup '( sport = :80 or sport = :443 )' 2>/dev/null | grep -v '"systemd"' || true)
  if [[ -n $busy ]]; then
    printf '%s\n' "$busy" >&2
    die "ports 80/443 are used by another program (often apache2/nginx from the provider image) — remove it and re-run"
  fi

  user_systemctl daemon-reload
  user_systemctl enable --now traefik-http.socket traefik-https.socket >/dev/null 2>&1
  info "pulling $TRAEFIK_IMAGE"
  as_user podman pull -q "$TRAEFIK_IMAGE" >/dev/null
  if ((changed)) || ! user_systemctl is-active --quiet traefik.service; then
    user_systemctl restart traefik.service
    sleep 2
  fi
  if ! user_systemctl is-active --quiet traefik.service; then
    journalctl -n 30 --no-pager "_SYSTEMD_USER_UNIT=traefik.service" + "CONTAINER_NAME=traefik" >&2 || true
    die "Traefik failed to start"
  fi
  ok "running — :80/:443 via systemd sockets, HTTP/3, Let's Encrypt"
}

# --- vps command + saved config -----------------------------------------------
install_self() {
  step "vps command"
  local src
  src=$(readlink -f "${BASH_SOURCE[0]}")
  [[ -f $src ]] || die "run this script from a file (not through a pipe)"
  if [[ $src != "$INSTALL_PATH" ]]; then install -m 0755 -o root -g root "$src" "$INSTALL_PATH"; fi
  install -d -m 0755 "$CONFIG_DIR"
  render_config | write_file "$CONFIG_PATH" 0644 root
  ok "installed $INSTALL_PATH, settings saved in $CONFIG_PATH"
}

# --- firewall -----------------------------------------------------------------
setup_firewall() {
  step "Firewall (nftables)"
  write_file /etc/nftables.conf 0755 root <<EOF
#!/usr/sbin/nft -f
# Managed by vps-setup.sh
# Only this table is (re)created, so fail2ban's own table survives reloads.
# Rootless Podman never touches the host firewall: nothing bypasses these rules.

table inet vps_filter
delete table inet vps_filter

table inet vps_filter {
  chain input {
    type filter hook input priority filter; policy drop;

    ct state established,related accept
    ct state invalid drop
    iif "lo" accept

    # ICMP/ICMPv6: path-MTU discovery, neighbour discovery, rate-limited ping
    icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
    icmp type echo-request limit rate 5/second burst 10 packets accept
    icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, mld-listener-query } accept
    icmpv6 type echo-request limit rate 5/second burst 10 packets accept
    # DHCPv6 replies (some providers configure IPv6 that way)
    ip6 saddr fe80::/10 udp dport 546 accept

    tcp dport $SSH_PORT accept comment "ssh"
    tcp dport { 80, 443 } accept comment "http, https"
    udp dport 443 accept comment "http/3"
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
EOF
  nft -c -f /etc/nftables.conf || die "generated /etc/nftables.conf failed validation"
  systemctl enable nftables.service >/dev/null 2>&1
  # never `restart`: the stop action of nftables.service flushes *every* table
  if systemctl is-active --quiet nftables.service; then
    systemctl reload nftables.service
  else
    systemctl start nftables.service
  fi
  ok "inbound: default deny — open: ssh/$SSH_PORT, 80, 443 (tcp+udp)"
}

# --- fail2ban -----------------------------------------------------------------
setup_fail2ban() {
  step "fail2ban"
  # recidive reads fail2ban's own log, so it must be a file
  write_file /etc/fail2ban/fail2ban.d/90-vps.local 0644 root <<'EOF'
# Managed by vps-setup.sh
[Definition]
logtarget = /var/log/fail2ban.log
EOF
  touch /var/log/fail2ban.log
  chmod 0640 /var/log/fail2ban.log
  write_file /etc/fail2ban/jail.d/90-vps.local 0644 root <<EOF
# Managed by vps-setup.sh
[DEFAULT]
backend = systemd
banaction = nftables-multiport
banaction_allports = nftables-allports
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = $SSH_PORT
mode = aggressive

# repeat offenders: banned on all ports for a week
[recidive]
enabled = true
backend = auto
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime = 1w
findtime = 1d
maxretry = 3
EOF
  fail2ban-client -t >/dev/null || die "fail2ban configuration test failed"
  systemctl enable fail2ban.service >/dev/null 2>&1
  systemctl restart fail2ban.service
  ok "sshd jail (aggressive) + recidive"
}

# --- ssh ----------------------------------------------------------------------
# Keep only the algorithms this OpenSSH build supports.
supported_algos() {
  local kind=$1 want=$2 have a out=()
  have=$(ssh -Q "$kind" 2>/dev/null)
  for a in $want; do
    if grep -qxF "$a" <<<"$have"; then out+=("$a"); fi
  done
  local IFS=,
  printf '%s' "${out[*]}"
}

setup_ssh() {
  step "SSH"
  local conf=/etc/ssh/sshd_config.d/00-vps-hardening.conf backup="" kex ciphers macs hostkeys pubkeys effective

  # never lock the user out: there must be a login key
  grep -v ' vps-ci:' "$USER_HOME/.ssh/authorized_keys" 2>/dev/null | grep -q . ||
    die "$USER_NAME has no SSH key — refusing to disable password logins"

  ssh-keygen -A >/dev/null
  kex=$(supported_algos kex "mlkem768x25519-sha256 sntrup761x25519-sha512 sntrup761x25519-sha512@openssh.com curve25519-sha256 curve25519-sha256@libssh.org")
  ciphers=$(supported_algos cipher "chacha20-poly1305@openssh.com aes256-gcm@openssh.com aes128-gcm@openssh.com")
  macs=$(supported_algos mac "hmac-sha2-512-etm@openssh.com hmac-sha2-256-etm@openssh.com umac-128-etm@openssh.com")
  hostkeys=$(supported_algos key-sig "ssh-ed25519 ssh-ed25519-cert-v01@openssh.com rsa-sha2-512 rsa-sha2-256 rsa-sha2-512-cert-v01@openssh.com rsa-sha2-256-cert-v01@openssh.com")
  pubkeys=$(supported_algos key-sig "ssh-ed25519 ssh-ed25519-cert-v01@openssh.com sk-ssh-ed25519@openssh.com sk-ssh-ed25519-cert-v01@openssh.com ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521 sk-ecdsa-sha2-nistp256@openssh.com rsa-sha2-512 rsa-sha2-256")

  if [[ -f $conf ]]; then
    backup=$(mktemp)
    cp -p "$conf" "$backup"
  fi
  # 00- sorts first and sshd keeps the first value it reads, so this wins over
  # cloud-init's 50-cloud-init.conf (which often re-enables passwords).
  write_file "$conf" 0644 root <<EOF
# Managed by vps-setup.sh
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers $USER_NAME
MaxAuthTries 3
MaxSessions 4
MaxStartups 10:30:60
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
PermitUserEnvironment no
X11Forwarding no
AllowAgentForwarding no
# ssh -L tunnels (e.g. to a database) stay possible for you; deploy keys
# carry "restrict", which disables every kind of forwarding for them
AllowTcpForwarding local
AllowStreamLocalForwarding no
GatewayPorts no
PermitTunnel no
UseDNS no
LogLevel VERBOSE
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
KexAlgorithms $kex
Ciphers $ciphers
MACs $macs
HostKeyAlgorithms $hostkeys
PubkeyAcceptedAlgorithms $pubkeys
EOF
  if ! sshd -t; then
    if [[ -n $backup ]]; then mv -f "$backup" "$conf"; else rm -f "$conf"; fi
    die "sshd rejected the new configuration — previous config restored, nothing restarted"
  fi
  rm -f "$backup"

  if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    write_file /etc/systemd/system/ssh.socket.d/90-vps-port.conf 0644 root <<EOF
# Managed by vps-setup.sh
[Socket]
ListenStream=
ListenStream=$SSH_PORT
EOF
    systemctl daemon-reload
    systemctl restart ssh.socket
  else
    systemctl restart ssh.service
  fi

  effective=$(sshd -T -C "user=$USER_NAME,host=localhost,addr=127.0.0.1" 2>/dev/null |
    grep -E '^(passwordauthentication|permitrootlogin) ' | sort | paste -sd' ')
  [[ $effective == "passwordauthentication no permitrootlogin no" ]] || die "unexpected effective sshd settings: $effective"
  ok "keys only, no root login, only $USER_NAME may log in, port $SSH_PORT"
}

# --- summary ------------------------------------------------------------------
print_summary() {
  local ip fp port_flag=""
  ip=$(public_ip)
  fp=$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')
  if [[ $SSH_PORT != 22 ]]; then port_flag=" -p $SSH_PORT"; fi
  step "Done"
  cat >&2 <<EOF

  ${C_BOLD}1. Test SSH from a NEW terminal on your laptop (keep this one open):${C_RESET}
       ssh$port_flag $USER_NAME@$ip
     server fingerprint: $fp (ED25519)

  ${C_BOLD}2. DNS:${C_RESET} point your domain(s) to $ip with A records
     (a wildcard *.yourdomain.com makes every new subdomain work immediately)

  ${C_BOLD}3. Smoke test (as $USER_NAME, no sudo):${C_RESET}
       printf 'services:\\n  web:\\n    image: docker.io/traefik/whoami\\n    labels: {vps.domain: whoami.yourdomain.com, vps.port: "80"}\\n' > whoami.yaml
       vps deploy whoami whoami.yaml          # → https://whoami.yourdomain.com
       vps remove whoami --purge              # clean up afterwards

  ${C_BOLD}4. Deploy a GitHub repo on every push:${C_RESET}
       vps ci-key myapp      → add the 5 secrets it prints to the repo
       vps workflow myapp    → save as .github/workflows/cd.yml
                               (--after CI: deploy only after your CI workflow passes)
       vps compose-example   → save as compose.yaml, adjust, then git push

  Everything else: vps help
EOF
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != "$USER_NAME" && $SUDO_USER != root ]]; then
    printf '\n  Once step 1 works, the provider account is no longer needed:\n       sudo deluser --remove-home %s\n' "$SUDO_USER" >&2
  fi
  if [[ -f /run/reboot-required ]]; then
    printf '\n' >&2
    warn "a kernel update needs a reboot — after step 1 works: sudo reboot (all apps come back by themselves)"
  fi
}

cmd_init() {
  local config=""
  while (($#)); do
    case $1 in
      --config | -c)
        need_value "$@"
        config=$2
        shift 2
        ;;
      --yes | -y)
        ASSUME_YES=yes
        shift
        ;;
      *) die "unknown option for init: $1" ;;
    esac
  done
  preflight
  resolve_config "$config"
  validate_config
  collect_admin_keys
  show_plan

  setup_base_system
  setup_user
  setup_memory
  setup_kernel
  setup_auto_updates
  install_podlet
  setup_podman
  setup_traefik
  install_self
  setup_firewall
  setup_fail2ban
  setup_ssh
  print_summary
}

# =============================================================================
#  Apps — a compose file becomes Quadlet units via Podlet (rootless, per user)
#
#  App "shop" with services web + db becomes:
#    shop.network            private network: services find each other by name
#    shop-web.container      + Traefik labels when it has vps.domain / vps.port
#    shop-db.container
#    volumes                 shop-<volume>
#  ~/apps/shop/.env is given to every service (secrets; never in Git).
#  ~/apps/shop/releases/<time> keeps each deploy; `current` points at the live one.
# =============================================================================

# Python helper (PyYAML). `normalize` validates the compose file and rewrites
# what Podlet can't handle; `transform` namespaces and hardens Podlet's output
# and refuses anything outside a whitelist of Quadlet keys.
vps_py() {
  python3 -I - "$@" <<'PY'
import json, re, shlex, sys
import yaml

def fail(msg):
    print(f"  compose: {msg}", file=sys.stderr)
    sys.exit(1)

def warn(msg):
    print(f"  ! compose: {msg}", file=sys.stderr)

SERVICE_RE = re.compile(r"^[a-z][a-z0-9-]{0,30}$")
VOLUME_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,62}$")
HEADER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,63}$")
DOMAIN_RE = re.compile(r"^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$")
IMAGE_RE = re.compile(r"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?/[a-z0-9]+([._/-][a-z0-9]+)*"
                      r"(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?(@sha256:[a-f0-9]{64})?$")
# Docker's default capability set: re-adding these is fine, anything else is refused.
SAFE_CAPS = {"CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "NET_BIND_SERVICE", "SETGID",
             "SETUID", "SETPCAP", "SETFCAP", "SYS_CHROOT", "MKNOD", "NET_RAW", "AUDIT_WRITE"}
ALLOWED = {"image", "command", "entrypoint", "environment", "labels", "depends_on", "healthcheck",
           "restart", "volumes", "tmpfs", "read_only", "user", "working_dir", "mem_limit",
           "mem_reservation", "memswap_limit", "cpus", "pids_limit", "cap_add", "cap_drop",
           "shm_size", "stop_grace_period", "stop_signal", "init", "security_opt", "ulimits",
           "extra_hosts", "dns"}
IGNORED = {  # meaningless on the server, or managed by vps
    "build": None, "expose": None, "hostname": None, "domainname": None, "links": None,
    "develop": None, "profiles": None, "pull_policy": None, "platform": None,
    "ports": "Traefik routes traffic — use labels vps.domain + vps.port",
    "networks": "every project gets its own network; services reach each other by name",
    "container_name": "containers are named <project>-<service>",
    "env_file": "secrets live on the server: vps env <app> KEY=VALUE",
    "logging": "logs go to journald",
}
FORBIDDEN = {
    "privileged": "privileged containers", "network_mode": "custom network modes",
    "pid": "host PID namespace", "ipc": "custom IPC namespaces", "devices": "host devices",
    "userns_mode": "custom user namespaces", "cgroup": "custom cgroups",
    "cgroup_parent": "custom cgroups", "sysctls": "sysctls", "volumes_from": "volumes_from",
    "secrets": "compose secrets (use the server .env)", "configs": "compose configs",
    "runtime": "custom runtimes", "group_add": "extra groups",
    "device_cgroup_rules": "device rules", "oom_kill_disable": "disabling the OOM killer",
    "storage_opt": "storage options", "isolation": "isolation modes",
}

def qualify(img):
    first = img.split("/")[0]
    if "/" not in img or ("." not in first and ":" not in first and first != "localhost"):
        img = "docker.io/" + (img if "/" in img else "library/" + img)
    return img

def repo_of(img):
    base = img.split("@")[0]
    if ":" in base.rsplit("/", 1)[-1]:
        base = base[: base.rfind(":")]
    return base

def unescape(value, where):
    """Compose interpolation isn't supported by Podlet: allow $$ escapes, refuse ${VAR}."""
    if isinstance(value, dict):
        return {k: unescape(v, where) for k, v in value.items()}
    if isinstance(value, list):
        return [unescape(v, where) for v in value]
    if isinstance(value, str):
        tmp = value.replace("$$", "\0")
        if re.search(r"\$\{?[A-Za-z_]", tmp):
            fail(f"{where}: variable interpolation ({value!r}) isn't supported — "
                 "put the value in the server .env: vps env <app> KEY=VALUE")
        return tmp.replace("\0", "$")
    return value

def normalize(src, dst, meta_path, project, ci_image, prefixes):
    prefixes = prefixes.split()
    try:
        with open(src) as fh:
            doc = yaml.safe_load(fh)
    except yaml.YAMLError as err:
        fail(f"invalid YAML: {err}")
    if not isinstance(doc, dict) or not isinstance(doc.get("services"), dict) or not doc["services"]:
        fail("needs a top-level 'services:' mapping")
    for key in list(doc):
        if key.startswith("x-") or key in ("name", "version", "networks"):
            doc.pop(key)
        elif key not in ("services", "volumes"):
            fail(f"top-level '{key}' is not supported")

    declared = doc.get("volumes") or {}
    if not isinstance(declared, dict):
        fail("'volumes' must be a mapping")
    for vname, vdef in declared.items():
        if not VOLUME_RE.match(str(vname)):
            fail(f"invalid volume name '{vname}'")
        if vdef not in (None, {}):
            fail(f"volume '{vname}': drivers, options and external volumes aren't supported")

    services = doc["services"]
    if len(services) > 20:
        fail("at most 20 services per project")
    meta = {"services": {}}
    ci_repo = repo_of(ci_image) if ci_image else None

    for name, svc in services.items():
        name = str(name)
        where = f"service '{name}'"
        if not SERVICE_RE.match(name):
            fail(f"{where}: names must be lowercase letters, digits and '-'")
        if len(project) + 1 + len(name) > 63:
            fail(f"{where}: '{project}-{name}' is longer than 63 characters")
        if not isinstance(svc, dict):
            fail(f"{where} must be a mapping")

        deploy = svc.pop("deploy", None) or {}
        if deploy.get("replicas", 1) not in (1, None):
            fail(f"{where}: replicas > 1 isn't supported")
        limits = (deploy.get("resources") or {}).get("limits") or {}
        if "memory" in limits:
            svc.setdefault("mem_limit", limits["memory"])
        if "cpus" in limits:
            svc.setdefault("cpus", limits["cpus"])

        for key in list(svc):
            if key.startswith("x-"):
                svc.pop(key)
            elif key in FORBIDDEN:
                fail(f"{where}: '{key}' is not allowed ({FORBIDDEN[key]})")
            elif key in IGNORED:
                if key == "build" and "image" not in svc:
                    fail(f"{where}: has 'build' but no 'image' — use image: ${{IMAGE}} for the image CI builds")
                if IGNORED[key]:
                    warn(f"{where}: ignoring '{key}' — {IGNORED[key]}")
                svc.pop(key)
            elif key not in ALLOWED:
                fail(f"{where}: '{key}' is not supported")
        if "image" not in svc:
            fail(f"{where}: 'image' is required")

        # image: ${IMAGE} (or the CI repository itself) is pinned to the digest CI just pushed
        image = str(svc["image"]).strip()
        if image in ("${IMAGE}", "$IMAGE"):
            if not ci_image:
                fail(f"{where}: uses ${{IMAGE}} but no image was passed to deploy")
            image = ci_image
        else:
            image = qualify(image)
            if ci_repo and repo_of(image) == ci_repo:
                image = ci_image
        if not IMAGE_RE.match(image):
            fail(f"{where}: invalid image '{image}'")
        if prefixes != ["*"] and not any(image.startswith(p) for p in prefixes):
            fail(f"{where}: image {image} is not allowed (ALLOWED_IMAGES: {' '.join(prefixes)})")
        svc["image"] = image

        # labels: vps.domain / vps.port become namespaced Traefik labels later
        labels = svc.pop("labels", None) or {}
        if isinstance(labels, list):
            labels = dict(item.split("=", 1) if "=" in item else (item, "") for item in map(str, labels))
        domains, redirects, headers, port, keep = [], [], {}, None, {}
        for key, value in labels.items():
            key, value = str(key), "" if value is None else str(value)
            if key == "vps.domain":
                domains = [d.strip().lower() for d in value.split(",") if d.strip()]
            elif key == "vps.redirect":
                redirects = [d.strip().lower() for d in value.split(",") if d.strip()]
            elif key == "vps.port":
                port = value.strip()
            elif key.startswith("vps.headers."):
                header = key[len("vps.headers."):]
                if not HEADER_RE.match(header):
                    fail(f"{where}: invalid header name in label '{key}'")
                if any(c in value for c in '"\\\n\r'):
                    fail(f"{where}: label '{key}': double quotes, backslashes and line breaks are not allowed")
                headers[header] = value.strip()
            elif key.startswith("traefik."):
                warn(f"{where}: ignoring label {key} — vps generates Traefik labels from vps.domain/vps.port")
            elif key.startswith(("vps.", "io.containers.", "io.podman.", "PODMAN_")):
                fail(f"{where}: label '{key}' is reserved")
            else:
                keep[key] = value
        if keep:
            svc["labels"] = keep
        for domain in domains + redirects:
            if not DOMAIN_RE.match(domain):
                fail(f"{where}: invalid domain '{domain}'")
        if domains:
            if not (port or "").isdigit() or not 1 <= int(port) <= 65535:
                fail(f"{where}: label vps.port (the port the service listens on) is required with vps.domain")
        else:
            if port:
                warn(f"{where}: vps.port without vps.domain is ignored")
            if redirects or headers:
                fail(f"{where}: vps.redirect and vps.headers.* need vps.domain")
        for domain in redirects:
            if domain in domains:
                fail(f"{where}: {domain} is in both vps.domain and vps.redirect")

        env = svc.get("environment")
        if isinstance(env, dict):
            clean = {}
            for key, value in env.items():
                if value is None:
                    warn(f"{where}: environment '{key}' has no value (pass-through doesn't exist here) — skipped")
                    continue
                clean[str(key)] = str(value).lower() if isinstance(value, bool) else str(value)
            svc["environment"] = clean
        elif env is not None and not isinstance(env, list):
            fail(f"{where}: 'environment' must be a mapping or a list")

        deps = svc.get("depends_on")
        if deps is not None:
            if not isinstance(deps, (list, dict)):
                fail(f"{where}: 'depends_on' must be a list or a mapping")
            # Conditions are dropped: with a healthcheck, Notify=healthy makes systemd
            # wait for the dependency to be healthy anyway (= service_healthy).
            svc["depends_on"] = [str(d) for d in deps]

        if "cpus" in svc:
            svc["cpus"] = float(svc["cpus"])
        if "pids_limit" in svc:
            svc["pids_limit"] = int(svc["pids_limit"])

        caps = []
        for cap in svc.get("cap_add") or []:
            cap = str(cap).upper().removeprefix("CAP_")
            if cap not in SAFE_CAPS:
                fail(f"{where}: cap_add {cap} is not allowed")
            caps.append(cap)
        if caps:
            svc["cap_add"] = caps
        for opt in svc.pop("security_opt", None) or []:
            if str(opt).replace("=", ":") not in ("no-new-privileges", "no-new-privileges:true"):
                fail(f"{where}: security_opt '{opt}' is not allowed")

        vols = []
        for vol in svc.get("volumes") or []:
            if isinstance(vol, dict):
                if vol.get("type", "volume") != "volume":
                    fail(f"{where}: only named volumes are allowed (use 'tmpfs:' for scratch space)")
                source, target = str(vol.get("source") or ""), str(vol.get("target") or "")
                rest = [target] + (["ro"] if vol.get("read_only") else [])
            else:
                source, *rest = str(vol).split(":")
                if not rest:
                    fail(f"{where}: anonymous volume '{vol}' — give it a name, e.g. data:{vol}")
            if source.startswith(("/", ".", "~")) or "/" in source:
                fail(f"{where}: bind mount '{source}' is not allowed — use a named volume")
            if source not in declared:
                fail(f"{where}: volume '{source}' must be declared under top-level 'volumes:'")
            if not rest[0].startswith("/") or any(o not in ("ro", "rw") for o in rest[1:]):
                fail(f"{where}: invalid volume '{vol}'")
            vols.append(":".join([f"{project}-{source}"] + rest))
        if vols:
            svc["volumes"] = vols

        services[name] = unescape(svc, where)
        meta["services"][name] = {"domains": domains, "port": int(port) if domains else None,
                                  "redirects": redirects, "headers": headers}

    for name, svc in services.items():
        for dep in svc.get("depends_on") or []:
            if dep not in services:
                fail(f"service '{name}': depends_on unknown service '{dep}'")

    if declared:
        doc["volumes"] = {f"{project}-{v}": None for v in declared}
    else:
        doc.pop("volumes", None)
    with open(dst, "w") as fh:
        yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False)
    with open(meta_path, "w") as fh:
        json.dump(meta, fh)

CONTAINER_KEYS = {"Image", "Environment", "Exec", "Entrypoint", "WorkingDir", "User", "Group",
                  "Label", "Annotation", "HealthCmd", "HealthInterval", "HealthRetries",
                  "HealthStartPeriod", "HealthTimeout", "HealthOnFailure", "HealthStartupCmd",
                  "HealthStartupInterval", "HealthStartupRetries", "HealthStartupSuccess",
                  "HealthStartupTimeout", "Volume", "Tmpfs", "ReadOnly", "ReadOnlyTmpfs",
                  "NoNewPrivileges", "DropCapability", "AddCapability", "PidsLimit", "Ulimit",
                  "ShmSize", "StopSignal", "StopTimeout", "RunInit", "PodmanArgs", "AddHost",
                  "DNS", "Notify", "Timezone", "Memory"}
PODMAN_FLAGS = {"--cpus", "--memory", "--memory-reservation", "--memory-swap", "--shm-size",
                "--init", "--stop-timeout", "--cpu-shares"}

def parse_unit(path):
    sections, current, pending = {}, None, ""
    with open(path) as fh:
        for raw in fh:
            line = pending + raw.rstrip("\n")
            if line.endswith("\\"):
                pending = line[:-1] + " "
                continue
            pending = ""
            stripped = line.strip()
            if not stripped or stripped.startswith(("#", ";")):
                continue
            if stripped.startswith("[") and stripped.endswith("]"):
                current = stripped[1:-1]
                sections.setdefault(current, [])
                continue
            if current is None or "=" not in stripped:
                fail(f"unexpected line in Podlet output: {stripped}")
            key, value = stripped.split("=", 1)
            sections[current].append((key.strip(), value.strip()))
    return sections

def transform(gen_dir, out_dir, meta_path, project, defaults, taken_path):
    memory, cpus, pids = defaults.split()
    with open(meta_path) as fh:
        services = json.load(fh)["services"]
    taken = {}
    with open(taken_path) as fh:
        for line in fh:
            if line.strip():
                domain, owner = line.split()
                taken[domain] = owner

    for name, info in services.items():
        unit = f"{project}-{name}"
        sections = parse_unit(f"{gen_dir}/{name}.container")
        for section in sections:
            if section not in ("Unit", "Container", "Service", "Install"):
                fail(f"service '{name}': unexpected section [{section}] from Podlet")

        out = [f"# Generated by vps from the compose file of app {project} (via Podlet).",
               "# Don't edit: change compose.yaml and redeploy.", "[Unit]",
               f"Description={project}/{name}"]
        for key, value in sections.get("Unit", []):
            if key not in ("Requires", "After", "Wants", "BindsTo"):
                fail(f"service '{name}': Podlet produced [Unit] {key}=, which vps does not allow")
            deps = []
            for dep in value.split():
                if not dep.endswith(".service") or dep[:-8] not in services:
                    fail(f"service '{name}': unexpected dependency {dep}")
                deps.append(f"{project}-{dep}")
            out.append(f"{key}={' '.join(deps)}")

        out += ["", "[Container]", f"ContainerName={unit}"]
        present, podman_args = set(), ""
        for key, value in sections.get("Container", []):
            if key not in CONTAINER_KEYS:
                fail(f"service '{name}': Podlet produced {key}=, which vps does not allow")
            if key == "Volume":
                for item in value.split():
                    source = item.split(":")[0]
                    if not source.startswith(f"{project}-") or "/" in source:
                        fail(f"service '{name}': volume '{item}' is not allowed")
            if key == "AddCapability" and not set(value.upper().replace("CAP_", "").split()) <= SAFE_CAPS:
                fail(f"service '{name}': capability '{value}' is not allowed")
            if key == "PodmanArgs":
                for token in shlex.split(value):
                    if token.startswith("-") and token.split("=", 1)[0] not in PODMAN_FLAGS:
                        fail(f"service '{name}': podman option '{token}' is not allowed")
                podman_args += " " + value
            present.add(key)
            # systemd expands $VAR and %x in the generated ExecStart: keep compose values literal
            out.append(f"{key}={value.replace('%', '%%').replace('$', '$$')}")

        out.append(f"Network={project}.network:alias={name}")
        if info["domains"]:
            out.append("Network=web.network")
        out += [f"EnvironmentFile=%h/apps/{project}/.env",
                f"Label=vps.project={project}", f"Label=vps.service={name}"]
        if info["domains"]:
            redirects, headers = info.get("redirects") or [], info.get("headers") or {}
            for domain in info["domains"] + redirects:
                owner = taken.get(domain)
                if owner and owner != project:
                    fail(f"service '{name}': domain {domain} is already served by '{owner}'")

            def label(key, value):
                # quoted for Quadlet; $ and % doubled so systemd passes them through literally
                return f'Label="{key}={value.replace("%", "%%").replace("$", "$$")}"'

            rule = " || ".join(f"Host(`{d}`)" for d in info["domains"])
            out += ["Label=traefik.enable=true", "Label=traefik.docker.network=web",
                    f"Label=traefik.http.services.{unit}.loadbalancer.server.port={info['port']}",
                    label(f"traefik.http.routers.{unit}.rule", rule),
                    f"Label=traefik.http.routers.{unit}.entrypoints=websecure",
                    f"Label=traefik.http.routers.{unit}.tls.certresolver=le",
                    f"Label=traefik.http.routers.{unit}.service={unit}"]
            if headers:
                for header, value in headers.items():
                    out.append(label(f"traefik.http.middlewares.{unit}-headers.headers.customresponseheaders.{header}", value))
                out.append(f"Label=traefik.http.routers.{unit}.middlewares={unit}-headers")
            if redirects:
                # vps.redirect: these hosts answer with a 301 to the first vps.domain
                rule = " || ".join(f"Host(`{d}`)" for d in redirects)
                out += [label(f"traefik.http.routers.{unit}-redirect.rule", rule),
                        f"Label=traefik.http.routers.{unit}-redirect.entrypoints=websecure",
                        f"Label=traefik.http.routers.{unit}-redirect.tls.certresolver=le",
                        f"Label=traefik.http.routers.{unit}-redirect.service={unit}",
                        f"Label=traefik.http.routers.{unit}-redirect.middlewares={unit}-redirect",
                        label(f"traefik.http.middlewares.{unit}-redirect.redirectregex.regex", "^https?://[^/]+(.*)$"),
                        label(f"traefik.http.middlewares.{unit}-redirect.redirectregex.replacement",
                              f"https://{info['domains'][0]}${{1}}"),
                        f"Label=traefik.http.middlewares.{unit}-redirect.redirectregex.permanent=true"]
        # secure, bounded defaults unless compose.yaml asked for something else
        if "NoNewPrivileges" not in present:
            out.append("NoNewPrivileges=true")
        if "PidsLimit" not in present:
            out.append(f"PidsLimit={pids}")
        extra = []
        if "--memory" not in podman_args and "Memory" not in present:
            extra.append(f"--memory {memory}")
        if "--cpus" not in podman_args:
            extra.append(f"--cpus {cpus}")
        if extra:
            out.append(f"PodmanArgs={' '.join(extra)}")
        if "HealthCmd" in present:
            if "Notify" not in present:
                out.append("Notify=healthy")  # start = healthy: deploys and depends_on wait for it
            if "HealthOnFailure" not in present:
                out.append("HealthOnFailure=kill")

        out += ["", "[Service]"]
        restart = "always"
        for key, value in sections.get("Service", []):
            if key != "Restart":
                fail(f"service '{name}': Podlet produced [Service] {key}=, which vps does not allow")
            restart = value
        out += [f"Restart={restart}", "TimeoutStartSec=300", "", "[Install]", "WantedBy=default.target"]
        with open(f"{out_dir}/{unit}.container", "w") as fh:
            fh.write("\n".join(out) + "\n")

    with open(f"{out_dir}/{project}.network", "w") as fh:
        fh.write(f"# Generated by vps: private network of project {project}\n"
                 f"[Network]\nNetworkName={project}\n")

if __name__ == "__main__":
    command, *args = sys.argv[1:]
    {"normalize": normalize, "transform": transform}[command](*args)
PY
}

# -----------------------------------------------------------------------------
# Deploy engine (runs as the user)
# -----------------------------------------------------------------------------
# Podman version Podlet should target (clamped to what this Podlet knows).
podlet_compat() {
  local have supported
  have=$(podman version --format '{{.Client.Version}}' 2>/dev/null | cut -d. -f1,2)
  supported=$(podlet --help 2>/dev/null | sed -n 's/^[[:space:]]*- \([0-9][0-9]*\.[0-9][0-9]*\): Podman.*/\1/p')
  [[ -n $supported ]] || die "could not read the supported Podman versions from 'podlet --help'"
  if grep -qx "$have" <<<"$supported"; then
    printf '%s' "$have"
  else
    sort -V <<<"$supported" | tail -n 1
  fi
}

app_exists() { [[ -L $APPS_DIR/$1/current ]]; }

require_app() {
  valid_app_name "${1-}" || die "invalid app name '${1-}' (a-z, 0-9 and '-', 2-32 characters)"
  app_exists "$1" || die "no app named '$1' (see: vps list)"
}

release_units() {
  local f
  for f in "$1"/units/*.container; do basename "$f" .container; done
}

app_units() { release_units "$(readlink -f "$APPS_DIR/$1/current")"; }

app_domains() {
  { cat "$(readlink -f "$APPS_DIR/$1/current")"/units/*.container | grep -o 'Host(`[^`]*`)' || true; } |
    sed 's/^Host(`//; s/`)$//' | sort -u
}

lock_app() {
  exec 9>"$XDG_RUNTIME_DIR/vps-$1.lock"
  flock -w 600 9 || die "another operation on $1 is still running"
}

# Domains routed by other apps: "domain owner" lines.
taken_hosts() {
  local app=$1 f owner domain
  for f in "$QUADLET_DIR"/*.container; do
    owner=$(sed -n 's/^Label=vps\.project=//p' "$f" | head -n 1)
    if [[ -z $owner || $owner == "$app" ]]; then continue; fi
    while read -r domain; do
      if [[ -n $domain ]]; then printf '%s %s\n' "$domain" "$owner"; fi
    done < <(grep -o 'Host(`[^`]*`)' "$f" | sed 's/^Host(`//; s/`)$//')
  done
}

pull_image() {
  local image=$1
  local -a pull_cmd=(podman pull --quiet)
  # the image built by CI is pulled with the one-shot token of that CI run
  if [[ -n $HOOK_AUTHFILE && $image == "$HOOK_CI_IMAGE" ]]; then pull_cmd+=(--authfile "$HOOK_AUTHFILE"); fi
  info "pulling $image"
  "${pull_cmd[@]}" "$image" >/dev/null || die "could not pull $image"
}

# Make release NEW live (replacing release OLD, if any). Only services whose
# unit changed are restarted; systemd orders them by depends_on and, with a
# healthcheck, waits until they are healthy. Then verify everything stays up.
compose_activate() {
  local new=$1 old=${2-} f u ok=1
  local -a units=() old_units=() gone=() changed=() same=()
  mapfile -t units < <(release_units "$new")
  if [[ -n $old ]]; then mapfile -t old_units < <(release_units "$old"); fi
  for u in "${old_units[@]}"; do
    if [[ " ${units[*]} " != *" $u "* ]]; then gone+=("$u.service"); fi
  done
  for u in "${units[@]}"; do
    if cmp -s "$new/units/$u.container" "$QUADLET_DIR/$u.container"; then same+=("$u.service"); else changed+=("$u.service"); fi
  done

  if ((${#gone[@]})); then systemctl --user stop "${gone[@]}" 2>/dev/null || true; fi
  if [[ -n $old ]]; then
    for f in "$old"/units/*; do rm -f "$QUADLET_DIR/${f##*/}"; done
  fi
  cp -f "$new"/units/* "$QUADLET_DIR"/
  systemctl --user daemon-reload

  if ((${#changed[@]})); then
    info "restarting: ${changed[*]%.service}"
    if ! systemctl --user restart "${changed[@]}"; then ok=0; fi
  fi
  if ((${#same[@]})); then
    if ! systemctl --user start "${same[@]}"; then ok=0; fi
  fi
  if ((ok && ${#changed[@]})); then sleep "$SETTLE_SECONDS"; fi
  for u in "${units[@]}"; do
    if ! systemctl --user is-active --quiet "$u.service"; then
      warn "$u is not running ($(unit_state "$u"))"
      ok=0
    fi
  done
  ((ok))
}

# Take a release offline (used when the very first deploy of an app fails).
compose_withdraw() {
  local rel=$1 f
  local -a units=()
  mapfile -t units < <(release_units "$rel")
  systemctl --user stop "${units[@]/%/.service}" 2>/dev/null || true
  for f in "$rel"/units/*; do rm -f "$QUADLET_DIR/${f##*/}"; done
  systemctl --user daemon-reload
}

# Keep the newest KEEP_RELEASES releases (always including the live one).
prune_releases() {
  local proj="$APPS_DIR/$1" cur r
  local -a rels=()
  cur=$(readlink -f "$proj/current")
  for r in "$proj"/releases/*; do rels+=("$r"); done
  ((${#rels[@]} > KEEP_RELEASES)) || return 0
  for r in "${rels[@]:0:${#rels[@]}-KEEP_RELEASES}"; do
    if [[ $r != "$cur" ]]; then rm -rf "$r"; fi
  done
}

# Keep the newest KEEP_RELEASES images of the app's own repository (rollback targets).
prune_images() {
  local repo=${1%@*}
  [[ -n $1 ]] || return 0
  if [[ ${repo##*/} == *:* ]]; then repo=${repo%:*}; fi
  podman images --filter "reference=$repo" --format '{{.ID}}' 2>/dev/null |
    awk '!seen[$0]++' | tail -n +"$((KEEP_RELEASES + 1))" |
    while read -r id; do podman rmi "$id" >/dev/null 2>&1 || true; done
}

reject_release() {
  local rel=$1 proj=${1%/releases/*}
  if [[ -L $proj/current ]]; then
    mv -f "$rel" "$rel.rejected" # kept next to the live release for inspection
  else
    # never deployed: leave nothing behind except secrets you already set
    rm -rf "$rel"
    rmdir "$proj/releases" 2>/dev/null || true
    if [[ ! -s $proj/.env ]]; then rm -f "$proj/.env"; fi
    rmdir "$proj" 2>/dev/null || true
  fi
  die "$2"
}

# deploy_release APP COMPOSE_FILE IMAGE ALLOWLIST PULL(yes|no)
#   IMAGE      replaces image: ${IMAGE} in the compose file (may be empty)
#   ALLOWLIST  image prefixes the compose file may use ("*" = any)
deploy_release() {
  local app=$1 compose=$2 image=$3 allow=$4 pull_all=$5
  local proj="$APPS_DIR/$1" rel cur="" stage f img d
  local -a domains=()
  python3 -c 'import yaml' 2>/dev/null || die "python3-yaml is missing — run: sudo vps init"

  install -d -m 0700 "$proj" "$proj/releases"
  if [[ ! -f $proj/.env ]]; then install -m 0600 /dev/null "$proj/.env"; fi
  # nanosecond timestamps: unique and sorted chronologically
  rel="$proj/releases/$(date -u +%Y%m%dT%H%M%S.%N)"
  mkdir -m 0700 "$rel"
  mkdir "$rel/units" "$rel/podlet"
  cp "$compose" "$rel/compose.yaml"
  if [[ -L $proj/current ]]; then cur=$(readlink -f "$proj/current"); fi

  step "Deploying $app"
  info "checking the compose file"
  vps_py normalize "$rel/compose.yaml" "$rel/compose.normalized.yaml" "$rel/meta.json" "$app" "$image" "$allow" ||
    reject_release "$rel" "the compose file was rejected (see above)"
  # --skip-services-check: Podlet only writes into this release's scratch folder; the units are
  # renamed to <app>-<service> afterwards. Its own check asks systemd for every unit whose name
  # merely *contains* "<service>.service", so the running release ("portfolio-web.service")
  # would block every redeploy of a service called "web".
  if ! NO_COLOR=1 RUST_BACKTRACE=0 podlet --podman-version "$(podlet_compat)" --skip-services-check \
    --file "$rel/podlet" compose "$rel/compose.normalized.yaml" >/dev/null 2>"$rel/podlet.log"; then
    sed 's/\x1b\[[0-9;]*m//g' "$rel/podlet.log" | sed -n '/^Error/,/^Location/p' | grep -v '^Location' >&2 || true
    reject_release "$rel" "Podlet could not convert the compose file"
  fi
  taken_hosts "$app" >"$rel/taken-hosts"
  vps_py transform "$rel/podlet" "$rel/units" "$rel/meta.json" "$app" \
    "$DEFAULT_MEMORY $DEFAULT_CPUS $DEFAULT_PIDS" "$rel/taken-hosts" ||
    reject_release "$rel" "the compose file was rejected (see above)"

  for f in "$rel"/units/*; do
    if [[ -e $QUADLET_DIR/${f##*/} && (-z $cur || ! -e $cur/units/${f##*/}) ]]; then
      reject_release "$rel" "${f##*/} already exists and belongs to something else — rename the app or the service"
    fi
  done

  # Dry-run Quadlet on the unit directory as it will look after the switch
  stage=$(mktemp -d "$XDG_RUNTIME_DIR/vps-stage.XXXXXX")
  cp -a "$QUADLET_DIR"/. "$stage"/
  if [[ -n $cur ]]; then
    for f in "$cur"/units/*; do rm -f "$stage/${f##*/}"; done
  fi
  cp "$rel"/units/* "$stage"/
  if ! QUADLET_UNIT_DIRS=$stage "$QUADLET_BIN" -dryrun -user >/dev/null 2>"$rel/quadlet.log"; then
    rm -rf "$stage"
    grep -v 'Loading source unit file' "$rel/quadlet.log" >&2 || true
    reject_release "$rel" "Quadlet rejected the generated units"
  fi
  rm -rf "$stage"

  # Pull what's missing (tags are not re-pulled unless --pull: bump the tag to upgrade)
  while read -r img; do
    if [[ $pull_all == yes ]] || ! podman image exists "$img"; then pull_image "$img"; fi
  done < <(sed -n 's/^Image=//p' "$rel"/units/*.container | sort -u)

  mapfile -t domains < <({ cat "$rel"/units/*.container | grep -o 'Host(`[^`]*`)' || true; } | sed 's/^Host(`//; s/`)$//' | sort -u)
  for d in "${domains[@]}"; do
    if ! getent ahosts "$d" >/dev/null 2>&1; then
      warn "DNS: $d does not resolve yet — HTTPS starts working once it points to this server"
    fi
  done

  if compose_activate "$rel" "$cur"; then
    ln -sfn "$rel" "$proj/current"
    prune_releases "$app"
    prune_images "$image" || true
    ok "$app is live"
    for d in "${domains[@]}"; do info "https://$d"; done
    return 0
  fi

  mv -f "$rel" "$rel.failed"
  if [[ -n $cur ]]; then
    warn "rolling back to the previous release"
    if compose_activate "$cur" "$rel.failed"; then
      die "deploy failed — the previous release is running again (logs: vps logs $app)"
    fi
    die "deploy failed and the previous release did not come back — check: vps logs $app"
  fi
  compose_withdraw "$rel.failed"
  die "the first deploy of $app failed, nothing was left running (logs: vps logs $app)"
}

rollback_release() {
  local app=$1 proj="$APPS_DIR/$1" cur prev="" r img
  cur=$(readlink -f "$proj/current")
  for r in "$proj"/releases/*; do
    if [[ $r == *.failed || $r == *.rejected ]]; then continue; fi
    if [[ $r == "$cur" ]]; then break; fi
    prev=$r
  done
  [[ -n $prev ]] || die "$app has no earlier release to roll back to"
  while read -r img; do
    podman image exists "$img" || die "image $img of that release was cleaned up — redeploy that commit instead"
  done < <(sed -n 's/^Image=//p' "$prev"/units/*.container | sort -u)

  step "Rolling back $app: ${cur##*/} → ${prev##*/}"
  if compose_activate "$prev" "$cur"; then
    ln -sfn "$prev" "$proj/current"
    ok "$app is back on ${prev##*/}"
    return 0
  fi
  compose_activate "$cur" "$prev" || true
  die "rollback failed — ${cur##*/} restored"
}

# -----------------------------------------------------------------------------
# App commands (run as the user, no sudo)
# -----------------------------------------------------------------------------
cmd_deploy() {
  local app=${1-} file=${2-} image="" pull=no
  shift $(($# < 2 ? $# : 2))
  while (($#)); do
    case $1 in
      --image) need_value "$@"; image=$2; shift 2 ;;
      --pull) pull=yes; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  valid_app_name "$app" || die "usage: vps deploy NAME COMPOSE_FILE [--image IMAGE] [--pull]"
  [[ -n $file && -f $file && -r $file ]] || die "compose file not found: ${file:-<missing>}"
  if [[ -n $image ]]; then
    valid_image_ref "$image" || die "--image must be fully qualified, e.g. ghcr.io/owner/app:tag"
  fi
  lock_app "$app"
  # deploys you run yourself may use any image; CI deploys are limited to ALLOWED_IMAGES
  deploy_release "$app" "$file" "$image" "*" "$pull"
}

cmd_list() {
  local d app u state active hosts
  local -a units=()
  printf '%-20s %-12s %-26s %s\n' APP STATE RELEASE DOMAINS
  for d in "$APPS_DIR"/*/; do
    app=$(basename "$d")
    app_exists "$app" || continue
    mapfile -t units < <(app_units "$app")
    active=0
    for u in "${units[@]}"; do
      if systemctl --user is-active --quiet "$u.service"; then active=$((active + 1)); fi
    done
    if ((active == ${#units[@]})); then
      state=running
    elif ((active == 0)); then
      state=stopped
    else
      state="partial $active/${#units[@]}"
    fi
    hosts=$(app_domains "$app" | paste -sd, -)
    printf '%-20s %-12s %-26s %s\n' "$app" "$state" "$(basename "$(readlink -f "$d/current")")" "${hosts:--}"
  done
}

cmd_status() {
  local svc u app=${1-}
  if [[ -n $app ]]; then
    require_app "$app"
    step "$app (release $(basename "$(readlink -f "$APPS_DIR/$app/current")"))"
    while read -r u; do
      printf '  %-28s %-20s %s\n' "$u" "$(unit_state "$u")" "$(unit_image "$QUADLET_DIR/$u.container")"
    done < <(app_units "$app")
    while read -r u; do info "https://$u"; done < <(app_domains "$app")
    return 0
  fi
  step "Server"
  printf '  %-20s %s\n' "uptime" "$(uptime -p)"
  printf '  %-20s %s\n' "memory" "$(free -h | awk '/^Mem:/ { print $3 " / " $2 }')"
  printf '  %-20s %s\n' "swap" "$(free -h | awk '/^Swap:/ { print $3 " / " $2 }')"
  printf '  %-20s %s\n' "disk /" "$(df -h / | awk 'NR == 2 { print $3 " / " $2 " (" $5 ")" }')"
  if [[ -f /run/reboot-required ]]; then printf '  %-20s %s\n' "reboot" "needed (kernel update): sudo reboot"; fi
  for svc in ssh nftables fail2ban unattended-upgrades; do
    printf '  %-20s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || true)"
  done
  printf '  %-20s %s\n' "traefik" "$(systemctl --user is-active traefik.service 2>/dev/null || true) — $(unit_image "$QUADLET_DIR/traefik.container")"
  step "Apps"
  cmd_list
}

cmd_logs() {
  local app=${1-} u
  local -a match=() follow=()
  require_app "$app"
  if [[ ${2-} == -f || ${2-} == --follow ]]; then follow=(-f); fi
  while read -r u; do
    if ((${#match[@]})); then match+=(+); fi
    match+=("_SYSTEMD_USER_UNIT=$u.service" + "CONTAINER_NAME=$u")
  done < <(app_units "$app")
  journalctl -n 200 --no-hostname -o short-iso "${follow[@]}" "${match[@]}" || true
}

cmd_restart() {
  local app=${1-}
  local -a units=()
  require_app "$app"
  lock_app "$app"
  mapfile -t units < <(app_units "$app")
  systemctl --user restart "${units[@]/%/.service}"
  ok "$app restarted"
}

cmd_rollback() {
  require_app "${1-}"
  lock_app "$1"
  rollback_release "$1"
}

cmd_env() {
  local app=${1-} kv file
  shift || true
  valid_app_name "$app" || die "usage: vps env NAME [KEY=VALUE ...]"
  file="$APPS_DIR/$app/.env"
  # works before the first deploy too, so secrets are in place when the app starts
  install -d -m 0700 "$APPS_DIR/$app"
  if [[ ! -f $file ]]; then install -m 0600 /dev/null "$file"; fi
  if (($#)); then
    for kv in "$@"; do
      [[ $kv =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "expected KEY=VALUE, got: $kv"
      {
        grep -v "^${kv%%=*}=" "$file" || true
        printf '%s\n' "$kv"
      } | write_file "$file" 0600
    done
  elif [[ -t 0 ]]; then
    "${EDITOR:-nano}" "$file"
    chmod 0600 "$file"
  else
    die "usage: vps env NAME KEY=VALUE ...   (or run it in a terminal to open an editor)"
  fi
  ok "$file updated ($(grep -c . "$file" || true) variables)"
  if ! app_exists "$app"; then
    info "$app isn't deployed yet — the values apply from its first deploy"
  elif [[ -t 0 ]] && confirm "Restart $app to apply?"; then
    cmd_restart "$app"
  else
    info "apply with: vps restart $app"
  fi
}

cmd_remove() {
  local app=${1-} purge=no f
  local -a units=()
  require_app "$app"
  if [[ ${2-} == --purge ]]; then purge=yes; fi
  confirm "Remove $app$([[ $purge == yes ]] && echo " AND delete its data (volumes, .env, releases)")?" || die "aborted"
  lock_app "$app"
  mapfile -t units < <(app_units "$app")
  systemctl --user stop "${units[@]/%/.service}" 2>/dev/null || true
  for f in "$(readlink -f "$APPS_DIR/$app/current")"/units/*; do rm -f "$QUADLET_DIR/${f##*/}"; done
  systemctl --user daemon-reload
  rm -f "$APPS_DIR/$app/current"
  {
    grep -v " vps-ci:$app\$" "$USER_HOME/.ssh/authorized_keys" 2>/dev/null || true
  } | write_file "$USER_HOME/.ssh/authorized_keys" 0600
  podman network rm -f "$app" >/dev/null 2>&1 || true

  if [[ $purge == yes ]]; then
    delete_app_data "$app"
    ok "$app removed with all its data; its deploy key is revoked"
  else
    ok "$app removed (deploy key revoked); data kept — delete it with: vps remove-data $app"
  fi
}

# Volumes (named in any release of the app), .env and releases.
delete_app_data() {
  local app=$1 vol
  local -a vols=()
  mapfile -t vols < <(cat "$APPS_DIR/$app"/releases/*/units/*.container 2>/dev/null |
    sed -n 's/^Volume=\([^:/]*\):.*/\1/p' | sort -u)
  for vol in "${vols[@]}"; do
    if podman volume rm -f "$vol" >/dev/null 2>&1; then info "deleted volume $vol"; fi
  done
  rm -rf "${APPS_DIR:?}/$app"
}

cmd_remove_data() {
  local app=${1-}
  valid_app_name "$app" || die "usage: vps remove-data NAME"
  if app_exists "$app"; then die "$app is still deployed — use: vps remove $app --purge"; fi
  [[ -d $APPS_DIR/$app ]] || die "there is no data for $app"
  confirm "Delete all data of $app (volumes, .env, releases)?" || die "aborted"
  lock_app "$app"
  delete_app_data "$app"
  ok "data of $app deleted"
}

# -----------------------------------------------------------------------------
# ci-key — an SSH key that can only deploy one app (forced command)
# -----------------------------------------------------------------------------
cmd_ci_key() {
  local app=${1-} host="" hostspec known k tmp pub auth="$USER_HOME/.ssh/authorized_keys"
  shift || true
  while (($#)); do
    case $1 in
      --host) need_value "$@"; host=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  valid_app_name "$app" || die "usage: vps ci-key NAME [--host HOST]   (NAME: a-z, 0-9, '-')"
  host=${host:-$(public_ip)}
  [[ -n $host && $host != "<server-ip>" ]] || die "could not detect the public IP — use: vps ci-key $app --host <public IP or domain>"
  if [[ $host =~ ^[0-9.]+$ ]] && ! is_public_ipv4 "$host"; then
    warn "$host is a private address that GitHub cannot reach — use --host <public IP or domain>"
  fi

  tmp=$(mktemp -d)
  ssh-keygen -q -t ed25519 -N '' -C "vps-ci:$app" -f "$tmp/id"
  pub=$(<"$tmp/id.pub")
  # one key per app: running this again rotates it
  {
    grep -v " vps-ci:$app\$" "$auth" 2>/dev/null || true
    printf 'restrict,command="%s deploy-hook --app %s" %s\n' "$INSTALL_PATH" "$app" "$pub"
  } | write_file "$auth" 0600

  hostspec=$host
  if [[ $SSH_PORT != 22 ]]; then hostspec="[$host]:$SSH_PORT"; fi
  known=""
  for k in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
    if [[ -f $k ]]; then known+="$hostspec $(cut -d' ' -f1,2 "$k")"$'\n'; fi
  done

  cat <<EOF
# GitHub → your repo → Settings → Environments → production (or: Secrets and variables → Actions)
# Add these 5 secrets. The private key is shown only once — run this again to rotate it.

VPS_HOST
$host

VPS_PORT
$SSH_PORT

VPS_USER
$USER_NAME

VPS_KNOWN_HOSTS
${known%$'\n'}

VPS_SSH_KEY
$(<"$tmp/id")
EOF
  shred -u "$tmp/id" 2>/dev/null || rm -f "$tmp/id"
  rm -rf "$tmp"
  ok "deploy key for '$app' installed — it can only deploy, roll back or show the status of $app"
}

# -----------------------------------------------------------------------------
# workflow — GitHub Actions: build → GHCR → deploy
# -----------------------------------------------------------------------------
cmd_workflow() {
  local app=${1-} after="" compose="compose.yaml" platform trigger cond summary
  shift || true
  while (($#)); do
    case $1 in
      --after) need_value "$@"; after=$2; shift 2 ;;
      --compose) need_value "$@"; compose=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  resolve_config ""
  valid_app_name "$app" || die "usage: vps workflow NAME [--after WORKFLOW] [--compose PATH] > .github/workflows/cd.yml"
  if [[ -n $after && ! $after =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,63}$ ]]; then die "--after: invalid workflow name"; fi
  [[ $compose =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && $compose != *..* ]] || die "--compose: use a relative path such as deploy/compose.yaml"
  platform="linux/$(dpkg --print-architecture 2>/dev/null || echo amd64)"

  if [[ -n $after ]]; then
    trigger="  # deploy only what the \"$after\" workflow has already tested on main
  workflow_run:
    workflows: ['$after']
    types: [completed]
    branches: [main]
  workflow_dispatch:
"
    cond="    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event.workflow_run.conclusion == 'success' &&
       github.event.workflow_run.event == 'push')
"
    summary="\"$after\" succeeded on main → build that exact commit → push to GHCR → the server"
  else
    trigger="  push:
    branches: [main]
  workflow_dispatch:
"
    cond=""
    summary="push to main → build the image → push it to GHCR → the server"
  fi

  sed -e "s|__APP__|$app|g" -e "s|__PLATFORM__|$platform|g" -e "s|__COMPOSE__|$compose|g" -e "s|__SUMMARY__|$summary|g" <<'EOF' |
# Generated by `vps workflow __APP__` on the server — save it in .github/workflows/
#
# Secrets (printed by `vps ci-key __APP__` on the server):
#   VPS_HOST, VPS_PORT, VPS_USER, VPS_KNOWN_HOSTS, VPS_SSH_KEY
#
# __SUMMARY__
# pulls that exact digest, turns __COMPOSE__ into Quadlet units (Podlet),
# restarts what changed, waits until it is healthy, and rolls back automatically if
# it is not (this run then fails).
name: Deploy __APP__

on:
__TRIGGER__

concurrency:
  group: deploy-__APP__
  cancel-in-progress: false

permissions: {}

env:
  COMPOSE_FILE: __COMPOSE__
  # the commit to build and deploy (for workflow_run: the commit that was tested)
  REF: ${{ github.event_name == 'workflow_run' && github.event.workflow_run.head_sha || github.sha }}

jobs:
  build:
    name: Build & push image
__IF__    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    outputs:
      image: ${{ steps.ref.outputs.image }}
    steps:
      - uses: actions/checkout@v7
        with:
          ref: ${{ env.REF }}

      - id: name
        run: echo "image=ghcr.io/${GITHUB_REPOSITORY,,}" >> "$GITHUB_OUTPUT"

      - uses: docker/setup-buildx-action@v4

      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: build
        uses: docker/build-push-action@v7
        with:
          context: .
          push: true
          platforms: __PLATFORM__
          provenance: false
          sbom: false
          tags: |
            ${{ steps.name.outputs.image }}:latest
            ${{ steps.name.outputs.image }}:${{ env.REF }}
          labels: org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - id: ref
        env:
          IMAGE: ${{ steps.name.outputs.image }}
          DIGEST: ${{ steps.build.outputs.digest }}
        run: echo "image=${IMAGE}@${DIGEST}" >> "$GITHUB_OUTPUT"

  deploy:
    name: Deploy to the server
    needs: build
    runs-on: ubuntu-latest
    environment: production
    permissions:
      contents: read
      packages: read
    steps:
      - uses: actions/checkout@v7
        with:
          ref: ${{ env.REF }}
          sparse-checkout: ${{ env.COMPOSE_FILE }}
          sparse-checkout-cone-mode: false

      - name: Deploy
        env:
          IMAGE: ${{ needs.build.outputs.image }}
          REGISTRY_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          VPS_HOST: ${{ secrets.VPS_HOST }}
          VPS_PORT: ${{ secrets.VPS_PORT }}
          VPS_USER: ${{ secrets.VPS_USER }}
          SSH_KEY: ${{ secrets.VPS_SSH_KEY }}
          KNOWN_HOSTS: ${{ secrets.VPS_KNOWN_HOSTS }}
        run: |
          test -f "$COMPOSE_FILE" || { echo "::error::$COMPOSE_FILE not found in the repo"; exit 1; }
          install -m 700 -d ~/.ssh
          printf '%s\n' "$SSH_KEY" > ~/.ssh/deploy_key && chmod 600 ~/.ssh/deploy_key
          printf '%s\n' "$KNOWN_HOSTS" > ~/.ssh/known_hosts
          # GitHub's runners are on the internet: a private or Tailscale address never works
          if [[ ! $VPS_PORT =~ ^[0-9]+$ || $VPS_HOST =~ ^$|^(10|127)\.|^192\.168\.|^169\.254\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|\.ts\.net$ ]]; then
            echo "::error::VPS_PORT must be a number, and VPS_HOST the server's public IP (not empty, private or Tailscale)."
            exit 1
          fi
          # stdin: line 1 = this run's short-lived token (used once to pull, never stored),
          # then the compose file
          rc=0
          { printf '%s\n' "$REGISTRY_TOKEN"; cat "$COMPOSE_FILE"; } |
            ssh -i ~/.ssh/deploy_key -p "$VPS_PORT" -o BatchMode=yes -o IdentitiesOnly=yes \
              -o StrictHostKeyChecking=yes -o ConnectTimeout=20 "$VPS_USER@$VPS_HOST" \
              deploy __APP__ "$IMAGE" "$GITHUB_ACTOR" || rc=$?
          if [[ $rc == 255 ]]; then
            echo "::error::SSH failed. 'Connection timed out': VPS_HOST/VPS_PORT are wrong (check the production environment too) or a firewall blocks the port. 'Permission denied' or 'Host key verification failed': run 'vps ci-key __APP__' again and update all 5 secrets."
          fi
          exit "$rc"
EOF
    TRIGGER=$trigger COND=$cond awk '
      /^__TRIGGER__$/ { printf "%s", ENVIRON["TRIGGER"]; next }
      /^__IF__/ { printf "%s", ENVIRON["COND"]; sub(/^__IF__/, ""); print; next }
      { print }'
}

# -----------------------------------------------------------------------------
# deploy-hook — the forced command of a deploy key (see ci-key)
#   deploy APP IMAGE [REGISTRY_USER]   stdin: registry token line, then compose file
#   rollback APP
#   status APP
# -----------------------------------------------------------------------------
cmd_deploy_hook() {
  local bound="" action app token="" size
  local -a req=()
  if [[ ${1-} == --app ]]; then bound=${2-}; fi
  read -r -a req <<<"${SSH_ORIGINAL_COMMAND:-}"
  ((${#req[@]} >= 2 && ${#req[@]} <= 4)) ||
    die "usage: deploy APP IMAGE [REGISTRY_USER] | rollback APP | status APP"
  action=${req[0]}
  app=${req[1]}
  valid_app_name "$app" || die "invalid app name"
  [[ -n $bound && $bound == "$app" ]] || die "this key may only manage '$bound'"
  enter_user_mode
  trap 'rm -f "${HOOK_AUTHFILE:-}" "${HOOK_COMPOSE:-}"' EXIT

  case $action in
    deploy)
      ((${#req[@]} >= 3)) || die "usage: deploy APP IMAGE [REGISTRY_USER]"
      HOOK_CI_IMAGE=${req[2]}
      valid_image_ref "$HOOK_CI_IMAGE" || die "invalid image reference"
      [[ -n $GHCR_PREFIX ]] || die "GITHUB_OWNER is not set in $CONFIG_PATH"
      [[ $HOOK_CI_IMAGE == "$GHCR_PREFIX"* ]] || die "only images under $GHCR_PREFIX can be deployed"

      IFS= read -r -t 10 token || true
      HOOK_COMPOSE=$(mktemp "$XDG_RUNTIME_DIR/vps-compose.XXXXXX")
      timeout 10 head -c 262145 >"$HOOK_COMPOSE" || true
      size=$(stat -c %s "$HOOK_COMPOSE")
      ((size > 0)) || die "no compose file received — add compose.yaml to the repo"
      ((size <= 262144)) || die "the compose file is larger than 256 KiB"

      if [[ -n ${req[3]-} ]]; then
        [[ ${req[3]} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,38}(\[bot\])?$ ]] || die "invalid registry user"
        [[ -n $token && ${#token} -le 4096 ]] || die "registry user given but no token on stdin"
        HOOK_AUTHFILE=$(mktemp "$XDG_RUNTIME_DIR/vps-auth.XXXXXX") # tmpfs, 0600, removed on exit
        printf '{}\n' >"$HOOK_AUTHFILE" # podman refuses an empty auth file, but accepts an empty object
        printf '%s' "$token" | podman login --authfile "$HOOK_AUTHFILE" --username "${req[3]}" \
          --password-stdin "${HOOK_CI_IMAGE%%/*}" >/dev/null || die "registry login failed"
      fi
      token=""

      lock_app "$app"
      deploy_release "$app" "$HOOK_COMPOSE" "$HOOK_CI_IMAGE" "$IMAGE_ALLOWLIST" no
      ;;
    rollback)
      require_app "$app"
      lock_app "$app"
      rollback_release "$app"
      ;;
    status)
      require_app "$app"
      cmd_status "$app"
      ;;
    *) die "unknown command: $action" ;;
  esac
}

# -----------------------------------------------------------------------------
# Templates & help
# -----------------------------------------------------------------------------
cmd_compose_example() {
  cat <<'EOF'
# compose.yaml — production stack, deployed by the server on every push to main.
# The server turns it into Quadlet units with Podlet (rootless Podman + systemd).
#
#   image: ${IMAGE}      the image GitHub Actions just built (pinned by digest)
#   vps.domain/vps.port  public HTTPS through Traefik (Let's Encrypt, HTTP/3)
#   vps.redirect         other hosts that 301-redirect to the first vps.domain
#   vps.headers.NAME     extra response headers, e.g. Content-Security-Policy
#   service names        are hostnames on the app's private network (DB_HOST: db)
#   secrets              NOT here: `vps env myapp KEY=VALUE` on the server
#                        (one .env per app, given to every service)
#   not allowed          ports, bind mounts, privileged, ${VAR} interpolation

services:
  web:
    image: ${IMAGE}
    labels:
      vps.domain: app.example.com     # several: example.com,www.example.com
      vps.port: "3333"                # the port the app listens on in the container
      # vps.redirect: www.app.example.com             # 301 to the first vps.domain
      # vps.headers.Content-Security-Policy: "default-src 'self'"   # extra response header
    environment:
      HOST: 0.0.0.0
      PORT: 3333
      NODE_ENV: production
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: app
      DB_DATABASE: app
      # DB_PASSWORD, APP_KEY → vps env myapp DB_PASSWORD=… APP_KEY=…
    depends_on: [db]                  # starts after db is healthy
    healthcheck:                      # deploys wait for "healthy", else roll back
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:3333/health"]
      interval: 30s
      start_period: 20s
      retries: 3
    mem_limit: 512m
    volumes:
      - uploads:/app/storage

  db:
    image: postgres:17                # Docker official images are allowed
    environment:
      POSTGRES_USER: app
      POSTGRES_DB: app
      # POSTGRES_PASSWORD → vps env myapp POSTGRES_PASSWORD=… (same as DB_PASSWORD)
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER}"]
      interval: 5s
      retries: 10
    mem_limit: 512m

volumes:
  uploads:
  pgdata:
EOF
}

cmd_config_example() {
  cat <<'EOF'
# vps.conf — settings for vps-setup.sh (KEY="value"; parsed, never executed)
# Usage: sudo bash vps-setup.sh init --config vps.conf

# --- you ------------------------------------------------------------------------
USER_NAME="admin"                  # your one login: SSH, sudo, and owner of all apps
SSH_PUBLIC_KEY=""                  # REQUIRED unless below: output of `cat ~/.ssh/id_ed25519.pub` on your laptop
GITHUB_KEYS_USER=""                # optional: also allow the keys at https://github.com/<user>.keys
SUDO_NOPASSWD="no"                 # "no" = sudo asks for a password (you choose it during init)
SSH_PORT="22"

# --- server ---------------------------------------------------------------------
SERVER_HOSTNAME=""
TIMEZONE="UTC"                     # e.g. Asia/Jakarta
AUTO_REBOOT="yes"                  # reboot for kernel security updates…
AUTO_REBOOT_TIME="04:00"           # …at this time (apps come back by themselves)
ZRAM_PERCENT="50"                  # compressed swap in RAM; 0 = swap file on disk

# --- https ----------------------------------------------------------------------
ACME_EMAIL=""                      # REQUIRED: your e-mail, for Let's Encrypt
ACME_STAGING="no"                  # "yes" while experimenting (avoids Let's Encrypt rate limits)
TRAEFIK_IMAGE="docker.io/library/traefik:v3.7"   # minor version pinned, patches auto-update daily
ACCESS_LOG="no"
TRUSTED_PROXY_IPS=""               # comma-separated CIDRs if you put Cloudflare's proxy in front
RATE_LIMIT_AVERAGE="100"           # requests per second per client IP…
RATE_LIMIT_BURST="200"             # …with this burst

# --- deploys --------------------------------------------------------------------
GITHUB_OWNER=""                    # REQUIRED: GitHub user/org — CI may deploy ghcr.io/<owner>/* only
#ALLOWED_IMAGES="ghcr.io/owner/ docker.io/library/"   # images a compose file from CI may use
DEFAULT_MEMORY="512m"              # per-service limits unless the compose file sets its own
DEFAULT_CPUS="1"
DEFAULT_PIDS="512"
KEEP_RELEASES="5"                  # releases (and images) kept for rollback
SETTLE_SECONDS="5"                 # a service must stay up this long after a restart
EOF
}

usage() {
  cat <<EOF
vps $VPS_VERSION — rootless Podman apps on a hardened Debian 13 server

Set up the server (once, as root; safe to re-run):
  bash vps-setup.sh config-example > vps.conf      then edit it
  sudo bash vps-setup.sh init --config vps.conf
  sudo vps init                                    re-apply /etc/vps/vps.conf later

Deploy from GitHub on every push (as your user, no sudo):
  vps ci-key NAME                 deploy key for one app → prints 5 GitHub secrets
  vps workflow NAME [--after CI] [--compose deploy/compose.yaml]
                                  GitHub Actions workflow → .github/workflows/cd.yml
                                  (--after: deploy only after that workflow succeeds on main)
  vps compose-example             starting point for the repo's compose.yaml
  vps env NAME KEY=VALUE ...      secrets for the app (works before the first deploy)
  git push                        → build → GHCR → live, or rolled back

Manage apps:
  vps list                        apps, state, domains
  vps status [NAME]               server overview, or one app
  vps logs NAME [-f]              logs of all services of an app
  vps restart NAME
  vps rollback NAME               back to the previous release
  vps env NAME                    edit the app's .env in an editor
  vps deploy NAME FILE [--image IMAGE] [--pull]
                                  deploy a compose file by hand (any image)
  vps remove NAME [--purge]       remove an app (--purge: also delete its data; -y: no prompt)
  vps remove-data NAME            delete the data an earlier \`vps remove\` kept

compose.yaml rules:
  image: \${IMAGE}                the image built by CI
  labels: vps.domain + vps.port   public HTTPS (several domains: a.com,www.a.com)
          vps.redirect            hosts that 301-redirect to the first vps.domain
          vps.headers.NAME        extra response header (e.g. Content-Security-Policy)
  named volumes only; no ports, privileged, bind mounts or \${VAR} (use vps env)
EOF
}

main() {
  local cmd=${1:-help} arg
  local -a args=()
  shift || true
  for arg in "$@"; do # -y/--yes anywhere: skip confirmations
    if [[ $arg == -y || $arg == --yes ]]; then ASSUME_YES=yes; else args+=("$arg"); fi
  done
  set -- "${args[@]}"
  case $cmd in
    init) cmd_init "$@" ;;
    deploy-hook) cmd_deploy_hook "$@" ;;
    workflow) cmd_workflow "$@" ;;
    compose-example) cmd_compose_example ;;
    config-example) cmd_config_example ;;
    deploy | list | ls | status | logs | restart | rollback | env | remove | rm | remove-data | ci-key)
      enter_user_mode
      case $cmd in
        deploy) cmd_deploy "$@" ;;
        list | ls) cmd_list ;;
        status) cmd_status "$@" ;;
        logs) cmd_logs "$@" ;;
        restart) cmd_restart "$@" ;;
        rollback) cmd_rollback "$@" ;;
        env) cmd_env "$@" ;;
        remove | rm) cmd_remove "$@" ;;
        remove-data) cmd_remove_data "$@" ;;
        ci-key) cmd_ci_key "$@" ;;
      esac
      ;;
    version | --version) printf 'vps %s\n' "$VPS_VERSION" ;;
    help | -h | --help) usage ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

# Piped: `curl -fsSL https://dotfiles.r3p.dev/vps-setup.sh | bash`. There is no
# file to install as `vps` and stdin is the script itself, so download the
# script, build a vps.conf from the environment and questions on the terminal,
# and run init from there. Nothing personal is downloaded: every setting comes
# from whoever runs it. Extra args go to init (`| bash -s -- --yes`), and
# `--config FILE` skips the questions and uses that file.

# Ask for one setting unless the environment already has it.
ask_setting() {
  local key=$1 question=$2 default=${3-} required=${4-} answer
  if [[ -v $key ]]; then return 0; fi
  if [[ ! -r /dev/tty ]] || ! (: </dev/tty) 2>/dev/null; then
    printf -v "$key" '%s' "$default"
    return 0
  fi
  while :; do
    read -r -p "  $question${default:+ [$default]}: " answer </dev/tty
    answer=${answer:-$default}
    if [[ -n $answer || -z $required ]]; then break; fi
    warn "required"
  done
  printf -v "$key" '%s' "$answer"
}

bootstrap_from_pipe() {
  local base=${VPS_SETUP_URL:-https://dotfiles.r3p.dev} dir arg key has_config=0 rc=0
  local -a args=("$@") run=()
  local tty=/dev/null
  command -v curl >/dev/null || die "curl is required"
  [[ $(os_release ID) == debian ]] || die "this script targets Debian (found: $(os_release ID))"
  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || die "run as root: curl -fsSL $base/vps-setup.sh | bash"
    run=(sudo)
  fi
  if (: </dev/tty) 2>/dev/null; then tty=/dev/tty; fi
  dir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" EXIT
  step "Downloading vps-setup.sh from $base"
  curl -fsSL "$base/vps-setup.sh" -o "$dir/vps-setup.sh" || die "download failed: $base/vps-setup.sh"

  for arg in "${args[@]}"; do
    if [[ $arg == --config || $arg == -c ]]; then has_config=1; fi
  done
  if ((has_config == 0)); then
    step "Settings (saved to $CONFIG_PATH; change them later with: sudo vps init)"
    ask_setting USER_NAME "Your login name on the server" "" required
    ask_setting SSH_PUBLIC_KEY "SSH public key (empty = the key you logged in with)"
    ask_setting SSH_PORT "SSH port" 22
    ask_setting TIMEZONE "Timezone" UTC
    ask_setting ACME_EMAIL "E-mail for Let's Encrypt" "" required
    ask_setting GITHUB_OWNER "GitHub user or org that may deploy (ghcr.io/<owner>/*)" "" required
    # Every setting that is set (asked above, or exported) goes into the file;
    # the rest keep their defaults.
    for key in "${CONFIG_KEYS[@]}"; do
      if [[ ! -v $key ]]; then continue; fi
      [[ ${!key} != *[$'"\n']* ]] || die "$key cannot contain a double quote or a newline"
      printf '%s="%s"\n' "$key" "${!key}"
    done >"$dir/vps.conf"
    args+=(--config "$dir/vps.conf")
  fi

  "${run[@]}" bash "$dir/vps-setup.sh" init "${args[@]}" <"$tty" || rc=$?
  exit "$rc"
}

if [[ -z ${BASH_SOURCE[0]-} ]]; then
  bootstrap_from_pipe "$@"
elif [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi