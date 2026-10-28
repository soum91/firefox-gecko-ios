#!/usr/bin/env python3
"""Repair the specific Gecko XUL dyld signing failure captured on iOS 27.

Device log, 2026-10-28:
  Library not loaded: @rpath/XUL
  .../Reynard.app/Frameworks/XUL (code signature invalid, errno=1)

XUL is an arm64 Mach-O dylib but its original packaging does not have a .dylib
extension, which can cause IPA signing tools to overlook the 226 MB binary.
Convert it to a conventionally named XUL.dylib and update the Mach-O load
commands with Apple's install_name_tool, then ad-hoc sign and verify all code.

This does NOT reproduce the user's purchased signing certificate. FlareStore
must replace ad-hoc signatures, including XUL.dylib, with the user's identity.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

OLD = "@rpath/XUL"
NEW = "@rpath/XUL.dylib"
APP = Path("Payload/Reynard.app")
MACHO_ARM64 = bytes.fromhex("cffaedfe")


def run(*cmd: str) -> None:
    print("+", " ".join(map(str, cmd)), flush=True)
    subprocess.run([str(x) for x in cmd], check=True)


def is_macho(path: Path) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    with path.open("rb") as fh:
        return fh.read(4) == MACHO_ARM64


def repair(src: Path, dest: Path, version: str, build: str) -> None:
    with tempfile.TemporaryDirectory(prefix="gecko-xul-signature-") as temp:
        stage = Path(temp)
        with zipfile.ZipFile(src) as z:
            names = z.namelist()
            if len(names) != len(set(names)) or z.testzip() is not None:
                raise ValueError("Bad IPA input: duplicate entries or damaged archive")
            if any(n.startswith("/") or ".." in Path(n).parts for n in names):
                raise ValueError("Unsafe IPA paths")
            z.extractall(stage)

        app = stage / APP
        info_path = app / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        if info.get("CFBundleIdentifier") != "com.soum91.FirefoxGecko":
            raise ValueError("Expected the Reynard-based Gecko diagnostic, not original Firefox")
        if info.get("CFBundleVersion") != "78953":
            raise ValueError("Expected the 159.0.4 / 78953 Gecko helper diagnostic")
        for key in ("UISupportedDevices", "WKCompanionAppBundleIdentifier", "WKWatchKitApp"):
            info.pop(key, None)
        info["CFBundleShortVersionString"] = version
        info["CFBundleVersion"] = build
        info_path.write_bytes(plistlib.dumps(info, sort_keys=False))

        helper = app / "PlugIns" / "Reynard Helper.appex"
        helper_info_path = helper / "Info.plist"
        helper_info = plistlib.loads(helper_info_path.read_bytes())
        if helper_info.get("CFBundleIdentifier") != "com.soum91.FirefoxGecko.Helper":
            raise ValueError("Gecko helper bundle ID mismatch")
        helper_info["CFBundleShortVersionString"] = version
        helper_info["CFBundleVersion"] = build
        helper_info_path.write_bytes(plistlib.dumps(helper_info, sort_keys=False))

        old_xul = app / "Frameworks" / "XUL"
        new_xul = app / "Frameworks" / "XUL.dylib"
        if not is_macho(old_xul) or new_xul.exists():
            raise ValueError("Expected an unconverted arm64 Gecko XUL Mach-O")
        old_xul.rename(new_xul)

        # Each Mach-O can contain an LC_LOAD_DYLIB for the original @rpath/XUL.
        # Rewriting every dependency avoids a partly converted dependency graph.
        machos = [p for p in sorted(app.rglob("*")) if is_macho(p)]
        rewritten = []
        for file in machos:
            with file.open("rb") as f:
                first = f.read(32768)
            if OLD.encode("ascii") + b"\0" in first:
                run("xcrun", "install_name_tool", "-change", OLD, NEW, str(file))
                rewritten.append(str(file.relative_to(app)))
        run("xcrun", "install_name_tool", "-id", NEW, str(new_xul))
        if not any(p.endswith("/GeckoView") for p in rewritten):
            raise ValueError("GeckoView dependency was not patched")
        if info["CFBundleExecutable"] not in rewritten:
            raise ValueError("Main executable dependency was not patched")
        if not any(p.endswith("Reynard Helper") for p in rewritten):
            raise ValueError("Gecko helper dependency was not patched")

        # Ad-hoc signing here is a packaging consistency check. The actual
        # FlareStore signing identity MUST sign all nested code on the device.
        # Sign leaf Mach-Os first, then nested code bundles and finally the app.
        for file in machos:
            run("codesign", "--force", "--sign", "-", "--timestamp=none", str(file))
        framework = app / "Frameworks" / "GeckoView.framework"
        run("codesign", "--force", "--sign", "-", "--timestamp=none", str(framework))
        run("codesign", "--force", "--sign", "-", "--timestamp=none", str(helper))
        run("codesign", "--force", "--sign", "-", "--timestamp=none", str(app))

        # These are required tests for the exact dyld error in the uploaded log.
        for file in [app / info["CFBundleExecutable"], new_xul,
                     framework / "GeckoView", helper / helper_info["CFBundleExecutable"]]:
            run("codesign", "--verify", "--strict", "--verbose=2", str(file))
        run("xcrun", "otool", "-L", str(app / info["CFBundleExecutable"]))
        assert not old_xul.exists()
        assert new_xul.is_file()
        for file in machos:
            with file.open("rb") as f:
                head = f.read(32768)
            if OLD.encode() + b"\0" in head:
                raise ValueError(f"Unchanged XUL load command: {file}")

        dest.parent.mkdir(parents=True, exist_ok=True)
        # ZIP remembers executable bits. No code object is renamed after signing.
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
            str(stage / "Payload"), str(dest))
        with zipfile.ZipFile(dest) as z:
            if z.testzip() is not None:
                raise ValueError("Result ZIP validation failed")
            files = z.namelist()
            prefix = "Payload/Reynard.app/"
            assert prefix + "Frameworks/XUL.dylib" in files
            assert prefix + "Frameworks/XUL" not in files
            assert prefix + "PlugIns/Reynard Helper.appex/Info.plist" in files
            actual = plistlib.loads(z.read(prefix + "Info.plist"))
            assert actual["CFBundleVersion"] == build
        print(f"FIXED: {dest} ({dest.stat().st_size} bytes); "
              f"rewrote {len(rewritten)} binary dependencies; all local signatures verified")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--version", default="159.0.5")
    parser.add_argument("--build", default="78954")
    args = parser.parse_args()
    repair(args.source, args.output, args.version, args.build)
