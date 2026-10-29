#!/usr/bin/env python3
"""Package Mozilla's Firefox 159 app (built with the Gecko overlay) as an IPA.

Embeds the Reynard Gecko engine the way Reynard's browser/Scripts/AddGecko.sh
does, plus the fixes main learned on device:

- Frameworks/GeckoView.framework (from the build or the xcframework)
- Frameworks/*.dylib and XUL, renamed XUL.dylib with every @rpath/XUL load
  command rewritten, because sideloaders skip signing an extensionless XUL and
  dyld then rejects it ("code signature invalid", main's 159.0.5 repair)
- the rest of Gecko's dist/bin (omni.ja, prefs, components) and the default
  theme inside GeckoView.framework/Frameworks, where Gecko looks for them
- PlugIns/Reynard Helper.appex, the child-process extension Gecko launches by
  that exact path

Firefox's own app extensions (widgets, share, notification service, ...) are
removed: each needs its own App ID when sideloading and none is needed to
browse. The result is ad-hoc signed as a consistency check; the sideloader must
re-sign everything with the user's certificate.
"""
from __future__ import annotations

import argparse
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

MACHO_MAGICS = {bytes.fromhex("cffaedfe"), bytes.fromhex("cafebabe")}
OLD_XUL = "@rpath/XUL"
NEW_XUL = "@rpath/XUL.dylib"
SKIP_DIST = ("Test", "test_")


def run(*cmd: object) -> None:
    print("+", " ".join(map(str, cmd)), flush=True)
    subprocess.run([str(c) for c in cmd], check=True)


def is_macho(path: Path) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    with path.open("rb") as handle:
        return handle.read(4) in MACHO_MAGICS


def copy_resolved(src: Path, dest: Path) -> None:
    """Copy following symlinks, like AddGecko.sh's cp -L / rsync -L."""
    if src.is_dir():
        shutil.copytree(src, dest, symlinks=False, dirs_exist_ok=True)
    else:
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest, follow_symlinks=True)


def set_plist(path: Path, **values: object) -> dict:
    info = plistlib.loads(path.read_bytes())
    for key in ("UISupportedDevices", "WKCompanionAppBundleIdentifier", "WKWatchKitApp"):
        info.pop(key, None)
    info.update(values)
    path.write_bytes(plistlib.dumps(info, sort_keys=False))
    return info


def package(app_src: Path, helper_src: Path, framework_src: Path, dist_bin: Path,
            default_theme: Path, output: Path, bundle_id: str, version: str, build: str) -> None:
    with tempfile.TemporaryDirectory(prefix="firefox-gecko-ipa-") as temp:
        payload = Path(temp) / "Payload"
        app = payload / "Firefox.app"
        shutil.copytree(app_src, app, symlinks=True)

        info = set_plist(
            app / "Info.plist",
            CFBundleIdentifier=bundle_id,
            CFBundleDisplayName="Firefox Gecko",
            CFBundleShortVersionString=version,
            CFBundleVersion=build,
        )
        executable = info["CFBundleExecutable"]

        # Firefox's extensions are not needed to browse and each costs an App ID.
        for folder in ("PlugIns", "Extensions", "Watch"):
            removed = sorted(p.name for p in (app / folder).glob("*")) if (app / folder).exists() else []
            if removed:
                print(f"removing {folder}: {', '.join(removed)}")
            shutil.rmtree(app / folder, ignore_errors=True)

        frameworks = app / "Frameworks"
        frameworks.mkdir(exist_ok=True)
        geckoview = frameworks / "GeckoView.framework"
        if not (geckoview / "GeckoView").is_file():
            print("GeckoView.framework was not embedded by Xcode; copying it")
            shutil.rmtree(geckoview, ignore_errors=True)
            copy_resolved(framework_src, geckoview)
        gecko_frameworks = geckoview / "Frameworks"
        gecko_frameworks.mkdir(exist_ok=True)

        if not (dist_bin / "XUL").is_file():
            raise FileNotFoundError(f"Gecko XUL missing from {dist_bin}")
        for entry in sorted(dist_bin.iterdir()):
            if entry.name == "XUL":
                copy_resolved(entry, frameworks / "XUL.dylib")
            elif entry.name.endswith(".dylib"):
                copy_resolved(entry, frameworks / entry.name)
            elif entry.name.startswith(SKIP_DIST) or entry.name.endswith("_unittest"):
                continue
            else:
                copy_resolved(entry, gecko_frameworks / entry.name)
        if default_theme.is_dir():
            copy_resolved(default_theme, gecko_frameworks / "default-theme")
            with (gecko_frameworks / "chrome.manifest").open("a", encoding="utf-8") as manifest:
                manifest.write("resource default-theme file:default-theme/\n")
        else:
            print(f"warning: default theme not found at {default_theme}")

        plugins = app / "PlugIns"
        plugins.mkdir()
        helper = plugins / "Reynard Helper.appex"
        shutil.copytree(helper_src, helper, symlinks=True)
        # A sideloaded extension must sit under the app's bundle ID.
        set_plist(
            helper / "Info.plist",
            CFBundleIdentifier=f"{bundle_id}.Helper",
            CFBundleShortVersionString=version,
            CFBundleVersion=build,
        )
        helper_executable = plistlib.loads((helper / "Info.plist").read_bytes())["CFBundleExecutable"]

        # Rewrite every dependency on XUL so no binary still loads the old name.
        machos = [p for p in sorted(app.rglob("*")) if is_macho(p)]
        rewritten = []
        for binary in machos:
            if OLD_XUL.encode() + b"\0" in binary.read_bytes()[:65536]:
                run("xcrun", "install_name_tool", "-change", OLD_XUL, NEW_XUL, binary)
                rewritten.append(str(binary.relative_to(app)))
        run("xcrun", "install_name_tool", "-id", NEW_XUL, frameworks / "XUL.dylib")
        print("rewrote XUL dependency in:", ", ".join(rewritten) or "nothing")
        if not any(p.endswith("GeckoView.framework/GeckoView") for p in rewritten):
            raise ValueError("GeckoView's XUL dependency was not rewritten")

        # Ad-hoc signatures: leaf code first, then bundles, then the app.
        for binary in machos:
            run("codesign", "--force", "--sign", "-", "--timestamp=none", binary)
        for bundle in sorted(frameworks.glob("*.framework")):
            run("codesign", "--force", "--sign", "-", "--timestamp=none", bundle)
        run("codesign", "--force", "--sign", "-", "--timestamp=none", helper)
        run("codesign", "--force", "--sign", "-", "--timestamp=none", app)
        for binary in (app / executable, frameworks / "XUL.dylib", geckoview / "GeckoView",
                       helper / helper_executable):
            run("codesign", "--verify", "--strict", binary)
        run("xcrun", "otool", "-L", app / executable)

        output.parent.mkdir(parents=True, exist_ok=True)
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", payload, output)

    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise ValueError("IPA zip is damaged")
        names = set(archive.namelist())
        prefix = "Payload/Firefox.app/"
        for required in ("Info.plist", "Frameworks/XUL.dylib",
                         "Frameworks/GeckoView.framework/GeckoView",
                         "PlugIns/Reynard Helper.appex/Info.plist"):
            if prefix + required not in names:
                raise ValueError(f"IPA is missing {required}")
        if prefix + "Frameworks/XUL" in names:
            raise ValueError("IPA still contains the unrenamed XUL")
        if not any(n.startswith(prefix + "Frameworks/GeckoView.framework/Frameworks/omni") for n in names):
            raise ValueError("IPA is missing Gecko's omni.ja runtime resources")
        built = plistlib.loads(archive.read(prefix + "Info.plist"))
        if built["CFBundleVersion"] != build:
            raise ValueError("IPA build number mismatch")
    print(f"PACKAGED {output} ({output.stat().st_size // 1048576} MB), build {build}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--framework", type=Path, required=True)
    parser.add_argument("--dist-bin", type=Path, required=True)
    parser.add_argument("--default-theme", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bundle-id", default="com.soum91.FirefoxNativeGecko")
    parser.add_argument("--version", default="159.0")
    parser.add_argument("--build", required=True)
    args = parser.parse_args()
    package(args.app, args.helper, args.framework, args.dist_bin, args.default_theme,
            args.output, args.bundle_id, args.version, args.build)
