#!/usr/bin/env python3
"""Generate a minimal sideload test from the existing Gecko IPA.

Keep the original full-featured IPA untouched. By default this test removes all
extensions. --keep-gecko-helper preserves the essential child-process extension
while excluding AutoFill/share/widget extensions.
"""
import argparse
import plistlib
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import zipfile


def package(source: Path, destination: Path, version: str, build: str, keep_gecko_helper: bool = False):
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
                # The Gecko content process lives in the Reynard Helper extension.
                # Keep this extension for helper diagnostics; drop UI/share extensions.
                if rel.startswith("PlugIns/"):
                    if not (keep_gecko_helper and rel.startswith("PlugIns/Reynard Helper.appex/")):
                        continue
                if (rel.startswith(("Watch/", "AppClips/", "com.apple.WatchPlaceholder/"))
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
        plist["CFBundleShortVersionString"] = version
        plist["CFBundleVersion"] = build
        with (app_dir / "Info.plist").open("wb") as f:
            plistlib.dump(plist, f, sort_keys=False)

        exe = app_dir / plist["CFBundleExecutable"]
        if not exe.is_file():
            raise ValueError("App executable missing")
        # Do not preserve restricted entitlements or stale keychain team IDs.
        # The installer must sign with its own account/certificate afterward.
        subprocess.run(["ldid", "-S", str(exe)], check=True)

        if keep_gecko_helper:
            helper_dir = app_dir / "PlugIns" / "Reynard Helper.appex"
            helper_info = helper_dir / "Info.plist"
            if not helper_info.is_file():
                raise ValueError("Original IPA lacks required Gecko child-process helper")
            with helper_info.open("rb") as f:
                helper_plist = plistlib.load(f)
            if helper_plist.get("CFBundleIdentifier") != "com.soum91.FirefoxGecko.Helper":
                raise ValueError("Unexpected Gecko child process bundle identifier")
            helper_plist["CFBundleShortVersionString"] = version
            helper_plist["CFBundleVersion"] = build
            with helper_info.open("wb") as f:
                plistlib.dump(helper_plist, f, sort_keys=False)
            helper_exe = helper_dir / helper_plist["CFBundleExecutable"]
            if not helper_exe.is_file():
                raise ValueError("Gecko helper executable is missing")
            # Previous app-store/ad-hoc entitlements are not the user's FlareStore
            # profile. The sideloader must sign BOTH main app and this helper
            # against the real provisioned Team ID.
            subprocess.run(["ldid", "-S", str(helper_exe)], check=True)

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
        info = plistlib.loads(zin.read(info_path))
        assert info["CFBundleShortVersionString"] == version
        assert info["CFBundleVersion"] == build
        extensions = [x for x in zin.namelist() if x.endswith(".appex/Info.plist")]
        if keep_gecko_helper:
            assert extensions == [app_prefix + "PlugIns/Reynard Helper.appex/Info.plist"], extensions
            helper = plistlib.loads(zin.read(extensions[0]))
            assert helper["CFBundleVersion"] == build
            assert helper["CFBundleIdentifier"] == "com.soum91.FirefoxGecko.Helper"
        else:
            assert not extensions
    print(f"Generated {destination} ({destination.stat().st_size} bytes) from {source}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("source", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--keep-gecko-helper", action="store_true",
                   help="Retain essential Gecko child-process extension; requires signer support")
    args = p.parse_args()
    package(args.source, args.output, args.version, args.build,
            keep_gecko_helper=args.keep_gecko_helper)
