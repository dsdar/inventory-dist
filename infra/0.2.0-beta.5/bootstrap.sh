#!/usr/bin/env bash
# Home Inventory bootstrap: turns a freshly imaged Raspberry Pi into a provisioned node.
#
# Downloads an infrastructure release (manifest + Ansible bundle) from the public
# distribution site, verifies it, installs Ansible, and runs provisioning locally.
# Normally started by install.sh. Safe to re-run: provisioning is idempotent.
#
# Usage (as root):
#   bootstrap.sh [--version X.Y.Z] [--channel stable|beta] [--dist-url URL]
#                [--registry-user U --registry-token T]
#   bootstrap.sh --resume     (used by systemd after the OS-update reboot)
set -euo pipefail

DIST_URL="${INVENTORY_DIST_URL:-https://dsdar.github.io/inventory-dist}"
CHANNEL="stable"
VERSION=""
REGISTRY_USER="${INVENTORY_REGISTRY_USER:-}"
REGISTRY_TOKEN="${INVENTORY_REGISTRY_TOKEN:-}"

ETC_DIR=/etc/inventory
STATE_DIR=/var/lib/inventory
INFRA_DIR=/opt/inventory/infra
LOG=/var/log/inventory-bootstrap.log

# Continuing after the OS-update reboot (see "Operating system update" below).
RESUME_DIR=/var/lib/inventory/bootstrap-resume
RESUME_UNIT=/etc/systemd/system/inventory-bootstrap-resume.service
RESUMED=0
if [ "${1:-}" = "--resume" ]; then
  RESUMED=1
  [ -f "$RESUME_DIR/args" ] || { echo "[bootstrap] ERROR: nothing to resume" >&2; exit 1; }
  # The original arguments, saved with printf %q before the reboot.
  eval "set -- $(cat "$RESUME_DIR/args")"
fi
ORIG_ARGS=("$@")

usage() {
  cat <<'EOF'
Home Inventory bootstrap

Options:
  --version X.Y.Z          Infrastructure version (default: latest in the channel)
  --channel NAME           Update channel: stable (default) or beta
  --dist-url URL           Distribution site (default: https://dsdar.github.io/inventory-dist)
  --registry-user USER     Only if container images are private (or INVENTORY_REGISTRY_USER)
  --registry-token TOKEN   Token with read:packages (or INVENTORY_REGISTRY_TOKEN)
  -h, --help               Show this help
EOF
}

log()  { printf '[bootstrap] %s\n' "$*"; }
die()  { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

# Retry downloads: right after boot the network can be up before name lookups work.
fetch() { curl -fsSL --connect-timeout 15 --retry 5 --retry-delay 5 --retry-all-errors "$@"; }

# Wait (up to 2 minutes) until the distribution site's name resolves.
wait_for_network() {
  local host="${DIST_URL#*://}"
  host="${host%%/*}"
  local i
  for i in $(seq 1 24); do
    getent hosts "$host" >/dev/null && return 0
    [ "$i" -eq 1 ] && log "waiting for the network (looking up $host)"
    sleep 5
  done
  die "no network: can't look up $host. Check the Wi-Fi or cable, then run the install again"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)        VERSION="${2:?}"; shift 2 ;;
    --channel)        CHANNEL="${2:?}"; shift 2 ;;
    --dist-url)       DIST_URL="${2:?}"; shift 2 ;;
    --registry-user)  REGISTRY_USER="${2:?}"; shift 2 ;;
    --registry-token) REGISTRY_TOKEN="${2:?}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                usage; die "unknown option: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (use sudo)"
case "$CHANNEL" in stable|beta) ;; *) die "unknown channel: $CHANNEL" ;; esac

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
log "started $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- Platform checks (full support check happens against the manifest below) ---

arch="$(uname -m)"
[ "$arch" = "aarch64" ] || die "64-bit Raspberry Pi OS required (found $arch)"

model_name="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
case "$model_name" in
  *"Raspberry Pi 4 Model B"*)      model="pi4b" ;;
  *"Raspberry Pi 3 Model B Plus"*) model="pi3b+" ;;
  *"Raspberry Pi 3 Model B"*)      model="pi3b" ;;
  *)                               die "unsupported hardware: ${model_name:-unknown}" ;;
esac

# Read os-release in a subshell: it defines its own VERSION, which would
# overwrite the infrastructure version this script installs.
# shellcheck disable=SC1091
codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")"
# shellcheck disable=SC1091
os_name="$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
mem_mb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
log "hardware: $model_name ($model, ${mem_mb} MB), OS: $os_name"

# --- Operating system update (reboots once if needed, then continues by itself) ---

wait_for_network

export DEBIAN_FRONTEND=noninteractive
log "updating the operating system (several minutes on a Pi 3)"
apt-get -o Acquire::Retries=5 update -qq
apt-get -y -qq -o Acquire::Retries=5 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
  full-upgrade >/dev/null

if [ -f /var/run/reboot-required ]; then
  if [ "$RESUMED" -eq 1 ]; then
    log "an update still asks for a reboot; continuing, it will apply at the next restart"
  else
    log "the update needs a restart: the Pi will reboot and continue on its own"
    mkdir -p "$RESUME_DIR"
    chmod 0700 "$RESUME_DIR"
    cp "${BASH_SOURCE[0]}" "$RESUME_DIR/bootstrap.sh"
    # Root-only: the arguments may include a registry token.
    ( umask 077; printf '%q ' "${ORIG_ARGS[@]}" > "$RESUME_DIR/args" )
    cat > "$RESUME_UNIT" <<EOF
[Unit]
Description=Home Inventory bootstrap (continues after the OS update reboot)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $RESUME_DIR/bootstrap.sh --resume
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable inventory-bootstrap-resume.service >/dev/null 2>&1
    log "rebooting now. After it restarts, follow progress with:  sudo tail -f $LOG"
    systemctl reboot
    exit 0
  fi
fi

# --- Prerequisites ---

log "installing prerequisites"
apt-get install -y -qq -o Acquire::Retries=5 curl ca-certificates python3 python3-apt ansible-core >/dev/null

# --- Find and download the release ---

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ -z "$VERSION" ]; then
  fetch "${DIST_URL}/channel-${CHANNEL}.json" -o "$tmp/channel.json" \
    || die "channel '${CHANNEL}' not found at ${DIST_URL}"
  VERSION="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["infrastructure"]["latest"])' "$tmp/channel.json")"
fi
log "infrastructure release: $VERSION (channel $CHANNEL)"

base="${DIST_URL}/infra/${VERSION}"
log "downloading manifest and Ansible bundle"
fetch "${base}/manifest.json" -o "$tmp/manifest.json" || die "release ${VERSION} not found at ${DIST_URL}"
fetch "${base}/ansible-bundle.tar.gz" -o "$tmp/ansible-bundle.tar.gz" || die "Ansible bundle for ${VERSION} not found"

# --- Verify against the manifest ---

python3 - "$tmp/manifest.json" "$tmp/ansible-bundle.tar.gz" "$VERSION" "$model" "$codename" <<'PY'
import hashlib, json, sys
manifest_path, bundle_path, version, model, codename = sys.argv[1:]
m = json.load(open(manifest_path))
def fail(msg):
    print(f"[bootstrap] ERROR: {msg}", file=sys.stderr); sys.exit(1)
if m.get("project") != "infrastructure" or m.get("version") != version:
    fail(f"manifest is for {m.get('project')} {m.get('version')}, expected infrastructure {version}")
bundle = next((c for c in m["components"] if c["name"] == "ansible-bundle"), None)
if bundle is None:
    fail("manifest has no ansible-bundle component")
digest = hashlib.sha256(open(bundle_path, "rb").read()).hexdigest()
if digest != bundle["sha256"]:
    fail("Ansible bundle checksum does not match the manifest")
if model not in m["supports"]["hardware"]:
    fail(f"this release does not support {model}")
if codename not in [o["codename"] for o in m["supports"]["os"]]:
    fail(f"this release does not support OS release '{codename}'")
print("[bootstrap] manifest verified: checksum ok, hardware and OS supported")
PY

# --- Install the release ---

release_dir="${INFRA_DIR}/${VERSION}"
mkdir -p "$release_dir" "$ETC_DIR" "$STATE_DIR"
chmod 0755 "$ETC_DIR" "$STATE_DIR"
rm -rf "${release_dir:?}/ansible"
tar -xzf "$tmp/ansible-bundle.tar.gz" -C "$release_dir"
cp "$tmp/manifest.json" "$release_dir/manifest.json"
ln -sfn "$release_dir" "${INFRA_DIR}/current"

# Where this node gets updates from (read by update checks from Milestone 2).
python3 -c 'import json, sys; json.dump({"channel": sys.argv[1], "dist_url": sys.argv[2]}, open(sys.argv[3], "w"), indent=2)' \
  "$CHANNEL" "$DIST_URL" "${ETC_DIR}/updates.json"

# Registry credentials are only needed if images are private. Root-only.
if [ -n "$REGISTRY_TOKEN" ]; then
  [ -n "$REGISTRY_USER" ] || die "--registry-user is required with --registry-token"
  umask 077
  python3 -c 'import json, sys; json.dump({"registry": "ghcr.io", "user": sys.argv[1], "token": sys.argv[2]}, open(sys.argv[3], "w"))' \
    "$REGISTRY_USER" "$REGISTRY_TOKEN" "${ETC_DIR}/registry-auth.json"
  umask 022
fi

# --- Provision ---

log "running Ansible provisioning"
cd "${release_dir}/ansible"
ansible-playbook -i localhost, -c local site.yml -e "manifest_path=${release_dir}/manifest.json"

# Finished: remove the after-reboot step, if one was set up. (If provisioning
# failed above, it stays, and tries again at the next boot.)
if [ -f "$RESUME_UNIT" ]; then
  systemctl disable inventory-bootstrap-resume.service >/dev/null 2>&1 || true
  rm -f "$RESUME_UNIT"
  rm -rf "$RESUME_DIR"
  systemctl daemon-reload
fi

log "done. Check with: inventoryctl version   and   inventoryctl health"
