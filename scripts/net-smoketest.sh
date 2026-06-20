#!/usr/bin/env bash
# Headless proof that gvproxy (user-mode net) is wire-compatible with ignition's
# `boot --net-socket` (qemu -netdev socket protocol). No app, no GUI, no sudo.
#
# Starts gvproxy on a unix socket, boots a headless guest with its net pointed at
# that socket, and confirms the guest completes DHCP against gvproxy's gateway
# (192.168.127.1) — i.e. ethernet frames flow both ways. Result: VERIFIED on
# 2026-06-18 (guest leased 192.168.127.3). See DECISIONS.md.
#
# Prereqs:
#   - gvproxy:  go install github.com/containers/gvisor-tap-vsock/cmd/gvproxy@latest
#               (binary at $(go env GOPATH)/bin/gvproxy, or set GVPROXY=/path)
#   - boot built + signed:  scripts/build-boot.sh   (vendor/ignition)
#   - guest assets in vendor/ignition/kimage/out (Image + a rootfs that DHCPs eth0)
#
# usage: scripts/net-smoketest.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IGN="$ROOT/vendor/ignition"
GVPROXY="${GVPROXY:-$(go env GOPATH 2>/dev/null)/bin/gvproxy}"
BOOT="${BOOT:-$IGN/target/release/boot}"; [ -x "$BOOT" ] || BOOT="$IGN/target/debug/boot"
KERNEL="$IGN/kimage/out/Image"
ROOTFS="$IGN/kimage/out/rootfs-tools.ext4"

[ -x "$GVPROXY" ] || { echo "gvproxy not found at $GVPROXY (set GVPROXY=)" >&2; exit 1; }
[ -x "$BOOT" ]    || { echo "boot not built: $BOOT (run scripts/build-boot.sh)" >&2; exit 1; }
[ -f "$KERNEL" ]  || { echo "kernel missing: $KERNEL" >&2; exit 1; }
[ -f "$ROOTFS" ]  || { echo "rootfs missing: $ROOTFS" >&2; exit 1; }

sock="$(mktemp -u /tmp/gv.XXXX.sock)"
ctl="$(mktemp -u /tmp/gvctl.XXXX.sock)"
gvlog="$(mktemp)"; bootlog="$(mktemp)"
cleanup() { kill -9 "${GVPID:-}" "${BPID:-}" 2>/dev/null || true; rm -f "$sock" "$ctl"; }
trap cleanup EXIT INT TERM

"$GVPROXY" -listen "unix://$ctl" -listen-qemu "unix://$sock" -debug >"$gvlog" 2>&1 &
GVPID=$!
for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.1; done
[ -S "$sock" ] || { echo "gvproxy socket never came up" >&2; cat "$gvlog" >&2; exit 1; }

"$BOOT" --net --net-socket "$sock" --mem 1024 \
  --append "ro init=/sbin/overlay-init" "$KERNEL" "$ROOTFS" >"$bootlog" 2>&1 &
BPID=$!
sleep 30

# gvproxy logs the DHCP Ack with the leased address; that is the proof.
if grep -q "MessageType:Ack" "$gvlog" && grep -q "YourClientIP=192.168.127" "$gvlog"; then
  lease=$(grep -o "YourClientIP=192.168.127.[0-9]*" "$gvlog" | head -1)
  echo "net-smoketest PASS — guest completed DHCP over gvproxy ($lease)"
  exit 0
fi
echo "net-smoketest FAIL — no DHCP Ack seen; gvproxy log tail:" >&2
tail -20 "$gvlog" >&2
exit 1
