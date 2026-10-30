#!/usr/bin/env python3
"""Copy the runtimes prepared by tools/bootstrap_runtime.py into LocalShift.app.

Offline and deterministic: it never downloads, and refuses to run if the
prepared runtime does not match tools/runtime.lock.json.
"""
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = ROOT / ".runtime"
FFMPEG_DIR = ROOT / "work/vendor/ffmpeg-9.0.2"
RESOURCES = ROOT / "LocalShift.app/Contents/Resources"
LICENSES = RESOURCES / "Licenses"
LOCK_FILE = ROOT / "tools/runtime.lock.json"

# Parts of the standalone Python that LocalShift never uses.
PYTHON_SKIP_ANYWHERE = {"__pycache__", "test", "tests", "idlelib", "tkinter", "turtledemo", "ensurepip", "pip", "lib2to3"}
PYTHON_SKIP_PREFIXES = ("_tkinter", "pip-", "config-3")
PYTHON_SKIP_IN_LIB = ("tcl", "tk", "itcl", "libtcl", "libtk", "pkgconfig")


def fail(message):
    sys.exit("bundle_runtime: " + message + "\nRun: python3 tools/bootstrap_runtime.py")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_prepared():
    ready = RUNTIME / "ready.json"
    if not ready.is_file():
        fail("runtime not prepared")
    if json.loads(ready.read_text()).get("lock_sha256") != sha256(LOCK_FILE):
        fail("tools/runtime.lock.json changed since the runtime was prepared")
    if not (FFMPEG_DIR / "verification.json").is_file():
        fail("FFmpeg has not been verified")
    lock = json.loads(LOCK_FILE.read_text())
    for item in lock["ffmpeg"]:
        if sha256(FFMPEG_DIR / item["name"]) != item["sha256"]:
            fail("FFmpeg archive does not match the lock: " + item["name"])


def python_ignore(directory, names):
    directory = Path(directory)
    skipped = {n for n in names if n in PYTHON_SKIP_ANYWHERE or n.startswith(PYTHON_SKIP_PREFIXES)}
    if directory == RUNTIME / "python/lib":
        skipped |= {n for n in names if n.startswith(PYTHON_SKIP_IN_LIB)}
    if directory == RUNTIME / "python/bin":
        skipped |= {n for n in names if n not in ("python3", "python3.12")}
    return skipped


def copy_tree(source, destination, **kwargs):
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True, **kwargs)


def copy_licenses():
    LICENSES.mkdir(parents=True, exist_ok=True)
    for source, name in [("FFMPEG-LICENSE.txt", "FFmpeg-license.txt"), ("PROVIDER-NOTICE.txt", "FFmpeg-provider-notice.txt"),
                         ("verification.json", "FFmpeg-verification.json")]:
        shutil.copy2(FFMPEG_DIR / source, LICENSES / name)
    python_lib = next((RUNTIME / "python/lib").glob("python3.*"))
    shutil.copy2(python_lib / "LICENSE.txt", LICENSES / "Python-LICENSE.txt")
    for info in (python_lib / "site-packages").glob("*.dist-info"):
        for path in info.rglob("*"):
            if path.is_file() and any(word in path.name.lower() for word in ("license", "copying", "notice")):
                shutil.copy2(path, LICENSES / (info.name + "-" + path.name))
    office = RUNTIME / "LibreOffice.app/Contents/Resources"
    for path in list(office.glob("LICENSE*")) + list(office.glob("NOTICE*")) + list(office.glob("CREDITS*")):
        if path.is_file():
            shutil.copy2(path, LICENSES / ("LibreOffice-" + path.name))


def main():
    check_prepared()
    bin_dir = RESOURCES / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    for name in ("ffmpeg", "ffprobe"):
        shutil.copy2(FFMPEG_DIR / name, bin_dir / name)
        (bin_dir / name).chmod(0o755)
    copy_tree(RUNTIME / "python", RESOURCES / "Python", ignore=python_ignore)
    (bin_dir / "python3").unlink(missing_ok=True)
    (bin_dir / "python3").symlink_to("../Python/bin/python3")
    copy_tree(RUNTIME / "LibreOffice.app", RESOURCES / "OfficeRuntime/LibreOffice.app")
    copy_licenses()
    manifest = {"lock_sha256": sha256(LOCK_FILE)}
    (RESOURCES / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    # Smoke check: the bundled Python must import every module office-helper.py needs.
    subprocess.run([str(bin_dir / "python3"), "-I", "-c", "import docx, openpyxl, PIL, reportlab, pypdf, lxml"],
                   check=True, env={"PYTHONDONTWRITEBYTECODE": "1"})
    print("bundled runtime from", RUNTIME)


if __name__ == "__main__":
    main()
