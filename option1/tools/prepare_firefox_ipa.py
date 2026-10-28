#!/usr/bin/env python3
"""Prepare a user-supplied decrypted Firefox IPA for an experimental injected bridge.

Preserves Firefox's actual Client.app, icons, interfaces, and bundle ID.
No binary IPA is stored or published by this repository. Re-signing does not
preserve Mozilla's provisioning profile, Team ID or browser entitlements.
This tool does NOT itself provide a Gecko implementation.
"""
from __future__ import annotations

import argparse
import plistlib
import shutil
import struct
import zipfile
from pathlib import Path

APP = "Payload/Client.app/"
LOAD_DYLIB = 0xC
CODE_SIGNATURE = 0x1D
SEGMENT_64 = 0x19
HEADER_SIZE = 32
BRIDGE = "@executable_path/Frameworks/FirefoxReynardBridge.dylib"


def load_commands(binary: bytes):
    if len(binary) < HEADER_SIZE or binary[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Expected decrypted thin arm64 Mach-O Client executable")
    count = struct.unpack_from("<I", binary, 16)[0]
    position = HEADER_SIZE
    for _ in range(count):
        if position + 8 > len(binary):
            raise ValueError("Truncated Mach-O load commands")
        command, size = struct.unpack_from("<II", binary, position)
        if size < 8 or position + size > len(binary):
            raise ValueError("Invalid Mach-O load command")
        yield command, position, size
        position += size


def inject_bridge(binary: bytes):
    original = bytearray(binary)
    commands = list(load_commands(binary))
    if any(command == LOAD_DYLIB and BRIDGE.encode() in binary[pos:pos+size]
           for command, pos, size in commands):
        raise ValueError("Bridge already injected")
    encryption = [struct.unpack_from("<I", original, pos + 16)[0]
                  for command, pos, size in commands if command == 0x2C and size >= 24]
    if any(encryption):
        raise ValueError("Source Firefox executable is encrypted")
    new_name = BRIDGE.encode("utf-8") + b"\x00"
    command_size = (24 + len(new_name) + 7) & ~7
    new_command = struct.pack("<IIIIII", LOAD_DYLIB, command_size, 24, 0, 0, 0)
    new_command += new_name
    new_command = new_command.ljust(command_size, b"\x00")
    # A removed CodeDirectory load command does not confer a valid signature.
    remaining = [binary[pos:pos+size] for command, pos, size in commands
                 if command != CODE_SIGNATURE]
    replacement = b"".join(remaining) + new_command
    first_data = len(binary)
    for command, pos, size in commands:
        if command != SEGMENT_64 or size < 72:
            continue
        nsects = struct.unpack_from("<I", binary, pos + 64)[0]
        if 72 + nsects * 80 > size:
            raise ValueError("Invalid Mach-O sections")
        for index in range(nsects):
            section = pos + 72 + index * 80
            offset = struct.unpack_from("<I", binary, section + 48)[0]
            if offset:
                first_data = min(first_data, offset)
    current_end = HEADER_SIZE + struct.unpack_from("<I", binary, 20)[0]
    end = HEADER_SIZE + len(replacement)
    if end > first_data or (end > current_end and any(binary[current_end:end])):
        raise ValueError("Insufficient Mach-O header padding; refusing overwrite")
    original[HEADER_SIZE:max(current_end, end)] = replacement.ljust(
        max(current_end, end) - HEADER_SIZE, b"\x00")
    struct.pack_into("<II", original, 16, len(remaining) + 1, len(replacement))
    if not any(cmd == LOAD_DYLIB and BRIDGE.encode() in original[pos:pos+size]
               for cmd, pos, size in load_commands(original)):
        raise AssertionError("Bridge load command was not inserted")
    return bytes(original)


def prepare(source: Path, bridge: Path, output: Path, omit_extensions: bool = False):
    if not bridge.is_file() or bridge.stat().st_size < HEADER_SIZE:
        raise ValueError("Supply a compiled arm64 iOS bridge dylib, not source code")
    if bridge.read_bytes()[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Bridge is not a thin arm64 Mach-O library")
    with zipfile.ZipFile(source) as zin:
        entries = zin.infolist()
        if len(entries) != len({item.filename for item in entries}):
            raise ValueError("Duplicate IPA members")
        if APP + "Info.plist" not in zin.namelist():
            raise ValueError("Not Firefox's Client.app IPA")
        info = plistlib.loads(zin.read(APP + "Info.plist"))
        if any(info.get(key) != expected for key, expected in (
            ("CFBundleIdentifier", "org.mozilla.ios.Firefox"),
            ("CFBundleExecutable", "Client"),
            ("CFBundleShortVersionString", "159.0"),
            ("CFBundleVersion", "78949"),
        )):
            raise ValueError("Requires original decrypted Firefox iOS 159.0 (78949)")
        patched = inject_bridge(zin.read(APP + "Client"))
        output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=6,
                             allowZip64=True) as zout:
            for item in entries:
                name = item.filename
                if (omit_extensions and name.startswith(APP + "PlugIns/")):
                    continue
                if ("/_CodeSignature/" in name or name.endswith("embedded.mobileprovision")
                    or "/SC_Info/" in name):
                    continue
                data = patched if name == APP + "Client" else zin.read(item)
                zout.writestr(item, data)
            library_path = APP + "Frameworks/FirefoxReynardBridge.dylib"
            if library_path in zin.namelist():
                raise ValueError("IPA already contains a bridge")
            item = zipfile.ZipInfo(library_path)
            item.create_system = 3
            item.external_attr = 0o100755 << 16
            zout.writestr(item, bridge.read_bytes())
    with zipfile.ZipFile(output) as z:
        assert z.testzip() is None
        assert plistlib.loads(z.read(APP + "Info.plist"))["CFBundleIdentifier"] == "org.mozilla.ios.Firefox"
        assert z.read(APP + "Client") != b""
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original_ipa", type=Path)
    parser.add_argument("compiled_bridge_dylib", type=Path)
    parser.add_argument("output_ipa", type=Path)
    parser.add_argument("--omit-extensions", action="store_true",
                        help="Diagnostic only: excludes Firefox's original app extensions")
    args = parser.parse_args()
    out = prepare(args.original_ipa, args.compiled_bridge_dylib,
                  args.output_ipa, args.omit_extensions)
    print(f"Experimental Firefox shell, NOT yet a working Gecko integration: {out}")
    print("Re-sign all nested code. Original Mozilla entitlements are NOT preserved.")


if __name__ == "__main__":
    main()
