import plistlib, subprocess, tempfile, os, sys

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "bump_patch.py")

def _plist(short, build=None):
    d = {"CFBundleShortVersionString": short}
    if build is not None:
        d["CFBundleVersion"] = build
    f = tempfile.NamedTemporaryFile(suffix=".plist", delete=False)
    plistlib.dump(d, f); f.close()
    return f.name

def run(path):
    out = subprocess.run([sys.executable, SCRIPT, path], capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    return out.stdout.strip()

def test_patch_increments_and_prints():
    p = _plist("0.0.20", "1")
    assert run(p) == "0.0.21"
    with open(p, "rb") as f: d = plistlib.load(f)
    assert d["CFBundleShortVersionString"] == "0.0.21"
    assert d["CFBundleVersion"] == "2"
    os.unlink(p)

def test_missing_build_defaults_to_1():
    p = _plist("1.2.3")
    assert run(p) == "1.2.4"
    with open(p, "rb") as f: d = plistlib.load(f)
    assert d["CFBundleVersion"] == "1"
    os.unlink(p)

if __name__ == "__main__":
    test_patch_increments_and_prints(); test_missing_build_defaults_to_1()
    print("OK")
