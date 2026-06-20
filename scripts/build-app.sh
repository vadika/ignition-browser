#!/usr/bin/env bash
set -euo pipefail

# Build the release binary, assemble dist/IgnitionBrowser.app (bundling boot, gvproxy,
# the kernel Image, and the gzip-compressed rootfs), and deep-sign it.
# Prereqs:
#   scripts/build-boot.sh    -> vendor/ignition/target/release/boot (Developer-ID signed)
#   scripts/build-gvproxy.sh -> dist/gvproxy (egress-filtered)
#   vendor/ignition/kimage/out/{Image,rootfs-browser.ext4} present

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP="dist/IgnitionBrowser.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

# 1. Build the release binary.
swift build -c release --arch arm64

# 2. Assemble the bundle.
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

cp ".build/release/IgnitionBrowser" "$MACOS/IgnitionBrowser"
cp "Resources/Info.plist" "$CONTENTS/Info.plist"
cp "Resources/AppIcon.icns" "$RES/AppIcon.icns"

# Nested runtime binaries.
cp "vendor/ignition/target/release/boot" "$RES/boot"
cp "$REPO_ROOT/dist/gvproxy" "$RES/gvproxy"
cp "vendor/ignition/kimage/out/Image" "$RES/Image"
# Rootfs is large but mostly sparse: gzip it; FirstRun gunzips on first launch.
gzip -c "vendor/ignition/kimage/out/rootfs-browser.ext4" > "$RES/rootfs-browser.ext4.gz"

# 3. Deep-sign: nested binaries first, then the app.
if [[ -z "${DEV_ID:-}" ]]; then
    echo "error: DEV_ID is unset. Set it to your Developer ID Application identity, e.g.:" >&2
    echo "  export DEV_ID='Developer ID Application: Your Name (TEAMID)'" >&2
    exit 1
fi

# boot calls Hypervisor.framework directly, and entitlements do NOT inherit to a
# spawned child process — so the nested boot binary needs the hypervisor entitlement
# itself (the app bundle's entitlement is not enough). gvproxy is userspace, no HVF.
codesign --force --options runtime --timestamp \
    --entitlements "Resources/IgnitionBrowser.entitlements" \
    --sign "$DEV_ID" "$RES/boot"
codesign --force --options runtime --timestamp --sign "$DEV_ID" "$RES/gvproxy"

codesign --force --options runtime --timestamp \
    --entitlements "Resources/IgnitionBrowser.entitlements" \
    --sign "$DEV_ID" "$APP"

echo "built: $APP"
echo "next: scripts/notarize.sh"
