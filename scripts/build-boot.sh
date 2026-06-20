#!/usr/bin/env bash
set -euo pipefail

# Build the pinned ignition `boot` binary from the submodule and Developer-ID sign it
# for bundling. The hypervisor entitlement is applied to the .app, but the nested boot
# binary must itself be Developer-ID signed (NOT adhoc) so notarization/hardened-runtime
# accept it.
#
# NOTE: verify on a SECOND machine that boot actually gets HVF access through the app's
# com.apple.security.hypervisor entitlement — adhoc/dev-only signing can pass locally
# (the kernel grants HVF to the developer's own machine) yet fail elsewhere.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/vendor/ignition"

cargo build --release -p ignition-spike --bin boot

BOOT_BIN="$REPO_ROOT/vendor/ignition/target/release/boot"

if [[ -z "${DEV_ID:-}" ]]; then
    echo "error: DEV_ID is unset. Set it to your Developer ID Application identity, e.g.:" >&2
    echo "  export DEV_ID='Developer ID Application: Your Name (TEAMID)'" >&2
    exit 1
fi

codesign --force --options runtime --timestamp \
    --sign "$DEV_ID" "$BOOT_BIN"

echo "built + signed: $BOOT_BIN"
