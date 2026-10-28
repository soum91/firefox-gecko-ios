"""Smoke tests for overlaying Firefox 159's BrowserKit SwiftPM target."""
from pathlib import Path
from tempfile import TemporaryDirectory
import importlib.util
import plistlib
import unittest

script = Path(__file__).resolve().parents[1] / "tools" / "apply_overlay.py"
spec = importlib.util.spec_from_file_location("apply_overlay", script)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class SourceOverlayTests(unittest.TestCase):
    def test_overlay_wires_swiftpm_binary_target_and_adapter(self):
        with TemporaryDirectory() as temp:
            root = Path(temp)
            firefox = root / "firefox-ios"
            webengine = firefox / "BrowserKit/Sources/WebEngine"
            (webengine / "WKWebview").mkdir(parents=True)
            (webengine / "Engine.swift").write_text("protocol Engine {}\n")
            (webengine / "WKWebview/WKEngine.swift").write_text("class WKEngine {}\n")
            (firefox / "BrowserKit/Package.swift").write_text(
                'let package = Package(\n    targets: [\n        .target(\n'
                '            name: "WebEngine",\n'
                '            dependencies: ["Common",\n'
                '                           .product(name: "GCDWebServers", package: "GCDWebServer")],\n'
                '        )\n    ]\n)\n'
            )
            binary = root / "GeckoView.xcframework"
            binary.mkdir()
            with (binary / "Info.plist").open("wb") as f:
                plistlib.dump({"CFBundlePackageType": "XFWK"}, f)
            adapter = root / "ReynardGeckoEngine.swift"
            adapter.write_text("import GeckoView\nfinal class Adapter {}\n")
            mod.apply(firefox, adapter, binary)
            manifest = (firefox / "BrowserKit/Package.swift").read_text()
            self.assertIn('.binaryTarget(name: "GeckoView"', manifest)
            self.assertIn('dependencies: ["Common", "GeckoView",', manifest)
            self.assertEqual((webengine / "ReynardGeckoEngine.swift").read_text(), adapter.read_text())

    def test_requires_real_binary_input(self):
        with TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(ValueError):
                mod.apply(root, root / "bad.swift", root / "missing.xcframework")

if __name__ == "__main__":
    unittest.main()
