#!/usr/bin/env python3
"""Export the editable Apple icon and generate the checked-in macOS ICNS."""
from pathlib import Path
import argparse
import shutil
import subprocess
import xml.etree.ElementTree as ET

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
# Preserve the supplied mark, gradients and masks. Icon Composer supplies the
# native background shape instead of rounding an already rounded SVG twice.
ET.register_namespace("", "http://www.w3.org/2000/svg")
source = ET.parse(root / "LOGO-LUME-novo.svg").getroot()
background = next(iter(source))
if background.tag != "{http://www.w3.org/2000/svg}path" or background.get("fill") != "#F9FEFD":
    raise SystemExit("Expected the original #F9FEFD background in LOGO-LUME-novo.svg")
source.remove(background)
source.set("width", "1024")
source.set("height", "1024")
# The original rounded tile occupies about 890 units, centered at (502, 501).
# Mapping that tile to the native canvas keeps the original optical proportions.
source.set("viewBox", "57 56 890 890")
layer = assets / "logo.svg"
ET.ElementTree(source).write(layer, encoding="utf-8", xml_declaration=True)
# CoreSVG drops the source's Gaussian blur filters. Render the transparent
# layer first, then let Icon Composer apply its native material and lighting.
if shutil.which("npx") is None:
    raise SystemExit("Install Node.js with npm to render the SVG filters before Icon Composer export.")
subprocess.run([
    "npx", "--yes", "sharp-cli@6.1.0", "--input", str(layer),
    "--output", str(assets / "logo.png"), "--density", "144",
], check=True)
shutil.copy2(assets / "logo.png", document / "Assets/logo.png")
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
