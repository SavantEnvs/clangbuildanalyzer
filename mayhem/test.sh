#!/usr/bin/env bash
#
# mayhem/test.sh — run ClangBuildAnalyzer's own golden-output test suite (upstream's
# `ClangBuildAnalyzer --test tests`, the same suite upstream CI runs). Each tests/<dir>
# aggregates its JSON traces (--stop) and diffs the analysis against
# tests/<dir>/_AnalysisOutputExpected.txt — a behavioral golden-output check.
# Runner is pre-built by mayhem/build.sh at build-tests/ClangBuildAnalyzer (normal flags).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "${SRC:-/mayhem}"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

RUNNER=build-tests/ClangBuildAnalyzer
if [ ! -x "$RUNNER" ]; then
  echo "test.sh: $RUNNER missing — mayhem/build.sh should have built it" >&2
  emit_ctrf "clangbuildanalyzer-selftest" 0 1
  exit 1
fi

expected=$(find tests -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l)
out=$(mktemp)
"$RUNNER" --test tests >"$out" 2>&1
rc=$?
cat "$out"

ran=$(grep -c "Running test '" "$out" || true)
failures=$(sed -n "s/.*had \([0-9]\+\) failures.*/\1/p" "$out" | tail -1)
: "${failures:=0}"
[ -z "$failures" ] && failures=0

if ! grep -q "tests done in" "$out" || [ "$ran" -ne "$expected" ] || [ "$ran" -eq 0 ]; then
  echo "test.sh: suite did not run all $expected tests (ran=$ran)" >&2
  emit_ctrf "clangbuildanalyzer-selftest" 0 "$expected"
  exit 1
fi
if [ "$rc" -ne 0 ] && [ "$failures" -eq 0 ]; then
  failures=$expected
fi

emit_ctrf "clangbuildanalyzer-selftest" $(( ran - failures )) "$failures"
