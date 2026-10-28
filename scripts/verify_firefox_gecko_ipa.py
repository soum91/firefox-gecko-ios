#!/usr/bin/env python3
"""Structural preflight for a Firefox-UI / Gecko IPA before device testing.

Passing this check does not establish that Gecko renders pages, that add-ons
work, or that the IPA is correctly signed. Those require device validation.
"""

import argparse
import plistlib
from pathlib import Path
from zipfile import ZipFile


APP = "Payload/Client.app/"


def verify(path: Path) -> str:
    with ZipFile(path) as archive:
        names = set(archive.namelist())
        info_path = APP + "Info.plist"
        if info_path not in names or APP + "Client" not in names:
            raise ValueError("IPA must contain the actual Firefox Client.app executable")

        info = plistlib.loads(archive.read(info_path))
        if info.get("CFBundleExecutable") != "Client":
            raise ValueError("Firefox Client executable identity is missing")
        display = info.get("CFBundleDisplayName") or info.get("CFBundleName", "")
        if "firefox" not in display.lower():
            raise ValueError("Application display identity is not Firefox")

        if not any(name.startswith(APP + "Frameworks/GeckoView.framework/")
                   and name.endswith("/GeckoView") for name in names):
            raise ValueError("GeckoView.framework executable is missing")
        if not any(name.startswith(APP + "Frameworks/") and name.endswith("/XUL.dylib")
                   for name in names):
            raise ValueError("Gecko XUL.dylib runtime is missing")
        if not info.get("NSSupportsLiveActivities"):
            raise ValueError("Download Live Activities are not declared")

        widget = False
        for name in names:
            if not (name.startswith(APP + "PlugIns/") and name.endswith(".appex/Info.plist")):
                continue
            extension = plistlib.loads(archive.read(name)).get("NSExtension", {})
            if extension.get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension":
                widget = True
                break
        if not widget:
            raise ValueError("Download Live Activity WidgetKit extension is missing")

        return info.get("CFBundleIdentifier", "(no bundle identifier)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    args = parser.parse_args()
    bundle = verify(args.ipa)
    print(f"Structural preflight passed for {bundle}; device validation is still required.")
