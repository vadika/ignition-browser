import subprocess, tempfile, os, sys
from xml.dom import minidom

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "appcast_add.py")
SEED = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><title>Ignition Browser</title></channel>
</rss>"""

def seed():
    f = tempfile.NamedTemporaryFile(suffix=".xml", delete=False, mode="w")
    f.write(SEED); f.close(); return f.name

def add(path, ver, build, url, sig, length):
    r = subprocess.run([sys.executable, SCRIPT, path, ver, build, url, sig, length],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr

def test_item_added_with_fields():
    p = seed()
    add(p, "0.0.21", "2", "https://ex/IgnitionBrowser.app.zip", "SIGabc==", "12345")
    doc = minidom.parse(p)
    items = doc.getElementsByTagName("item")
    assert len(items) == 1
    enc = items[0].getElementsByTagName("enclosure")[0]
    assert enc.getAttribute("url") == "https://ex/IgnitionBrowser.app.zip"
    assert enc.getAttribute("sparkle:version") == "2"
    assert enc.getAttribute("sparkle:shortVersionString") == "0.0.21"
    assert enc.getAttribute("sparkle:edSignature") == "SIGabc=="
    assert enc.getAttribute("length") == "12345"
    assert enc.getAttribute("type") == "application/octet-stream"
    item = items[0]
    assert item.getElementsByTagName("title")[0].firstChild.data == "Ignition Browser 0.0.21"
    assert item.getElementsByTagName("pubDate")  # present
    mv = item.getElementsByTagName("sparkle:minimumSystemVersion")[0]
    assert mv.firstChild.data == "14.0"
    os.unlink(p)

def test_idempotent_on_version():
    p = seed()
    add(p, "0.0.21", "2", "https://ex/a.zip", "SIG==", "1")
    add(p, "0.0.21", "2", "https://ex/a.zip", "SIG==", "1")
    assert len(minidom.parse(p).getElementsByTagName("item")) == 1  # not duplicated
    os.unlink(p)

def test_keeps_encoding_declaration():
    p = seed()
    add(p, "0.0.21", "2", "https://ex/a.zip", "SIG==", "1")
    head = open(p, encoding="utf-8").read(60)
    assert "encoding=\"utf-8\"" in head, head
    os.unlink(p)

if __name__ == "__main__":
    test_item_added_with_fields(); test_idempotent_on_version()
    test_keeps_encoding_declaration()
    print("OK")
