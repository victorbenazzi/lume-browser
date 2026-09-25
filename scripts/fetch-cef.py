"""Fetch the pinned CEF distribution and verify the publisher checksum."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
from urllib.parse import quote

root = Path(__file__).resolve().parent.parent
lock = json.loads((root / "cef-version.json").read_text())
vendor = root / "vendor"
target = vendor / lock["archive"].removesuffix(".tar.bz2")
archive = vendor / "cef.tar.bz2"
link = vendor / "cef"
vendor.mkdir(exist_ok=True)
if not target.is_dir():
    if not archive.exists() or hashlib.sha1(archive.read_bytes()).hexdigest() != lock["sha1"]:
        partial = archive.with_suffix(".download")
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--output", str(partial),
                        lock["source"] + quote(lock["archive"])], check=True)
        if hashlib.sha1(partial.read_bytes()).hexdigest() != lock["sha1"]:
            raise SystemExit("CEF checksum mismatch. The download was not extracted.")
        partial.replace(archive)
    with tarfile.open(archive) as bundle:
        bundle.extractall(vendor, filter="data")
if link.is_symlink():
    if link.resolve() != target.resolve():
        link.unlink()
        link.symlink_to(target.name)
elif not link.exists():
    link.symlink_to(target.name)
else:
    raise SystemExit("vendor/cef is not a managed symlink; move it before bootstrap.")
print(f"CEF {lock['version']} ready (ARM64).")
