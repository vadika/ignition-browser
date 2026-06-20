#!/usr/bin/env bash
set -euo pipefail

# Notarize + staple the built app. Run after scripts/build-app.sh.
#
# Credentials: CI sets NOTARY_KEY (path to the App Store Connect API .p8) +
# NOTARY_KEY_ID + NOTARY_ISSUER. Local runs can instead set NOTARY_PROFILE, a
# keychain profile stored once via:
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#     --apple-id <id> --team-id <TEAMID> --password <app-specific-password>

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP="dist/IgnitionBrowser.app"
ZIP="dist/IgnitionBrowser.app.zip"

# Submission zip (notarytool needs a zip; the staple goes on the .app afterward).
SUBMIT_ZIP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/IgnitionBrowser.submit.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

# CI: App Store Connect API key (NOTARY_KEY = path to the .p8). Local: a stored
# keychain profile (NOTARY_PROFILE).
if [[ -n "${NOTARY_KEY:-}" ]]; then
    xcrun notarytool submit "$SUBMIT_ZIP" \
        --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
else
    echo "error: set NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER (CI) or NOTARY_PROFILE (local)." >&2
    exit 1
fi

# Staple the ticket onto the .app, THEN (re)zip the STAPLED app as the release
# asset — so the distributed zip validates offline without an online notarization
# check. (The earlier zip was pre-staple.)
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "notarized + stapled: $APP -> $ZIP"
