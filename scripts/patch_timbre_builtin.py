#!/usr/bin/env python3
"""Let Gecko's iOS built-in add-on validator accept Timbre.

Reynard's GeckoViewWebExtension.sys.mjs only accepts built-in add-ons from
resource://android/... or from an allowlist of resource://app/extensions/
folders (readerview, fxawebchannel, fetchdock). Timbre was never on that
list, which is why resource://app/extensions/timbre/ was refused and every
later URI workaround failed. FetchDock loads from resource://app/, so Timbre
uses the same mapping:

  resource://app/extensions/timbre/  source builds (Swift registers this)
  resource://app/ext/timbre/         repackaged builds, where the compiled
                                     Swift literal had to keep its length
"""
from pathlib import Path

ANCHOR = '    const isIOSBuiltInResource =\n'
ALLOWED = (
    'resource://app/extensions/timbre/',
    'resource://app/ext/timbre/',
)
LINES = ''.join(f'      uri.spec === "{spec}" ||\n' for spec in ALLOWED)


def patch(root):
    paths = list(Path(root).rglob("GeckoViewWebExtension.sys.mjs"))
    assert len(paths) == 1, f"Expected one Gecko built-in module, found {len(paths)}"
    path = paths[0]
    text = path.read_text()
    if ANCHOR + LINES not in text:
        assert text.count(ANCHOR) == 1, "Unexpected Gecko validator"
        text = text.replace(ANCHOR, ANCHOR + LINES)
        path.write_text(text)
    text = path.read_text()
    for spec in ALLOWED:
        assert f'uri.spec === "{spec}"' in text, spec
    print(f"Verified Timbre built-in validator in {path}", flush=True)


if __name__ == "__main__":
    import sys
    patch(sys.argv[1])
