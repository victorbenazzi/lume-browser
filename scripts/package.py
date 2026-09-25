"""Assemble the local app with versioned framework, helpers and ad-hoc signatures."""
from pathlib import Path
import json
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
app = root / "dist/Lume.app"
contents = app / "Contents"
frameworks = contents / "Frameworks"
resources = contents / "Resources"
app_icon = root / "resources/AppIcon/Lume.icns"
if not app_icon.is_file() or app_icon.read_bytes()[:4] != b"icns":
    raise SystemExit("Missing macOS icon: resources/AppIcon/Lume.icns")
for path in (frameworks, resources, contents / "MacOS"):
    path.mkdir(parents=True, exist_ok=True)

def plist(path, content):
    path.write_bytes(plistlib.dumps(content))

def install_executable(source, destination):
    # A new file, not a rewrite: a running Lume keeps executing the one it opened.
    destination.unlink(missing_ok=True)
    shutil.copy2(source, destination)

def sign(path, entitlements=False):
    args = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
    if entitlements:
        args += ["--options", "runtime", "--entitlements", str(root / "resources/entitlements.plist")]
    subprocess.run(args + [str(path)], check=True, stdout=subprocess.DEVNULL)

cef = frameworks / "Chromium Embedded Framework.framework"
version = json.loads((root / "cef-version.json").read_text())["version"]
marker = root / ".build/packaged-cef-version"
if not cef.exists() or not marker.exists() or marker.read_text() != version:
    if cef.exists():
        shutil.rmtree(cef)
    actual = cef / "Versions/A"
    actual.parent.mkdir(parents=True)
    subprocess.run(["ditto", str(root / "vendor/cef/Release/Chromium Embedded Framework.framework"), str(actual)], check=True)
    (cef / "Versions/Current").symlink_to("A")
    for name in ("Chromium Embedded Framework", "Libraries", "Resources"):
        (cef / name).symlink_to("Versions/Current/" + name)
    for library in (actual / "Libraries").glob("*.dylib"):
        sign(library)
    sign(cef)
    marker.write_text(version)

for suffix, identifier in [("", ""), (" (Alerts)", ".alerts"), (" (GPU)", ".gpu"),
                           (" (Plugin)", ".plugin"), (" (Renderer)", ".renderer")]:
    name = "Lume Helper" + suffix
    helper = frameworks / (name + ".app")
    binary = helper / "Contents/MacOS" / name
    binary.parent.mkdir(parents=True, exist_ok=True)
    install_executable(root / ".build/LumeHelper", binary)
    helper_resources = helper / "Contents/Resources"
    helper_resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(app_icon, helper_resources / "Lume.icns")
    plist(helper / "Contents/Info.plist", {
        "CFBundleExecutable": name, "CFBundleIdentifier": "app.lume.browser.helper" + identifier,
        "CFBundleName": name, "CFBundlePackageType": "APPL", "CFBundleVersion": "3",
        "CFBundleIconFile": "Lume.icns",
        "LSUIElement": True, "LSMinimumSystemVersion": "14.0",
        "NSCameraUsageDescription": "Sites autorizados por você podem usar a câmera para chamadas de vídeo.",
        "NSMicrophoneUsageDescription": "Sites autorizados por você podem usar o microfone para chamadas e gravações.",
    })
    sign(helper, True)

install_executable(root / ".build/Lume", contents / "MacOS/Lume")
shutil.copy2(app_icon, resources / "Lume.icns")
shutil.copy2(root / "vendor/cef/LICENSE.txt", resources / "CEF-LICENSE.txt")
shutil.copy2(root / "cef-version.json", resources / "cef-version.json")
plist(contents / "Info.plist", {
    "CFBundleExecutable": "Lume", "CFBundleName": "Lume", "CFBundleDisplayName": "Lume",
    "CFBundleIdentifier": "app.lume.browser", "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.2.1", "CFBundleVersion": "3", "LSMinimumSystemVersion": "14.0",
    "CFBundleIconFile": "Lume.icns",
    "NSHighResolutionCapable": True, "NSSupportsAutomaticGraphicsSwitching": True,
    "NSPrincipalClass": "LBApplication", "NSHumanReadableCopyright": "Lume experimental browser",
    "NSCameraUsageDescription": "Sites autorizados por você podem usar a câmera para chamadas de vídeo.",
    "NSMicrophoneUsageDescription": "Sites autorizados por você podem usar o microfone para chamadas e gravações.",
    "NSLocationUsageDescription": "Sites autorizados por você podem ver sua localização, como em mapas e entregas.",
    "NSLocationWhenInUseUsageDescription": "Sites autorizados por você podem ver sua localização, como em mapas e entregas.",
})
sign(app, True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
