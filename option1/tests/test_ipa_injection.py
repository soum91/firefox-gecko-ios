"""Local structural tests for the decrypted Firefox IPA bridge injection.

Run: python3 -m unittest discover -s option1/tests -v
Set FIREFOX_SOURCE_IPA to locally inspect the actual decrypted binary; CI does
not upload/require that IPA.
"""
import importlib.util
import os
from pathlib import Path
import plistlib
import struct
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools" / "prepare_firefox_ipa.py"
spec = importlib.util.spec_from_file_location("firefox_ipa", MODULE_PATH)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def executable(crypt_id=0, space=8192):
    # Thin arm64 Mach-O: one segment with one section, one encryption-info
    # command, one old signature command; first bytes of actual code at 4096.
    segment = bytearray(72 + 80)
    struct.pack_into("<II", segment, 0, 0x19, len(segment))
    struct.pack_into("<I", segment, 64, 1)
    struct.pack_into("<I", segment, 72 + 48, 4096)
    encryption = struct.pack("<IIIIII", 0x2C, 24, 0, 0, crypt_id, 0)
    signature = struct.pack("<IIII", 0x1D, 16, 6000, 200)
    commands = bytes(segment) + encryption + signature
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 2,
                         3, len(commands), 0, 0)
    data = bytearray(space)
    data[:32] = header
    data[32:32 + len(commands)] = commands
    data[4096:4100] = b"CODE"
    return bytes(data)


class InjectionTests(unittest.TestCase):
    def test_injects_bridge_without_overwriting_executable(self):
        original = executable()
        result = mod.inject_bridge(original)
        commands = list(mod.load_commands(result))
        self.assertEqual(sum(1 for c, _, _ in commands if c == 0x1D), 0)
        self.assertTrue(any(c == 0xC and mod.BRIDGE.encode() in result[o:o+n]
                            for c, o, n in commands))
        self.assertEqual(result[4096:], original[4096:])

    def test_refuses_encrypted_binary(self):
        with self.assertRaisesRegex(ValueError, "encrypted"):
            mod.inject_bridge(executable(crypt_id=1))

    def test_refuses_duplicate_injection(self):
        patched = mod.inject_bridge(executable())
        with self.assertRaisesRegex(ValueError, "already injected"):
            mod.inject_bridge(patched)

    def test_original_firefox_ipa_optional(self):
        path = os.environ.get("FIREFOX_SOURCE_IPA")
        if not path:
            self.skipTest("Decrypted IPA stays outside public CI")
        with zipfile.ZipFile(path) as archive:
            info = plistlib.loads(archive.read("Payload/Client.app/Info.plist"))
            self.assertEqual(info["CFBundleIdentifier"], "org.mozilla.ios.Firefox")
            self.assertEqual(info["CFBundleShortVersionString"], "159.0")
            self.assertEqual(info["CFBundleVersion"], "78949")
            original = archive.read("Payload/Client.app/Client")
            patched = mod.inject_bridge(original)
            self.assertGreater(len(patched), 10000)
            self.assertEqual(len(patched), len(original))


if __name__ == "__main__":
    unittest.main()
