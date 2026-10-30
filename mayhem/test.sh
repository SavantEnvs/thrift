#!/usr/bin/env bash
#
# mayhem/test.sh — RUN Thrift's own C++ Boost.Test suites and a compiler known-answer check (all
# built by mayhem/build.sh with normal flags). exit 0 = pass.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

BIN="$SRC/mayhem-build/tests/bin"
THRIFT="$SRC/mayhem-build/tests/compiler/cpp/bin/thrift"
[ -d "$BIN" ] && [ -x "$THRIFT" ] || { echo "test build missing — run mayhem/build.sh" >&2; emit_ctrf "boost-test" 0 1 0; exit 1; }

passed=0; failed=0
# No summary line (crash, neutered binary, missing runner) counts as one failure, so a program that
# silently exits 0 cannot pass.
run_suite() {
  local name="$1"; shift
  local out; out="$(timeout 900 "$BIN/$name" --report_level=short "$@" 2>&1)" || true
  local pass_n fail_n
  pass_n="$(grep -oE '[0-9]+ test cases? out of [0-9]+ passed' <<<"$out" | head -1 | awk '{print $1}')"
  fail_n="$(grep -oE '[0-9]+ test cases? out of [0-9]+ failed' <<<"$out" | head -1 | awk '{print $1}')"
  pass_n="${pass_n:-0}"; fail_n="${fail_n:-0}"
  if [ "$pass_n" -eq 0 ] && [ "$fail_n" -eq 0 ]; then
    echo "FAIL $name: no Boost.Test summary"; failed=$((failed+1)); return
  fi
  passed=$((passed + pass_n)); failed=$((failed + fail_n))
  echo "$name: $pass_n passed, $fail_n failed"
  [ "$fail_n" -eq 0 ] || grep -E 'error|failed' <<<"$out" | head -10
}

# The two locale cases need en_US/de_DE locales, which the image does not have.
run_suite UnitTests '--run_test=!ToStringTest/locale_en_US_int_to_string:!ToStringTest/locale_de_DE_floating_point_to_string'
for t in UnitTestsUuid AllProtocolsTest JSONProtoTest DebugProtoTest OptionalRequiredTest RecursiveTest \
         EnumTest AnnotationTest SpecializationTest TransportTest ZlibTest; do
  run_suite "$t"
done

# Compiler known answer: the generated C++ for the fuzz IDL declares the struct and its fields.
gen="$(mktemp -d "${TMPDIR:-/tmp}/thrift-gen.XXXXXX")"
if "$THRIFT" --gen cpp -o "$gen" "$SRC/test/FuzzTest.thrift" >/dev/null 2>&1 \
   && grep -q 'class BasicTypes' "$gen/gen-cpp/FuzzTest_types.h" \
   && grep -q 'std::string string_field;' "$gen/gen-cpp/FuzzTest_types.h" \
   && grep -q 'int64_t i64_field;' "$gen/gen-cpp/FuzzTest_types.h" \
   && [ "$("$THRIFT" -version 2>&1 | grep -c 'Thrift version')" -eq 1 ]; then
  echo "compiler-gen: 1 passed"; passed=$((passed+1))
else
  echo "FAIL compiler-gen"; failed=$((failed+1))
fi
rm -rf "$gen"

emit_ctrf "boost-test" "$passed" "$failed" 0
