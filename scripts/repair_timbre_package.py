#!/usr/bin/env python3
"""Repair build 48's bundled extension URI without recompiling native code."""
import argparse
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
from patch_timbre_builtin import patch
from pathlib import Path

OLD = b"resource://timbre-builtin/"
NEW = b"resource://android/timbre/"
OLD_MAP = b"resource timbre-builtin file:extensions/timbre/"
NEW_MAP = b"resource android file:extensions/"

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
                if mode and path.exists():
                    path.chmod(mode)
        app = root / "Payload/Firefox.app"
        info = plistlib.loads((app / "Info.plist").read_bytes())
        matches = []
        for candidate in app.rglob("*"):
            if not candidate.is_file():
                continue
            with candidate.open("rb") as handle:
                magic = handle.read(4)
            if magic not in {bytes.fromhex("cffaedfe"), bytes.fromhex("cafebabe")}:
                continue
            data = candidate.read_bytes()
            count = data.count(OLD)
            if count:
                matches.append((candidate, data, count))
        count = sum(item[2] for item in matches)
        assert count == 1, f"Expected exactly one Timbre URI literal across Mach-O binaries, found {count}"
        binary, data, _ = matches[0]
        patched_relative = str(binary.relative_to(app))
        print(f"Repairing Timbre URI in {patched_relative}", flush=True)
        binary.write_bytes(data.replace(OLD, NEW))
        binary.chmod(0o755)
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(binary)], check=True)
        gecko = app / "Frameworks/GeckoView.framework"
        patch(gecko / "Frameworks")
        manifest = gecko / "Frameworks/chrome.manifest"
        data = manifest.read_bytes()
        assert data.count(OLD_MAP) == 1
        manifest.write_bytes(data.replace(OLD_MAP, NEW_MAP))
        extension = gecko / "Frameworks/extensions/timbre"
        assert (extension / "manifest.json").is_file()
        assert (extension / "engine.js").is_file()
        for bundle in [app, *sorted((app / "PlugIns").glob("*.appex"))]:
            path = bundle / "Info.plist"
            info = plistlib.loads(path.read_bytes())
            info["CFBundleShortVersionString"] = f"159.0.{build}"
            info["CFBundleVersion"] = str(build)
            path.write_bytes(plistlib.dumps(info, sort_keys=False))
            exe = bundle / info["CFBundleExecutable"]
            exe.chmod(0o755)
        for bundle in [gecko, *sorted((app / "PlugIns").glob("*.appex")), app]:
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle)], check=True)
            subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(root / "Payload"), str(output)], check=True)
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        prefix = "Payload/Firefox.app/"
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        binary = archive.read(prefix + patched_relative)
        assert binary.count(NEW) == 1 and OLD not in binary
        chrome = archive.read(prefix + "Frameworks/GeckoView.framework/Frameworks/chrome.manifest")
        assert NEW_MAP in chrome and OLD_MAP not in chrome
        assert info["CFBundleVersion"] == str(build)
    print(f"Verified repaired IPA: {output}, {output.stat().st_size} bytes")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--build", type=int, required=True)
    args = parser.parse_args()
    repair(args.source, args.output, args.build)
