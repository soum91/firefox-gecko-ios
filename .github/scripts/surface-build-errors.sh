#!/bin/bash
# Turn compiler errors buried in build logs into GitHub annotations.
# Annotations show on the public run page without signing in, so whoever
# fixes the build sees the real error instead of "exit code 65".
#
# GitHub shows at most 10 error annotations per step, so each failing log
# becomes ONE multi-line annotation, and logs that built fine are skipped.
#
# Usage: surface-build-errors.sh <log> [<log> ...]

set -uo pipefail

limit=40
found=0
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
pattern='(^|[[:space:]:])(error|fatal error)(\[[A-Z0-9]+\])?:|^error:|\*\* BUILD FAILED \*\*|^make(\[[0-9]+\])?: \*\*\*|Traceback \(most recent call last\)|The following build commands failed'

{
  echo "## Build errors"
  echo
} >> "$summary"

for log in "$@"; do
  [ -s "$log" ] || continue
  name=$(basename "$log")
  # Xcode/clang/swiftc/rustc/mach error lines, deduplicated, original order,
  # with the runner's checkout path stripped so lines stay short.
  errors=$(grep -E "$pattern" "$log" \
    | sed -E 's/^[[:space:]]+//; s#/Users/runner/work/[^/]+/[^/]+/##g' \
    | awk '!seen[$0]++' | head -n "$limit")
  if [ -z "$errors" ]; then
    # A log that ends in success is not where the failure is.
    if tail -n 30 "$log" | grep -q 'BUILD SUCCEEDED'; then
      continue
    fi
    errors=$(tail -n 20 "$log" | sed -E 's#/Users/runner/work/[^/]+/[^/]+/##g')
    label="last lines"
  else
    label="errors"
  fi
  found=1
  {
    echo "### $name ($label)"
    echo '```'
    echo "$errors"
    echo '```'
  } >> "$summary"
  # One annotation per log; %0A is a newline inside an annotation.
  msg=$(printf '%s\n' "$errors" | cut -c1-400 | sed 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')
  echo "::error title=$name ($label)::${msg:0:60000}"
done

if [ "$found" -eq 0 ]; then
  echo "No failing build log found; the failure happened outside a compile step." >> "$summary"
fi
exit 0
