#!/usr/bin/env python3
"""Stamp numeric Firefox-style versions into a checked-out Reynard Xcode project.

Revision is a monotonically increasing CI release counter, starting at 1.
The upstream Firefox version/build are references, not claims of Mozilla signing.
"""

import argparse
import json
from pathlib import Path
import re


def version_for(base: str, original_build: int, revision: int) -> tuple[str, int]:
    if not re.fullmatch(r"[0-9]+\.[0-9]+", base):
        raise ValueError("Firefox version must be MAJOR.MINOR")
    if revision < 1 or original_build < 1:
        raise ValueError("revision and original build must be positive")
    return f"{base}.{revision}", original_build + revision


def replace_setting(data: str, key: str, value: str) -> str:
    pattern = rf"(?m)^{re.escape(key)} = .*?$"
    updated, count = re.subn(pattern, f"{key} = {value}", data)
    if count != 1:
        raise RuntimeError(f"expected one {key} setting; found {count}")
    return updated


def stamp(source: Path, config: dict, revision: int) -> dict:
    public, internal = version_for(
        config["upstream_firefox_version"],
        int(config["upstream_firefox_build"]),
        revision,
    )
    path = source / "browser" / "Configuration" / "Reynard.xcconfig"
    data = path.read_text(encoding="utf-8")
    for key, value in (
        ("CURRENT_VERSION", public),
        ("CURRENT_BUILD", str(internal)),
        ("APP_DISPLAY_NAME", config["app_display_name"]),
    ):
        data = replace_setting(data, key, value)
    if "APP_BUNDLE_ID = " not in data:
        data += f"\nAPP_BUNDLE_ID = {config['development_bundle_id']}\n"
    path.write_text(data, encoding="utf-8")
    return {"version": public, "buildVersion": str(internal), "upstream": config["upstream_firefox_version"]}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="Checked-out Reynard repository root")
    parser.add_argument("--revision", type=int, required=True)
    parser.add_argument("--config", type=Path, default=Path(__file__).resolve().parents[1] / "config" / "build.json")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    config = json.loads(args.config.read_text(encoding="utf-8"))
    result = stamp(args.source, config, args.revision)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
