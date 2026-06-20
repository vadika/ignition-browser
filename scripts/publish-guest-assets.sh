#!/usr/bin/env bash
# Publish the guest assets (kernel Image + browser rootfs) to the private OCI
# registry on artemis2, tagged by the ignition commit they were built from. CI
# (release.yml) joins the tailnet and `oras pull`s this tag.
#
# Run this ON artemis2 (where the registry + freshly-built assets live) after a
# rootfs rebuild. The tag MUST match the ignition submodule pin in this repo so
# CI fetches assets that match the boot/rootfs it builds.
#
# usage (on artemis2):
#   IGN_SHA=$(git -C <ignition checkout> rev-parse --short=7 HEAD) \
#     scripts/publish-guest-assets.sh
#   # or pass the tag explicitly:
#   scripts/publish-guest-assets.sh 227987e
set -euo pipefail

REGISTRY="${REGISTRY:-127.0.0.1:5001}"          # local registry on artemis2 (push plain-http)
REPO="${REPO:-ignition-browser/guest-assets}"
OUT="${OUT:-$HOME/kbuild/out}"                   # where build-rootfs-browser.sh / build-kernel.sh land
TAG="${1:-${IGN_SHA:?pass a tag arg or set IGN_SHA (the ignition short SHA)}}"

[ -f "$OUT/Image" ] || { echo "missing $OUT/Image" >&2; exit 1; }
[ -f "$OUT/rootfs-browser.ext4" ] || { echo "missing $OUT/rootfs-browser.ext4" >&2; exit 1; }

cd "$OUT"
oras push --plain-http "$REGISTRY/$REPO:$TAG" \
  Image:application/octet-stream \
  rootfs-browser.ext4:application/octet-stream

echo "published $REPO:$TAG to $REGISTRY"
echo "CI pulls it over the tailnet at artemis2.tailc718e.ts.net:8443/$REPO:$TAG"
