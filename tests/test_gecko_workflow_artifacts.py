"""Keep expensive Gecko compilation outputs recoverable across CI failures."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".github/workflows/build-gecko-dev-framework.yml"
RESUME = ROOT / ".github/workflows/resume-geckoview-from-artifact.yml"


class GeckoArtifactWorkflowTests(unittest.TestCase):
    def test_engine_archive_is_uploaded_before_framework_build(self):
        workflow = BUILD.read_text(encoding="utf-8")
        self.assertLess(
            workflow.index("Upload compiled Gecko engine (independent of GeckoView)"),
            workflow.index("Build original Reynard GeckoView Swift framework"),
        )
        self.assertIn("gecko-engine-dist.tar.gz", workflow)
        self.assertIn("Gecko-iOS-arm64-compiled-engine-dist", workflow)
        self.assertIn("Gecko-iOS-arm64-raw-binaries-fallback", workflow)
        self.assertIn("BUILD_LIBRARY_FOR_DISTRIBUTION=NO", workflow)

    def test_resume_uses_the_exact_engine_archive_name_and_toolchain(self):
        workflow = RESUME.read_text(encoding="utf-8")
        self.assertIn("Gecko-iOS-arm64-compiled-engine-dist", workflow)
        self.assertIn("gecko-engine-dist.tar.gz", workflow)
        self.assertIn("run-id: ${{ inputs.engine_run_id }}", workflow)
        self.assertIn("xcode-version: '26.5'", workflow)
        self.assertIn("BUILD_LIBRARY_FOR_DISTRIBUTION=NO", workflow)
        self.assertNotIn("./tools/development/build-gecko.sh", workflow)


if __name__ == "__main__":
    unittest.main()
