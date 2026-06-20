#!/usr/bin/env python3
"""Increment the patch of CFBundleShortVersionString in a plist, bump CFBundleVersion,
and print the new short version. Stdlib-only so it runs on the Linux artemis2 runner."""
import plistlib, sys

def main(path):
    with open(path, "rb") as f:
        d = plistlib.load(f)
    major, minor, patch = d["CFBundleShortVersionString"].split(".")
    new = f"{major}.{minor}.{int(patch) + 1}"
    d["CFBundleShortVersionString"] = new
    d["CFBundleVersion"] = str(int(d.get("CFBundleVersion", "0")) + 1)
    with open(path, "wb") as f:
        plistlib.dump(d, f)
    print(new)

if __name__ == "__main__":
    main(sys.argv[1])
