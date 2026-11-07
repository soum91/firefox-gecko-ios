"""Regression checks for the native Firefox Timbre entry points."""
from pathlib import Path
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "Client" / "GeckoAddons.swift").read_text()


class TimbreMenuTests(unittest.TestCase):
    def test_installed_timbre_does_not_depend_on_gecko_action_event(self):
        self.assertIn("action(for: addon) != nil || addon.id == Self.timbreID", SOURCE)
        self.assertIn("manager.action(for: addon) != nil || addon.id == GeckoAddonManager.timbreID", SOURCE)

    def test_click_dispatches_browser_action_even_without_cached_action(self):
        self.assertIn('let kind = action(for: addon)?.kind ?? .browser', SOURCE)
        self.assertIn('AddonRuntime.shared.clickAction(kind: kind, addon: addon)', SOURCE)
        self.assertIn('if try await self.openActionPopup(for: addon) { return }', SOURCE)

    def test_popup_fallback_uses_fresh_extension_origin(self):
        self.assertIn('base.scheme?.lowercased() == "moz-extension"', SOURCE)
        self.assertIn('popup.path = "/popup/popup.html"', SOURCE)
        self.assertIn('current = try await self.refreshTimbre() ?? addon', SOURCE)
        self.assertIn('self.presentPopup(url: url)', SOURCE)

    def test_missing_gecko_policy_gets_one_non_destructive_recovery(self):
        self.assertIn('if !self.timbreRecoveryAttempted', SOURCE)
        self.assertIn('AddonRuntime.shared.disable(addon)', SOURCE)
        self.assertIn('AddonRuntime.shared.enable(addon)', SOURCE)
        self.assertNotIn('AddonRuntime.shared.uninstall(addon)', SOURCE[SOURCE.index('private func reactivateTimbre'):SOURCE.index('func openOptions')])
        self.assertIn('disabled flags:', SOURCE)

    def test_floating_button_uses_same_open_path(self):
        self.assertIn("manager.click(timbre)", SOURCE)
        self.assertNotIn("Timbre is still starting. Try again in a moment.", SOURCE)


if __name__ == "__main__":
    unittest.main()
