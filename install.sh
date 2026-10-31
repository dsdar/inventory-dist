#!/usr/bin/env bash
# Home Inventory installer: the one public entry point.
#
#   curl -fsSL https://dsdar.github.io/inventory-dist/install.sh | sudo bash
#   curl -fsSL https://dsdar.github.io/inventory-dist/install.sh | sudo bash -s -- --channel beta
#
# Picks an infrastructure release from a channel, verifies its bootstrap script
# against the release manifest, and runs it. Any other options are passed to
# bootstrap.sh. Kept small and backward compatible: it is shared by all releases.
set -euo pipefail

DIST_URL="${INVENTORY_DIST_URL:-https://dsdar.github.io/inventory-dist}"
CHANNEL="stable"
VERSION=""
BOOTSTRAP_ARGS=()

die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --channel)  CHANNEL="${2:?}"; shift 2 ;;
    --version)  VERSION="${2:?}"; shift 2 ;;
    --dist-url) DIST_URL="${2:?}"; shift 2 ;;
    *)          BOOTSTRAP_ARGS+=("$1"); shift ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root: curl ... | sudo bash"
command -v curl >/dev/null || die "curl is required"
command -v python3 >/dev/null || die "python3 is required (included in Raspberry Pi OS)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "${DIST_URL}/channel-${CHANNEL}.json" -o "$tmp/channel.json" \
  || die "channel '${CHANNEL}' not found at ${DIST_URL} (no release published yet?)"

latest="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["infrastructure"]["latest"])' "$tmp/channel.json")"
VERSION="${VERSION:-$latest}"
printf '[install] channel %s, infrastructure %s\n' "$CHANNEL" "$VERSION"

base="${DIST_URL}/infra/${VERSION}"
curl -fsSL "${base}/manifest.json" -o "$tmp/manifest.json" || die "release ${VERSION} not found"
curl -fsSL "${base}/bootstrap.sh" -o "$tmp/bootstrap.sh" || die "bootstrap for ${VERSION} not found"

python3 - "$tmp/channel.json" "$tmp/manifest.json" "$tmp/bootstrap.sh" "$VERSION" "$latest" <<'PY'
import hashlib, json, sys
channel_path, manifest_path, bootstrap_path, version, latest = sys.argv[1:]
def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()
if version == latest:
    expected = json.load(open(channel_path))["infrastructure"]["manifest_sha256"]
    if sha(manifest_path) != expected:
        sys.exit("[install] ERROR: manifest checksum does not match the channel index")
m = json.load(open(manifest_path))
boot = next(c for c in m["components"] if c["name"] == "bootstrap")
if sha(bootstrap_path) != boot["sha256"]:
    sys.exit("[install] ERROR: bootstrap checksum does not match the manifest")
print("[install] bootstrap verified")
PY

exec bash "$tmp/bootstrap.sh" --version "$VERSION" --channel "$CHANNEL" --dist-url "$DIST_URL" "${BOOTSTRAP_ARGS[@]}"
