#!/usr/bin/env python3
"""Repackage a published Firefox Gecko IPA so Timbre loads, without compiling.

Gecko's iOS built-in validator never allowed Timbre's folder, and the
resource://android/ host Swift was later pointed at fails on iOS. FetchDock
already loads from resource://app/, so Timbre goes there too:

  * the compiled Swift literal resource://android/timbre/ becomes
    resource://app/ext/timbre/ (same 26 bytes, so the Mach-O stays intact)
  * the add-on is copied to GeckoView.framework/Frameworks/ext/timbre/
  * the stray `resource android` mapping is removed from chrome.manifest
  * GeckoViewWebExtension.sys.mjs allows exactly that URI
"""
import argparse
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

from patch_timbre_builtin import patch

OLD = b"resource://android/timbre/"
NEW = b"resource://app/ext/timbre/"
STRAY_MAP = b"resource android file:extensions/\n"
MACHO = {bytes.fromhex(m) for m in ("cffaedfe", "cefaedfe", "cafebabe", "bebafeca")}


def repair(source, output, build):
    assert len(OLD) == len(NEW)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        with zipfile.ZipFile(source) as archive:
            assert archive.testzip() is None
            archive.extractall(root)
            for entry in archive.infolist():
                path = root / entry.filename
                mode = (entry.external_attr >> 16) & 0o777
                if mode and path.exists() and not path.is_symlink():
                    path.chmod(mode)
        app = root / "Payload/Firefox.app"

        matches = []
        for candidate in app.rglob("*"):
            if not candidate.is_file() or candidate.is_symlink():
                continue
            with candidate.open("rb") as handle:
                if handle.read(4) not in MACHO:
                    continue
            data = candidate.read_bytes()
            if NEW in data:
                matches.append((candidate, data, 0))
            elif data.count(OLD):
                matches.append((candidate, data, data.count(OLD)))
        assert len(matches) == 1, f"Expected the Timbre URI in one Mach-O, found {[str(m[0]) for m in matches]}"
        binary, data, count = matches[0]
        assert count in (0, 1), f"Timbre URI appears {count} times in {binary}"
        patched_relative = str(binary.relative_to(app))
        if count:
            print(f"Pointing Timbre at {NEW.decode()} in {patched_relative}", flush=True)
            binary.write_bytes(data.replace(OLD, NEW))
            binary.chmod(0o755)
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(binary)], check=True)

        gecko = app / "Frameworks/GeckoView.framework"
        runtime = gecko / "Frameworks"
        bundled = runtime / "extensions/timbre"
        assert (bundled / "manifest.json").is_file(), "Timbre add-on missing from the IPA"
        assert (bundled / "engine.js").is_file(), "Timbre audio engine missing from the IPA"
        target = runtime / "ext/timbre"
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(bundled, target)

        manifest = runtime / "chrome.manifest"
        manifest.write_bytes(manifest.read_bytes().replace(STRAY_MAP, b""))
        patch(runtime)

        for bundle in [app, *sorted((app / "PlugIns").glob("*.appex"))]:
            path = bundle / "Info.plist"
            info = plistlib.loads(path.read_bytes())
            info["CFBundleShortVersionString"] = f"159.0.{build}"
            info["CFBundleVersion"] = str(build)
            path.write_bytes(plistlib.dumps(info, sort_keys=False))
            (bundle / info["CFBundleExecutable"]).chmod(0o755)
        for bundle in [gecko, *sorted((app / "PlugIns").glob("*.appex")), app]:
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle)], check=True)
            subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        if output.exists():
            output.unlink()
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                        str(root / "Payload"), str(output)], check=True)

    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        prefix = "Payload/Firefox.app/"
        names = set(archive.namelist())
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        assert info["CFBundleVersion"] == str(build)
        binary = archive.read(prefix + patched_relative)
        assert binary.count(NEW) == 1 and OLD not in binary
        runtime = prefix + "Frameworks/GeckoView.framework/Frameworks/"
        for name in ("manifest.json", "engine.js", "background.js", "bridge.js", "boot.js"):
            assert runtime + "ext/timbre/" + name in names, name
        assert STRAY_MAP not in archive.read(runtime + "chrome.manifest")
        js = archive.read(runtime + "modules/GeckoViewWebExtension.sys.mjs")
        assert b'uri.spec === "resource://app/ext/timbre/"' in js
    print(f"Verified repaired IPA: {output}, {output.stat().st_size} bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--build", type=int, required=True)
    args = parser.parse_args()
    repair(args.source, args.output, args.build)
