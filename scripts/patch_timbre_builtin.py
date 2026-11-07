#!/usr/bin/env python3
"""Allow the exact bundled Timbre URI in Gecko's iOS built-in validator."""
from pathlib import Path

OLD = '    const isIOSBuiltInResource =\n'
NEW = OLD + '      uri.spec === "resource://android/timbre/" ||\n'

def patch(root):
    paths = list(Path(root).rglob("GeckoViewWebExtension.sys.mjs"))
    assert len(paths) == 1, f"Expected one Gecko built-in module, found {len(paths)}"
    path = paths[0]
    text = path.read_text()
    if NEW not in text:
        assert text.count(OLD) == 1, "Unexpected Gecko validator"
        text = text.replace(OLD, NEW)
        path.write_text(text)
    assert NEW in path.read_text()
    print(f"Verified exact Timbre built-in validator in {path}", flush=True)

if __name__ == "__main__":
    import sys
    patch(sys.argv[1])
