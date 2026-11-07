#!/usr/bin/env python3
"""Make Gecko honour the xpinstall.signatures.required pref.

Reynard builds Gecko with MOZ_REQUIRE_SIGNING, which AddonSettings turns into
a hard constant, so the app's "Require signed add-ons" switch did nothing.
The developer build ships loose JS modules, so flipping the constant in
AppConstants.sys.mjs is enough: AddonSettings then reads the pref, which the
switch sets. No Gecko recompile needed.
"""
from pathlib import Path

OLD = "  MOZ_REQUIRE_SIGNING: true,\n"
NEW = "  MOZ_REQUIRE_SIGNING: false,\n"


def patch(root):
    paths = list(Path(root).rglob("AppConstants.sys.mjs"))
    assert len(paths) == 1, f"Expected one AppConstants module, found {len(paths)}"
    path = paths[0]
    text = path.read_text()
    if NEW not in text:
        assert text.count(OLD) == 1, "Unexpected AppConstants signing constant"
        path.write_text(text.replace(OLD, NEW))
    assert NEW in path.read_text()
    print(f"Verified optional add-on signing in {path}", flush=True)


if __name__ == "__main__":
    import sys
    patch(sys.argv[1])
