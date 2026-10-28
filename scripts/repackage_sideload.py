#!/usr/bin/env python3
"""Generate a minimal sideload test from the existing Gecko IPA.

Keep the original full-featured IPA untouched. This test intentionally removes
all app extensions to isolate extension provisioning and entitlement failures.
"""
import argparse
import plistlib
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import zipfile


def package(source: Path, destination: Path):
    with tempfile.TemporaryDirectory(prefix="ff-gecko-repair-") as directory:
        root = Path(directory)
        with zipfile.ZipFile(source) as zin:
            entries = zin.infolist()
            info_paths = [
                n.filename for n in entries if n.filename.startswith("Payload/")
                and n.filename.count("/") == 2
                and n.filename.endswith(".app/Info.plist")
            ]
            if len(info_paths) != 1 or len({x.filename for x in entries}) != len(entries):
                raise ValueError("Expected exactly one app without duplicate IPA members")
            info_path = info_paths[0]
            app_prefix = info_path[:-len("Info.plist")]
            for item in entries:
                path = item.filename
                if not path.startswith(app_prefix) or path.startswith("/"):
                    continue
                if ".." in Path(path).parts:
                    raise ValueError(f"Unsafe archive member: {path}")
                rel = path[len(app_prefix):]
                if (rel.startswith(("PlugIns/", "Watch/", "AppClips/", "com.apple.WatchPlaceholder/"))
                        or "/_CodeSignature/" in path
                        or "/SC_Info/" in path
                        or path.endswith("embedded.mobileprovision")):
                    continue
                dest = root / path
                if item.is_dir():
                    dest.mkdir(parents=True, exist_ok=True)
                    continue
                dest.parent.mkdir(parents=True, exist_ok=True)
                with zin.open(item) as src, dest.open("wb") as dst:
                    shutil.copyfileobj(src, dst)
                mode = (item.external_attr >> 16) & 0o777
                if mode:
                    dest.chmod(mode)

        app_dir = root / app_prefix
        with (app_dir / "Info.plist").open("rb") as f:
            plist = plistlib.load(f)
        if plist.get("CFBundleIdentifier") != "com.soum91.FirefoxGecko":
            raise ValueError(f"Unexpected app bundle ID: {plist.get('CFBundleIdentifier')}")
        for key in ("UISupportedDevices", "WKCompanionAppBundleIdentifier", "WKWatchKitApp", "NSExtension"):
            plist.pop(key, None)
        with (app_dir / "Info.plist").open("wb") as f:
            plistlib.dump(plist, f, sort_keys=False)

        exe = app_dir / plist["CFBundleExecutable"]
        if not exe.is_file():
            raise ValueError("App executable missing")
        # Do not preserve restricted entitlements or stale keychain team IDs.
        # The installer must sign with its own account/certificate afterward.
        subprocess.run(["ldid", "-S", str(exe)], check=True)

        destination.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as zout:
            for file in sorted((root / "Payload").rglob("*")):
                if not file.is_file():
                    continue
                path = file.relative_to(root).as_posix()
                item = zipfile.ZipInfo(path)
                item.create_system = 3
                item.external_attr = (stat.S_IFREG | stat.S_IMODE(file.stat().st_mode)) << 16
                item.compress_type = zipfile.ZIP_DEFLATED
                with file.open("rb") as src, zout.open(item, "w", force_zip64=True) as dst:
                    shutil.copyfileobj(src, dst)

    with zipfile.ZipFile(destination) as zin:
        assert zin.testzip() is None, "Corrupt IPA member"
        assert zin.read(info_path)
        assert not any("/PlugIns/" in name for name in zin.namelist())
    print(f"Generated {destination} ({destination.stat().st_size} bytes) from {source}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("source", type=Path)
    p.add_argument("output", type=Path)
    args = p.parse_args()
    package(args.source, args.output)
