#!/usr/bin/env python3
"""Apply the private Firefox/Gecko overlay to a pinned public Reynard checkout.

Intentionally does not copy decrypted Mozilla binaries, inject signing identities,
or claim Apple's managed default-browser entitlement.
"""

import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

if __package__:
    from .stamp_version import stamp
else:
    from stamp_version import stamp


ROOT = Path(__file__).resolve().parents[1]


def replace_once(content: str, old: str, new: str) -> str:
    occurrences = content.count(old)
    if occurrences != 1:
        raise RuntimeError(f"Expected exactly one occurrence ({occurrences} found): {old[:80]}")
    return content.replace(old, new, 1)


def insert_in_section(content: str, section: str, entry: str) -> str:
    return replace_once(content, f"/* End {section} section */", entry + f"/* End {section} section */")


def object_id(n: int) -> str:
    return f"{0x50D1A0000000000000000000 + n:024X}"


def patch_project(path: Path) -> None:
    content = path.read_text(encoding="utf-8")
    if "FirefoxDownloadWidget" in content:
        raise RuntimeError("Project has already been patched; start from the pinned source revision")

    product, embed, proxy, dependency, group, target = (object_id(i) for i in range(1, 7))
    sources, frameworks, resources, debug, release, configs, exception = (object_id(i) for i in range(7, 14))

    content = insert_in_section(content, "PBXBuildFile",
        f'\t\t{embed} /* FirefoxDownloadWidget.appex in Embed Process Extensions */ = {{isa = PBXBuildFile; fileRef = {product} /* FirefoxDownloadWidget.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n')
    content = insert_in_section(content, "PBXContainerItemProxy",
        f'\t\t{proxy} /* PBXContainerItemProxy */ = {{isa = PBXContainerItemProxy; containerPortal = 018C67962F2F289C001F0BBB /* Project object */; proxyType = 1; remoteGlobalIDString = {target}; remoteInfo = FirefoxDownloadWidget; }};\n')
    content = insert_in_section(content, "PBXFileReference",
        f'\t\t{product} /* FirefoxDownloadWidget.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = FirefoxDownloadWidget.appex; sourceTree = BUILT_PRODUCTS_DIR; }};\n')
    content = insert_in_section(content, "PBXFileSystemSynchronizedBuildFileExceptionSet",
        f'\t\t{exception} /* Widget Info.plist exclusion */ = {{isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = (Info.plist, ); target = {target} /* FirefoxDownloadWidget */; }};\n')
    content = insert_in_section(content, "PBXFileSystemSynchronizedRootGroup",
        f'\t\t{group} /* DownloadLiveWidget */ = {{isa = PBXFileSystemSynchronizedRootGroup; exceptions = ({exception} /* Widget Info.plist exclusion */, ); path = DownloadLiveWidget; sourceTree = "<group>"; }};\n')
    content = insert_in_section(content, "PBXFrameworksBuildPhase",
        f'\t\t{frameworks} /* Frameworks */ = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ( ); runOnlyForDeploymentPostprocessing = 0; }};\n')
    content = insert_in_section(content, "PBXSourcesBuildPhase",
        f'\t\t{sources} /* Sources */ = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ( ); runOnlyForDeploymentPostprocessing = 0; }};\n')
    content = insert_in_section(content, "PBXResourcesBuildPhase",
        f'\t\t{resources} /* Resources */ = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ( ); runOnlyForDeploymentPostprocessing = 0; }};\n')
    content = insert_in_section(content, "PBXNativeTarget",
        f'\t\t{target} /* FirefoxDownloadWidget */ = {{isa = PBXNativeTarget; buildConfigurationList = {configs} /* Build configuration list for FirefoxDownloadWidget */; buildPhases = ({sources} /* Sources */, {frameworks} /* Frameworks */, {resources} /* Resources */, ); buildRules = ( ); dependencies = ( ); fileSystemSynchronizedGroups = ({group} /* DownloadLiveWidget */, ); name = FirefoxDownloadWidget; packageProductDependencies = ( ); productName = FirefoxDownloadWidget; productReference = {product} /* FirefoxDownloadWidget.appex */; productType = "com.apple.product-type.app-extension"; }};\n')
    content = insert_in_section(content, "PBXTargetDependency",
        f'\t\t{dependency} /* PBXTargetDependency */ = {{isa = PBXTargetDependency; target = {target} /* FirefoxDownloadWidget */; targetProxy = {proxy} /* PBXContainerItemProxy */; }};\n')

    for label, ident in (("Debug", debug), ("Release", release)):
        settings = (
            'APPLICATION_EXTENSION_API_ONLY = YES; CODE_SIGN_STYLE = Automatic; '
            'CODE_SIGN_IDENTITY = "Apple Development"; CURRENT_PROJECT_VERSION = "$(CURRENT_BUILD)"; '
            'GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = DownloadLiveWidget/Info.plist; '
            'IPHONEOS_DEPLOYMENT_TARGET = 16.1; MARKETING_VERSION = "$(CURRENT_VERSION)"; '
            'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_ID).DownloadLiveWidget"; '
            'PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = iphoneos; SKIP_INSTALL = YES; '
            'SWIFT_VERSION = 5.0; SWIFT_OBJC_BRIDGING_HEADER = ""; '
            'TARGETED_DEVICE_FAMILY = "1,2";'
        )
        content = insert_in_section(content, "XCBuildConfiguration",
            f'\t\t{ident} /* {label} */ = {{isa = XCBuildConfiguration; baseConfigurationReference = 01GECKO0052F2F289C001F0001 /* Reynard.xcconfig */; buildSettings = {{{settings}}}; name = {label}; }};\n')
    content = insert_in_section(content, "XCConfigurationList",
        f'\t\t{configs} /* Build configuration list for FirefoxDownloadWidget */ = {{isa = XCConfigurationList; buildConfigurations = ({debug} /* Debug */, {release} /* Release */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};\n')

    content = replace_once(content,
        '02WCPBF12F3000000000001 /* Reynard Helper.appex in Embed Process Extensions */,',
        f'02WCPBF12F3000000000001 /* Reynard Helper.appex in Embed Process Extensions */,\n\t\t\t\t{embed} /* FirefoxDownloadWidget.appex in Embed Process Extensions */,')
    content = replace_once(content,
        '04AFAPP2F3200000000001 /* ReynardAutoFill.appex */,\n\t\t\t);',
        f'04AFAPP2F3200000000001 /* ReynardAutoFill.appex */,\n\t\t\t\t{product} /* FirefoxDownloadWidget.appex */,\n\t\t\t);')
    content = replace_once(content,
        '04AFGRP12F3200000000001 /* CredentialProvider */,\n\t\t\t\t018C679F2F2F289C001F0BBB /* Products */,',
        f'04AFGRP12F3200000000001 /* CredentialProvider */,\n\t\t\t\t{group} /* DownloadLiveWidget */,\n\t\t\t\t018C679F2F2F289C001F0BBB /* Products */,')
    content = replace_once(content,
        '04AFDEP2F3200000000001 /* PBXTargetDependency */,\n\t\t\t);',
        f'04AFDEP2F3200000000001 /* PBXTargetDependency */,\n\t\t\t\t{dependency} /* PBXTargetDependency */,\n\t\t\t);')
    content = replace_once(content,
        '04AFTGT2F3200000000001 /* ReynardAutoFill */,\n\t\t\t);',
        f'04AFTGT2F3200000000001 /* ReynardAutoFill */,\n\t\t\t\t{target} /* FirefoxDownloadWidget */,\n\t\t\t);')
    content = replace_once(content,
        '04AFTGT2F3200000000001 = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 26.2;\n\t\t\t\t\t};',
        f'04AFTGT2F3200000000001 = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 26.2;\n\t\t\t\t\t}};\n\t\t\t\t\t{target} = {{CreatedOnToolsVersion = 26.2; }};')
    for old, new in (("com.minh-ton.Reynard.Helper", "$(APP_BUNDLE_ID).Helper"),
                     ("com.minh-ton.Reynard.OpenIn", "$(APP_BUNDLE_ID).OpenIn"),
                     ("com.minh-ton.Reynard.AutoFill", "$(APP_BUNDLE_ID).AutoFill"),
                     ('PRODUCT_BUNDLE_IDENTIFIER = "com.minh-ton.Reynard";', 'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_ID)";')):
        content = content.replace(old, new)
    path.write_text(content, encoding="utf-8")


def patch_release_tools(source: Path) -> None:
    """Keep stamped numeric versions intact through archive and IPA packaging."""
    archive_script = source / "tools" / "release" / "build-app.sh"
    content = archive_script.read_text(encoding="utf-8")
    original = '''BUILD_SHA=$(git -C "$ROOT_DIR" rev-parse HEAD | cut -c1-7)
sed -i '' -E \\
\t-e "s|^CURRENT_BUILD = .*|CURRENT_BUILD = $BUILD_SHA|" \\
\t"$BUILD_XCCONFIG_PATH"
'''
    # The upstream script deliberately uses a short SHA for CFBundleVersion.
    # Our version must remain numeric to support iOS update checks and feeds.
    if original not in content:
        raise RuntimeError("Expected upstream version override was not found")
    content = replace_once(content, original, '# Keep the numeric build stamped by the integration workflow.\n')
    archive_script.write_text(content, encoding="utf-8")

    package_script = source / "tools" / "release" / "create-ipa.sh"
    content = package_script.read_text(encoding="utf-8")
    first = content.index('plutil -replace CFBundleIdentifier -string "com.minh-ton.Reynard"')
    last_line = 'plutil -replace CFBundleIdentifier -string "com.minh-ton.Reynard.AutoFill" "$APP_PATH/PlugIns/ReynardAutoFill.appex/Info.plist"'
    last = content.index(last_line, first) + len(last_line)
    replacement = '''# Use the app's own development bundle ID. Do not imply Mozilla signing.
BUILD_CONFIG="$ROOT_DIR/dist/Reynard.xcconfig"
APP_BUNDLE_ID=$(sed -n 's/^APP_BUNDLE_ID = //p' "$BUILD_CONFIG")
PUBLIC_VERSION=$(sed -n 's/^CURRENT_VERSION = //p' "$BUILD_CONFIG")
BUILD_NUMBER=$(sed -n 's/^CURRENT_BUILD = //p' "$BUILD_CONFIG")
test -n "$APP_BUNDLE_ID" && test -n "$PUBLIC_VERSION" && test -n "$BUILD_NUMBER"

plutil -replace CFBundleIdentifier -string "$APP_BUNDLE_ID" "$APP_PATH/Info.plist"
plutil -replace CFBundleIdentifier -string "$APP_BUNDLE_ID.Helper" "$APP_PATH/PlugIns/Reynard Helper.appex/Info.plist"
plutil -replace CFBundleIdentifier -string "$APP_BUNDLE_ID.OpenIn" "$APP_PATH/PlugIns/OpenIn.appex/Info.plist"
plutil -replace CFBundleIdentifier -string "$APP_BUNDLE_ID.AutoFill" "$APP_PATH/PlugIns/ReynardAutoFill.appex/Info.plist"
plutil -replace CFBundleIdentifier -string "$APP_BUNDLE_ID.DownloadLiveWidget" "$APP_PATH/PlugIns/FirefoxDownloadWidget.appex/Info.plist"
for plist in "$APP_PATH/Info.plist" "$APP_PATH"/PlugIns/*.appex/Info.plist; do
    test -f "$plist" || continue
    plutil -replace CFBundleShortVersionString -string "$PUBLIC_VERSION" "$plist"
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$plist"
done'''
    content = content[:first] + replacement + content[last:]
    package_script.write_text(content, encoding="utf-8")


def bootstrap(source: Path, revision: int) -> dict:
    config = json.loads((ROOT / "config" / "build.json").read_text(encoding="utf-8"))
    if not (source / "browser" / "Reynard.xcodeproj" / "project.pbxproj").exists():
        raise RuntimeError("The target path is not a Reynard source checkout")
    for relative, dest in (
        ("overlay/shared/FirefoxDownloadActivityAttributes.swift", "browser/Reynard/Client/Stores/FirefoxDownloadActivityAttributes.swift"),
        ("overlay/shared/FirefoxDownloadActivityAttributes.swift", "browser/DownloadLiveWidget/FirefoxDownloadActivityAttributes.swift"),
        ("overlay/app/FirefoxDownloadActivityCoordinator.swift", "browser/Reynard/Client/Stores/FirefoxDownloadActivityCoordinator.swift"),
        ("overlay/widget/FirefoxDownloadWidget.swift", "browser/DownloadLiveWidget/FirefoxDownloadWidget.swift"),
        ("overlay/widget/Info.plist", "browser/DownloadLiveWidget/Info.plist"),
    ):
        target = source / dest
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, target)

    app_delegate = source / "browser" / "Reynard" / "AppDelegate.swift"
    content = app_delegate.read_text(encoding="utf-8")
    content = replace_once(content, 'JITController.shared.startBackgroundAudioIfNeeded()',
        'JITController.shared.startBackgroundAudioIfNeeded()\n        if #available(iOS 16.1, *) {\n            Task { @MainActor in FirefoxDownloadActivityCoordinator.shared.startObserving() }\n        }')
    app_delegate.write_text(content, encoding="utf-8")

    info = source / "browser" / "Reynard" / "Resources" / "Info.plist"
    with info.open("rb") as fh:
        data = plistlib.load(fh)
    data["NSSupportsLiveActivities"] = True
    with info.open("wb") as fh:
        plistlib.dump(data, fh, sort_keys=False)

    patch_project(source / "browser" / "Reynard.xcodeproj" / "project.pbxproj")
    patch_release_tools(source)
    return stamp(source, config, revision)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--revision", type=int, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = bootstrap(args.source.resolve(), args.revision)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
