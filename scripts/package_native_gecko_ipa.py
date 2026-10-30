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
KEEP_PLUGINS = {"WidgetKitExtension.appex"}
# Firefox's own scheme is "firefox"; a separate one keeps links meant for this
# app from opening a real Firefox installed alongside it.
URL_SCHEME = "firefoxgecko"


def run(*cmd: object) -> None:
    print("+", " ".join(map(str, cmd)), flush=True)
    subprocess.run([str(c) for c in cmd], check=True)


def is_macho(path: Path) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    with path.open("rb") as handle:
        return handle.read(4) in MACHO_MAGICS


def copy_resolved(src: Path, dest: Path) -> None:
    """Copy following symlinks, like AddGecko.sh's cp -L / rsync -L.

    Links whose target is gone are skipped; package() reports them.
    """
    if src.is_symlink() and not src.exists():
        return
    if src.is_dir():
        shutil.copytree(src, dest, symlinks=False, dirs_exist_ok=True,
                        ignore=lambda folder, names: [
                            n for n in names
                            if (Path(folder) / n).is_symlink() and not (Path(folder) / n).exists()])
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
            default_theme: Path, output: Path, bundle_id: str, version: str, build: str,
            missing_report: Path | None = None, companion: Path | None = None,
            extensions: list[Path] | None = None) -> None:
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
        url_types = info.get("CFBundleURLTypes") or [{}]
        url_types[0]["CFBundleURLSchemes"] = [
            URL_SCHEME if scheme == info.get("MozPublicURLScheme", "firefox") else scheme
            for scheme in url_types[0].get("CFBundleURLSchemes", [])
        ] or [URL_SCHEME]
        if URL_SCHEME not in url_types[0]["CFBundleURLSchemes"]:
            url_types[0]["CFBundleURLSchemes"].insert(0, URL_SCHEME)
        set_plist(app / "Info.plist", CFBundleURLTypes=url_types, MozPublicURLScheme=URL_SCHEME)

        # Firefox's extensions each cost an App ID when sideloading. Keep only the
        # widget extension, which draws Firefox's download Live Activity.
        kept = []
        for folder in ("PlugIns", "Extensions", "Watch"):
            for item in sorted((app / folder).glob("*")) if (app / folder).exists() else []:
                if folder == "PlugIns" and item.name in KEEP_PLUGINS:
                    kept.append(item.name)
                    continue
                print(f"removing {folder}/{item.name}")
                shutil.rmtree(item, ignore_errors=True)
        for name in kept:
            extension = app / "PlugIns" / name
            extension_info = plistlib.loads((extension / "Info.plist").read_bytes())
            set_plist(
                extension / "Info.plist",
                CFBundleIdentifier=f"{bundle_id}.{Path(name).stem}",
                CFBundleShortVersionString=version,
                CFBundleVersion=build,
                **({"MozPublicURLScheme": URL_SCHEME} if "MozPublicURLScheme" in extension_info else {}),
            )
            print(f"keeping PlugIns/{name}")
        # Safari redirect and share sheet extensions (scripts/build_link_extensions.sh).
        for source in extensions or []:
            target = app / "PlugIns" / source.name
            shutil.copytree(source, target, symlinks=True)
            set_plist(
                target / "Info.plist",
                CFBundleIdentifier=f"{bundle_id}.{source.stem}",
                CFBundleShortVersionString=version,
                CFBundleVersion=build,
            )
            print(f"added PlugIns/{source.name}")

        frameworks = app / "Frameworks"
        frameworks.mkdir(exist_ok=True)
        geckoview = frameworks / "GeckoView.framework"
        if not (geckoview / "GeckoView").is_file():
            print("GeckoView.framework was not embedded by Xcode; copying it")
            shutil.rmtree(geckoview, ignore_errors=True)
            copy_resolved(framework_src, geckoview)
        gecko_frameworks = geckoview / "Frameworks"
        gecko_frameworks.mkdir(exist_ok=True)

        # The cached engine archive keeps dist/ only; links into the rest of
        # the Gecko build tree dangle after a restore. Report them all at once.
        dangling = sorted(str(p.relative_to(dist_bin)) for p in dist_bin.rglob("*")
                          if p.is_symlink() and not p.exists())
        if dangling:
            print(f"warning: skipping {len(dangling)} Gecko files whose links dangle in the "
                  f"cached engine: {', '.join(dangling)}")
        if missing_report:
            missing_report.write_text("".join(f"{d}\n" for d in dangling), encoding="utf-8")
        xul = dist_bin / "XUL"
        print(f"dist/bin: {len(list(dist_bin.iterdir()))} entries; XUL symlink={xul.is_symlink()} "
              f"resolves={xul.exists()}" + (f" -> {xul.resolve()}" if xul.is_symlink() else ""))
        if not xul.is_file():
            raise FileNotFoundError(f"Gecko XUL missing or a dangling link in {dist_bin}")
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
        # Built-in add-on Gecko loads from resource://app/extensions/fetchdock/,
        # the same place Reynard's companion build compiles it into dist/bin.
        if companion is not None:
            target = gecko_frameworks / "extensions" / "fetchdock"
            target.mkdir(parents=True, exist_ok=True)
            for file in sorted(companion.iterdir()):
                if file.is_file() and not file.name.endswith(".md"):
                    shutil.copy2(file, target / file.name)
            if not (target / "manifest.json").is_file():
                raise FileNotFoundError(f"FetchDock Companion manifest missing in {companion}")
            print(f"bundled FetchDock Companion from {companion}")

        plugins = app / "PlugIns"
        plugins.mkdir(exist_ok=True)
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
        for extension in sorted(plugins.glob("*.appex")):
            run("codesign", "--force", "--sign", "-", "--timestamp=none", extension)
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
                         "PlugIns/Reynard Helper.appex/Info.plist",
                         *(["Frameworks/GeckoView.framework/Frameworks/extensions/fetchdock/manifest.json"]
                           if companion is not None else [])):
            if prefix + required not in names:
                raise ValueError(f"IPA is missing {required}")
        if prefix + "Frameworks/XUL" in names:
            raise ValueError("IPA still contains the unrenamed XUL")
        # Developer Gecko builds ship loose chrome files rather than omni.ja.
        runtime = prefix + "Frameworks/GeckoView.framework/Frameworks/"
        if runtime + "chrome.manifest" not in names or not any(n.startswith(runtime + "chrome/") for n in names):
            raise ValueError("IPA is missing Gecko's runtime resources (chrome.manifest, chrome/)")
        for source in extensions or []:
            if prefix + f"PlugIns/{source.name}/Info.plist" not in names:
                raise ValueError(f"IPA is missing PlugIns/{source.name}")
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
    parser.add_argument("--companion", type=Path,
                        help="Reynard's addons/fetchdock folder, bundled as a built-in add-on")
    parser.add_argument("--extension", type=Path, action="append", default=[],
                        help="extra .appex to embed under PlugIns (repeatable)")
    parser.add_argument("--missing-report", type=Path,
                        help="write Gecko files skipped because their links dangle")
    args = parser.parse_args()
    try:
        package(args.app, args.helper, args.framework, args.dist_bin, args.default_theme,
                args.output, args.bundle_id, args.version, args.build, args.missing_report,
                args.companion, args.extension)
    except Exception as failure:  # one greppable line for the CI error summary
        import sys
        import traceback
        traceback.print_exc()
        detail = f"{type(failure).__name__}: {failure}".replace("\n", " | ")
        print(f"error: IPA packaging failed: {detail}", file=sys.stderr, flush=True)
        sys.exit(1)
