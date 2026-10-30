#!/usr/bin/env python3
"""Download and prepare the pinned third-party runtimes into .runtime/.

Every download is checked against tools/runtime.lock.json. The result is what
tools/bundle_runtime.py copies into LocalShift.app. Run on an Apple silicon Mac:

    python3 tools/bootstrap_runtime.py
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / "tools/runtime.lock.json").read_text())
RUNTIME = ROOT / ".runtime"
DOWNLOADS = RUNTIME / "downloads"
FFMPEG_DIR = ROOT / "work/vendor/ffmpeg-9.0.2"
WEBP_DIR = ROOT / "work/vendor/webp13"


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(item):
    """Return a verified local copy of a lock entry, downloading only when needed."""
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    path = DOWNLOADS / item["name"]
    if path.is_file() and sha256(path) == item["sha256"]:
        return path
    print("download", item["name"], flush=True)
    partial = path.with_suffix(path.suffix + ".part")
    # Some mirrors reject urllib's default User-Agent.
    request = urllib.request.Request(item["url"], headers={"User-Agent": "LocalShift-bootstrap/1.0"})
    with urllib.request.urlopen(request, timeout=120) as response, open(partial, "wb") as out:
        shutil.copyfileobj(response, out)
    actual = sha256(partial)
    if actual != item["sha256"]:
        partial.unlink()
        sys.exit(f"sha256 mismatch for {item['name']}: expected {item['sha256']}, got {actual}")
    partial.rename(path)
    return path


def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def prepare_ffmpeg():
    FFMPEG_DIR.mkdir(parents=True, exist_ok=True)
    for item in LOCK["ffmpeg"]:
        archive = fetch(item)
        name = item["name"][: -len(".zip")]
        shutil.copy2(archive, FFMPEG_DIR / item["name"])
        (FFMPEG_DIR / (item["name"] + ".sha256")).write_text(f"{item['sha256']}  {item['name']}\n")
        with zipfile.ZipFile(archive) as z:
            if z.namelist() != [name]:
                sys.exit(f"unexpected members in {item['name']}")
            (FFMPEG_DIR / name).write_bytes(z.read(name))
        (FFMPEG_DIR / name).chmod(0o755)
    # Checks architecture, deployment target, dependencies, encoders and real encodes.
    run(sys.executable, "-I", FFMPEG_DIR / "verify-runtime.py")


def prepare_python():
    target = RUNTIME / "python"
    if target.exists():
        shutil.rmtree(target)
    with tarfile.open(fetch(LOCK["python"])) as tar:
        # The "tar" filter rejects absolute paths and links leaving the target (Python >= 3.9.17).
        tar.extractall(RUNTIME, **({"filter": "tar"} if hasattr(tarfile, "tar_filter") else {}))
    python = target / "bin/python3"
    wheels = [fetch(item) for item in LOCK["wheels"]]
    run(python, "-m", "pip", "install", "--no-deps", "--no-index", "--no-compile", "--no-cache-dir",
        "--disable-pip-version-check", *wheels, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
    # The WebP encoder used by the Swift engine comes from the same Pillow wheel.
    site = next((target / "lib").glob("python3.*/site-packages"))
    run("/bin/bash", WEBP_DIR / "prepare.sh", site)


def prepare_libreoffice():
    target = RUNTIME / "LibreOffice.app"
    if target.exists():
        shutil.rmtree(target)
    dmg = fetch(LOCK["libreoffice"])
    with tempfile.TemporaryDirectory() as mount:
        run("/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount, dmg,
            stdout=subprocess.DEVNULL)
        try:
            run("/usr/bin/ditto", Path(mount) / "LibreOffice.app", target)
        finally:
            run("/usr/bin/hdiutil", "detach", mount, "-quiet")


def main():
    if sys.platform != "darwin":
        sys.exit("bootstrap_runtime.py must run on macOS.")
    prepare_ffmpeg()
    prepare_python()
    prepare_libreoffice()
    lock_hash = hashlib.sha256((ROOT / "tools/runtime.lock.json").read_bytes()).hexdigest()
    (RUNTIME / "ready.json").write_text(json.dumps({"lock_sha256": lock_hash}, indent=2) + "\n")
    print("runtime ready:", RUNTIME)


if __name__ == "__main__":
    main()
