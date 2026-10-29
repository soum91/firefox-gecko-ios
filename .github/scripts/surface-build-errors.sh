#!/bin/bash
# Turn compiler errors buried in build logs into GitHub annotations.
# Annotations show on the public run page without signing in, so whoever
# fixes the build sees the real error instead of "exit code 65".
#
# Usage: surface-build-errors.sh <log> [<log> ...]

set -uo pipefail

limit=25
found=0
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

{
  echo "## Build errors"
  echo
} >> "$summary"

for log in "$@"; do
  [ -s "$log" ] || continue
  name=$(basename "$log")
  # Xcode/clang/swiftc/rustc/mach error lines, deduplicated, original order.
  errors=$(grep -E '(^|[[:space:]:])(error|fatal error)(\[[A-Z0-9]+\])?:|^error:|\*\* BUILD FAILED \*\*|^make(\[[0-9]+\])?: \*\*\*|Traceback \(most recent call last\)' "$log" \
    | sed -E 's/^[[:space:]]+//' | awk '!seen[$0]++' | head -n "$limit")
  if [ -z "$errors" ]; then
    errors=$(tail -n 15 "$log")
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
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Annotation text must stay on one line and under GitHub's size limit.
    msg=$(printf '%s' "$line" | cut -c1-900 | sed 's/%/%25/g')
    echo "::error title=$name::$msg"
  done <<<"$errors"
done

if [ "$found" -eq 0 ]; then
  echo "No build logs were written; the failure happened before compilation." >> "$summary"
fi
exit 0
