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

    def test_push_never_recompiles_an_engine_that_already_exists(self):
        workflow = BUILD.read_text(encoding="utf-8")
        self.assertIn("actions/cache/restore@v4", workflow)
        self.assertIn("actions/cache/save@v4", workflow)
        self.assertIn(".github/scripts/fetch-gecko-engine.sh", workflow)
        self.assertIn("cancel-in-progress: false", workflow)
        # The compile is skipped whenever a reusable engine was unpacked.
        compile_step = workflow[workflow.index("- name: Compile Gecko engine"):]
        compile_step = compile_step[:compile_step.index("- name:", 10)]
        self.assertIn("steps.engine-reuse.outputs.ready != 'true'", compile_step)
        # The engine is cached before any GeckoView or Firefox step can fail.
        self.assertLess(
            workflow.index("Cache compiled Gecko engine immediately"),
            workflow.index("Build original Reynard GeckoView Swift framework"),
        )
        self.assertIn("reynard-engine-key.txt", workflow)

    def test_engines_compiled_by_the_reynard_fork_are_reused(self):
        workflow = BUILD.read_text(encoding="utf-8")
        self.assertIn(".github/scripts/gecko-engine-key.sh reynard-source", workflow)
        self.assertIn("steps.engine-key.outputs.content", workflow)
        fetch = (ROOT / ".github/scripts/fetch-gecko-engine.sh").read_text(encoding="utf-8")
        self.assertIn("soum91/reynard-browser", fetch)
        self.assertLess(fetch.index("if try_release"), fetch.index("if try_artifacts"))
        # The build flags in the key must match the ones this workflow compiles with.
        self.assertIn("build-gecko.sh --use-sccache --auto-clobber", workflow)

    def test_failures_publish_real_compiler_errors(self):
        for path in (BUILD, RESUME):
            workflow = path.read_text(encoding="utf-8")
            self.assertIn(".github/scripts/surface-build-errors.sh", workflow, path.name)
        script = ROOT / ".github/scripts/surface-build-errors.sh"
        self.assertTrue(script.is_file())
        self.assertIn("::error title=", script.read_text(encoding="utf-8"))

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
