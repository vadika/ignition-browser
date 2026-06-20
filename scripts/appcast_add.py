#!/usr/bin/env python3
"""Prepend a signed Sparkle <item> to an appcast feed. Idempotent on shortVersion.
Usage: appcast_add.py <appcast.xml> <shortVersion> <build> <url> <edSignature> <length>"""
import sys, datetime
from xml.dom import minidom

def main(path, short, build, url, sig, length):
    doc = minidom.parse(path)
    channel = doc.getElementsByTagName("channel")[0]
    # Idempotent: skip if an item already advertises this shortVersionString.
    for enc in doc.getElementsByTagName("enclosure"):
        if enc.getAttribute("sparkle:shortVersionString") == short:
            return
    item = doc.createElement("item")
    title = doc.createElement("title")
    title.appendChild(doc.createTextNode(f"Ignition Browser {short}"))
    item.appendChild(title)
    pub = doc.createElement("pubDate")
    pub.appendChild(doc.createTextNode(
        datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")))
    item.appendChild(pub)
    minver = doc.createElement("sparkle:minimumSystemVersion")
    minver.appendChild(doc.createTextNode("14.0"))
    item.appendChild(minver)
    enc = doc.createElement("enclosure")
    enc.setAttribute("url", url)
    enc.setAttribute("sparkle:version", build)
    enc.setAttribute("sparkle:shortVersionString", short)
    enc.setAttribute("sparkle:edSignature", sig)
    enc.setAttribute("length", length)
    enc.setAttribute("type", "application/octet-stream")
    item.appendChild(enc)
    existing = channel.getElementsByTagName("item")
    if existing:
        channel.insertBefore(item, existing[0])
    else:
        channel.appendChild(item)
    with open(path, "w", encoding="utf-8") as f:
        f.write(doc.toxml())

if __name__ == "__main__":
    main(*sys.argv[1:7])
