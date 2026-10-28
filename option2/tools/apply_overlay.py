#!/usr/bin/env python3
"""Apply Firefox UI / Reynard Gecko engine adapter to Firefox iOS 159 source.

Requires an independently built device-compatible GeckoView.xcframework.
The overlay does NOT claim to build this framework or initialize Gecko's
multi-process runtime. The Engine factory/runtime startup still need wiring.
"""
import argparse
from pathlib import Path
import plistlib
import re
import shutil


VERSION = "firefox-v159.0"
WEBENGINE_TARGET = Path("BrowserKit/Sources/WebEngine")
BROWSERKIT_PACKAGE = Path("BrowserKit/Package.swift")
BINARY_NAME = "GeckoView.xcframework"


def apply(firefox_root: Path, adapter_file: Path, xcframework: Path) -> None:
    firefox_root = firefox_root.resolve()
    adapter_file = adapter_file.resolve()
    xcframework = xcframework.resolve()

    target = firefox_root / WEBENGINE_TARGET
    package = firefox_root / BROWSERKIT_PACKAGE
    if not (target / "Engine.swift").exists() or not (target / "WKWebview/WKEngine.swift").exists():
        raise ValueError("Expected Mozilla firefox-ios v159.0 BrowserKit layout")
    if not package.exists():
        raise ValueError("BrowserKit/Package.swift missing")
    if not xcframework.is_dir() or not (xcframework / "Info.plist").exists():
        raise ValueError("Supply a device-compatible GeckoView.xcframework with Info.plist")
    with (xcframework / "Info.plist").open("rb") as source:
        framework_info = plistlib.load(source)
    device_slices = [
        item for item in framework_info.get("AvailableLibraries", [])
        if item.get("SupportedPlatform") == "ios"
        and "arm64" in item.get("SupportedArchitectures", [])
    ]
    if not device_slices:
        raise ValueError("GeckoView.xcframework lacks an iOS arm64 device slice")
    if not any(xcframework.glob("**/GeckoView.swiftmodule/*-apple-ios.swiftinterface")):
        raise ValueError(
            "GeckoView.xcframework lacks a distributable Swift interface; "
            "rebuild GeckoView from source with BUILD_LIBRARY_FOR_DISTRIBUTION=YES"
        )

    # The actual GeckoView runtime and child-process extensions are NOT shipped
    # via SwiftPM alone. Xcode app embedding is a separate required integration.
    destination = firefox_root / "BrowserKit" / "Binaries" / BINARY_NAME
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        raise FileExistsError(f"Refusing to overwrite existing binary framework: {destination}")
    shutil.copytree(xcframework, destination)

    text = package.read_text(encoding="utf-8")
    dependencies = '''        .target(
            name: "WebEngine",
            dependencies: ["Common",
                           .product(name: "GCDWebServers", package: "GCDWebServer")],'''
    modified = '''        .target(
            name: "WebEngine",
            dependencies: ["Common", "GeckoView",
                           .product(name: "GCDWebServers", package: "GCDWebServer")],'''
    if text.count(dependencies) != 1:
        raise ValueError("BrowserKit WebEngine target did not match expected Firefox 159")
    text = text.replace(dependencies, modified, 1)
    # Introduce an internal binary target for the prebuilt engine framework.
    target_anchor = '''    targets: [
        .target('''
    if text.count(target_anchor) != 1:
        raise ValueError("BrowserKit target list did not match")
    text = text.replace(target_anchor,
        '''    targets: [
        .binaryTarget(name: "GeckoView", path: "Binaries/GeckoView.xcframework"),
        .target(''', 1)
    package.write_text(text, encoding="utf-8")

    shutil.copyfile(adapter_file, target / "ReynardGeckoEngine.swift")
    print(f"Placed engine adapter: {target / 'ReynardGeckoEngine.swift'}")
    print("NEXT: Wire Engine factory to ReynardGeckoEngine, integrate GeckoRuntime startup,")
    print("       embed helper processes and resources, and resolve remaining WebKit-only APIs.")
    print("NOT an installable build. No official Mozilla signing rights are preserved.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("firefox_source", type=Path)
    parser.add_argument("geckoview_xcframework", type=Path)
    parser.add_argument("--adapter", type=Path, default=Path(__file__).resolve().parents[1] /
                        "BrowserKit/WebEngine/ReynardGeckoEngine.swift")
    args = parser.parse_args()
    apply(args.firefox_source, args.adapter, args.geckoview_xcframework)
