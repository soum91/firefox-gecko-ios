import tempfile
import unittest
from pathlib import Path

from scripts.stamp_version import replace_setting, stamp, version_for


class StampVersionTests(unittest.TestCase):
    def test_initial_release(self):
        self.assertEqual(version_for("159.0", 78949, 1), ("159.0.1", 78950))

    def test_future_release(self):
        self.assertEqual(version_for("160.0", 80000, 2), ("160.0.2", 80002))

    def test_rejects_invalid_version(self):
        with self.assertRaises(ValueError):
            version_for("159.0.1", 78949, 1)

    def test_missing_setting_is_error(self):
        with self.assertRaises(RuntimeError):
            replace_setting("CURRENT_VERSION = 159.0\n", "CURRENT_BUILD", "1")

    def test_project_stamp(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            xcconfig = root / "browser" / "Configuration" / "Reynard.xcconfig"
            xcconfig.parent.mkdir(parents=True)
            xcconfig.write_text("CURRENT_VERSION = 0.18.0\nCURRENT_BUILD = UNKNOWN\nAPP_DISPLAY_NAME = Reynard\n")
            manifest = stamp(root, {"upstream_firefox_version": "159.0", "upstream_firefox_build": 78949,
                                    "app_display_name": "Firefox", "development_bundle_id": "com.soum91.FirefoxGecko"}, 1)
            self.assertEqual(manifest["version"], "159.0.1")
            self.assertIn("CURRENT_BUILD = 78950", xcconfig.read_text())


if __name__ == "__main__":
    unittest.main()
