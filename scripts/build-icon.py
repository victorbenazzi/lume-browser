#!/usr/bin/env python3
"""Export the editable Apple icon and generate the checked-in macOS ICNS."""
from pathlib import Path
import argparse
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--ictool", type=Path, help="Path to Icon Composer's ictool executable")
args = parser.parse_args()
candidates = [
    args.ictool,
    root / ".tools/Icon Composer.app/Contents/Executables/ictool",
    Path("/Applications/Icon Composer.app/Contents/Executables/ictool"),
    Path("/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"),
]
ictool = next((path for path in candidates if path is not None and path.is_file()), None)
if ictool is None:
    parser.error("Install Apple's Icon Composer, accept its license, then provide --ictool if needed.")

assets = root / "resources/AppIcon"
build = root / ".build/app-icon"
build.mkdir(parents=True, exist_ok=True)
document = assets / "Lume.icon"
# Keep exported layers byte-identical to the editable vector sources.
for name in ("body.svg", "muzzle.svg", "features.svg"):
    shutil.copy2(assets / name, document / "Assets" / name)
subprocess.run([
    str(ictool), str(document), "--export-image", "--output-file", str(build / "rendered.png"),
    "--platform", "macOS", "--rendition", "Default", "--width", "1024", "--height", "1024", "--scale", "1",
], check=True)
subprocess.run([
    "xcrun", "swift", "-module-cache-path", str(root / ".build/module-cache"),
    str(root / "scripts/build-icon.swift"), str(build / "rendered.png"), str(build),
], check=True)
subprocess.run([
    "iconutil", "-c", "icns", str(build / "Lume.iconset"), "-o", str(assets / "Lume.icns"),
], check=True)
shutil.copy2(build / "Lume.iconset/icon_512x512@2x.png", assets / "Lume-1024.png")
shutil.copy2(build / "Lume.iconset/icon_128x128@2x.png", assets / "Lume-256.png")
print(f"Generated: {assets / 'Lume.icns'}")
