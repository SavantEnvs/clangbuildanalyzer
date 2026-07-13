#!/usr/bin/env bash
#
# mayhem/build.sh — build ClangBuildAnalyzer fuzz targets + the upstream test binary.
#
#   build/ClangBuildAnalyzer         sanitized + DWARF  -> target `clangbuildanalyzer` (--analyze @@)
#   build/fuzz_Lowercase             sanitized + libFuzzer -> target `lowercase` (utils::Lowercase)
#   build/fuzz_Lowercase-standalone  run-once reproducer for the libFuzzer harness
#   build-tests/ClangBuildAnalyzer   normal flags -> runner for mayhem/test.sh (--test tests)
# Sources are compiled directly (the same TU set as upstream's CMakeLists.txt) — no network,
# no upstream edits.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "${SRC:-/mayhem}"

C_SRC=(
  src/external/cwalk/cwalk.c
  src/external/inih/ini.c
  src/external/xxHash/xxhash.c
)
CXX_SRC=(
  src/Analysis.cpp
  src/Arena.cpp
  src/BuildEvents.cpp
  src/Colors.cpp
  src/main.cpp
  src/Utils.cpp
  src/external/enkiTS/TaskScheduler.cpp
  src/external/inih/cpp/INIReader.cpp
  src/external/llvm-Demangle/lib/Demangle.cpp
  src/external/llvm-Demangle/lib/ItaniumDemangle.cpp
  src/external/llvm-Demangle/lib/MicrosoftDemangle.cpp
  src/external/llvm-Demangle/lib/MicrosoftDemangleNodes.cpp
  src/external/simdjson/simdjson.cpp
)
STD="-std=c++17"

mkdir -p build build-tests /tmp/obj-san /tmp/obj-rel

build_analyzer() {  # $1 = obj dir, $2 = out binary, $3... = flags
  local objdir="$1" out="$2"; shift 2
  local flags=("$@") objs=() pids=()
  for f in "${C_SRC[@]}"; do
    local o="$objdir/$(basename "$f").o"
    # shellcheck disable=SC2086
    $CC "${flags[@]}" -w -c "$f" -o "$o" & pids+=($!)
    objs+=("$o")
  done
  for f in "${CXX_SRC[@]}"; do
    local o="$objdir/$(basename "$f").o"
    # shellcheck disable=SC2086
    $CXX $STD "${flags[@]}" -w -c "$f" -o "$o" & pids+=($!)
    objs+=("$o")
  done
  local rc=0 p
  for p in "${pids[@]}"; do wait "$p" || rc=1; done
  [ "$rc" -eq 0 ] || { echo "build.sh: compile failed for $out" >&2; return 1; }
  $CXX $STD "${flags[@]}" "${objs[@]}" -lpthread -o "$out"
}

# 1) Sanitized analyzer (the fuzzed CLI target) — project code instrumented, DWARF < 4.
# shellcheck disable=SC2086
build_analyzer /tmp/obj-san build/ClangBuildAnalyzer $SANITIZER_FLAGS $DEBUG_FLAGS

# 2) libFuzzer harness over utils::Lowercase (+ its standalone run-once reproducer).
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -w -c src/external/cwalk/cwalk.c -o /tmp/cwalk_fuzz.o
# shellcheck disable=SC2086
$CXX $STD $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -w -I src \
    mayhem/fuzz_Lowercase.cpp src/Utils.cpp /tmp/cwalk_fuzz.o -o build/fuzz_Lowercase
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
# shellcheck disable=SC2086
$CXX $STD $SANITIZER_FLAGS $DEBUG_FLAGS -w -I src \
    mayhem/fuzz_Lowercase.cpp src/Utils.cpp /tmp/cwalk_fuzz.o /tmp/standalone_main.o \
    -o build/fuzz_Lowercase-standalone

# 3) Test runner with NORMAL flags (clean, independent build) for mayhem/test.sh.
# shellcheck disable=SC2086
build_analyzer /tmp/obj-rel build-tests/ClangBuildAnalyzer -O2 $COVERAGE_FLAGS

echo "build.sh: built build/ClangBuildAnalyzer, build/fuzz_Lowercase(+standalone), build-tests/ClangBuildAnalyzer"
