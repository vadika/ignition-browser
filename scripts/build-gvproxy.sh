#!/usr/bin/env bash
# Build gvproxy with the ignition-browser egress filter.
#
# The disposable browser gets NAT egress to the PUBLIC internet only — it must
# never reach the host or the host's LAN. Upstream gvproxy (gvisor-tap-vsock) has
# no egress ACL, so we apply patches/0001-egress-lan-filter.patch, which refuses to
# dial private / host-local / loopback / link-local / CGNAT destinations at the two
# outbound NAT chokepoints (pkg/services/forwarder/{tcp,udp}.go). Verified live:
# guest reaches example.com but is refused 192.168.x/10.x/etc. See DECISIONS.md.
#
# usage: scripts/build-gvproxy.sh   (output: dist/gvproxy)
set -euo pipefail

TAG="${GVTV_TAG:-v0.8.9}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$ROOT/patches/0001-egress-lan-filter.patch"
OUT="${OUT:-$ROOT/dist/gvproxy}"
SRC="$(mktemp -d)/gvisor-tap-vsock"

[ -f "$PATCH" ] || { echo "missing patch: $PATCH" >&2; exit 1; }
command -v go >/dev/null || { echo "go toolchain required" >&2; exit 1; }

git clone -q --depth 1 --branch "$TAG" https://github.com/containers/gvisor-tap-vsock "$SRC"
git -C "$SRC" apply "$PATCH"
( cd "$SRC" && go test ./pkg/services/forwarder/ -run TestBlockedEgress )  # filter unit check
mkdir -p "$(dirname "$OUT")"
( cd "$SRC" && go build -o "$OUT" ./cmd/gvproxy )
rm -rf "$(dirname "$SRC")"
echo "built filtered gvproxy ($TAG + egress filter) -> $OUT"
