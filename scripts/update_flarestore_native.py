#!/usr/bin/env python3
"""Add a Firefox Gecko (Native UI) build to the FlareStore/AltStore feed.

The native-UI app has its own bundle ID (com.soum91.FirefoxNativeGecko), so
it gets its own entry and installs alongside the Reynard-based "Firefox
Gecko" app instead of replacing it. Newest version first; up to 10 kept.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

BUNDLE_ID = "com.soum91.FirefoxNativeGecko"
APP_NAME = "Firefox Gecko (Native UI)"
SUBTITLE = "Mozilla's Firefox 159 UI with the Reynard Gecko engine"
DESCRIPTION = (
    "Mozilla's own Firefox 159 app (home, tab tray, menus, settings) with web pages "
    "rendered by the Reynard Gecko engine instead of WebKit. Experimental test builds, "
    "not an official Mozilla release. Re-sign everything, including Frameworks/XUL.dylib, "
    "GeckoView.framework and PlugIns/Reynard Helper.appex."
)


def update(feed_path: Path, version: str, build: str, url: str, size: int, date: str,
           notes: str, min_os: str) -> None:
    feed = json.loads(feed_path.read_text(encoding="utf-8"))
    apps = feed.setdefault("apps", [])
    app = next((a for a in apps if a.get("bundleIdentifier") == BUNDLE_ID), None)
    if app is None:
        template = apps[0] if apps else {}
        app = {
            "name": APP_NAME,
            "bundleIdentifier": BUNDLE_ID,
            "developerName": template.get("developerName", "soum91"),
            "subtitle": SUBTITLE,
            "localizedDescription": DESCRIPTION,
            "iconURL": template.get("iconURL", ""),
            "tintColor": template.get("tintColor", "#FF8C42"),
            "category": template.get("category", "utilities"),
            "versions": [],
        }
        apps.append(app)
    entry = {
        "version": version,
        "buildVersion": build,
        "date": date,
        "localizedDescription": notes,
        "downloadURL": url,
        "size": size,
        "minOSVersion": min_os,
    }
    versions = [v for v in app.get("versions", [])
                if not (v.get("version") == version and v.get("buildVersion") == build)]
    app["versions"] = [entry, *versions][:10]
    app.update(
        version=version,
        versionDate=date,
        versionDescription=notes,
        downloadURL=url,
        size=size,
    )
    feed_path.write_text(json.dumps(feed, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{APP_NAME}: {version} ({build}) -> {url}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("feed", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--size", type=int, required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--notes", required=True)
    parser.add_argument("--min-os", default="15.0")
    args = parser.parse_args()
    update(args.feed, args.version, args.build, args.url, args.size, args.date, args.notes, args.min_os)
