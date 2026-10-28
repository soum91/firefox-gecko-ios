from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZipFile
import importlib.util
import plistlib
import unittest


source = Path(__file__).resolve().parents[1] / "scripts/verify_firefox_gecko_ipa.py"
spec = importlib.util.spec_from_file_location("verify_firefox_gecko_ipa", source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FirefoxGeckoIPATests(unittest.TestCase):
    def build_ipa(self, path, gecko=True, widget=True, xul=True, live=True):
        info = {
            "CFBundleExecutable": "Client",
            "CFBundleDisplayName": "Firefox",
            "CFBundleIdentifier": "com.soum91.FirefoxGecko",
            "NSSupportsLiveActivities": live,
        }
        with ZipFile(path, "w") as archive:
            archive.writestr("Payload/Client.app/Info.plist", plistlib.dumps(info))
            archive.writestr("Payload/Client.app/Client", b"client executable")
            if gecko:
                archive.writestr("Payload/Client.app/Frameworks/GeckoView.framework/GeckoView", b"gecko")
            if xul:
                archive.writestr("Payload/Client.app/Frameworks/XUL.dylib", b"xul")
            if widget:
                extension = {"NSExtension": {
                    "NSExtensionPointIdentifier": "com.apple.widgetkit-extension"
                }}
                archive.writestr("Payload/Client.app/PlugIns/FirefoxDownloads.appex/Info.plist",
                                 plistlib.dumps(extension))

    def test_valid_structure(self):
        with TemporaryDirectory() as temp:
            ipa = Path(temp) / "Firefox-Gecko.ipa"
            self.build_ipa(ipa)
            self.assertEqual(module.verify(ipa), "com.soum91.FirefoxGecko")

    def test_rejects_missing_gecko(self):
        with TemporaryDirectory() as temp:
            ipa = Path(temp) / "Firefox-Gecko.ipa"
            self.build_ipa(ipa, gecko=False)
            with self.assertRaisesRegex(ValueError, "GeckoView.framework"):
                module.verify(ipa)

    def test_rejects_missing_xul(self):
        with TemporaryDirectory() as temp:
            ipa = Path(temp) / "Firefox-Gecko.ipa"
            self.build_ipa(ipa, xul=False)
            with self.assertRaisesRegex(ValueError, "XUL.dylib"):
                module.verify(ipa)

    def test_rejects_missing_widget(self):
        with TemporaryDirectory() as temp:
            ipa = Path(temp) / "Firefox-Gecko.ipa"
            self.build_ipa(ipa, widget=False)
            with self.assertRaisesRegex(ValueError, "WidgetKit"):
                module.verify(ipa)

    def test_rejects_missing_live_activity_declaration(self):
        with TemporaryDirectory() as temp:
            ipa = Path(temp) / "Firefox-Gecko.ipa"
            self.build_ipa(ipa, live=False)
            with self.assertRaisesRegex(ValueError, "Live Activities"):
                module.verify(ipa)
