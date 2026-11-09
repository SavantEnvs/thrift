#!/usr/bin/env bash
#
# mayhem/build.sh — mining layer: the sanitized + coverage-instrumented thrift compiler (the file-input
# target `thrift-gv`, which runs `--gen gv` over an IDL file), plus the normally-built C++ test suite
# and compiler (mayhem/test.sh only RUNS them).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# All build trees live under one directory that ignores itself, so `git clean -ffdX` removes it
# (upstream's /build is tracked source and can't hold ours).
B="$SRC/mayhem-build"
mkdir -p "$B"
printf '*\n' > "$B/.gitignore"

# Thrift libraries that matter to the harnesses; everything else is off.
COMMON_OPTS=(-G Ninja -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TUTORIALS=OFF
  -DWITH_JAVA=OFF -DWITH_JAVASCRIPT=OFF -DWITH_NODEJS=OFF -DWITH_PYTHON=OFF
  -DWITH_LIBEVENT=OFF -DWITH_QT5=OFF -DWITH_OPENSSL=OFF)

# 1) Test build (project's NORMAL flags): compiler + C++ library + boost unit tests.
TEST_TARGETS=(thrift-compiler UnitTests UnitTestsUuid AllProtocolsTest JSONProtoTest DebugProtoTest
  OptionalRequiredTest RecursiveTest EnumTest AnnotationTest SpecializationTest TransportTest ZlibTest)
cmake -S "$SRC" -B "$B/tests" "${COMMON_OPTS[@]}" -DBUILD_COMPILER=ON -DBUILD_TESTING=ON \
  -DWITH_CPP=ON -DWITH_ZLIB=ON -DWITH_C_GLIB=OFF \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build "$B/tests" -j"$MAYHEM_JOBS" --target "${TEST_TARGETS[@]}"
THRIFT="$B/tests/compiler/cpp/bin/thrift"
[ -x "$THRIFT" ] || { echo "thrift compiler missing at $THRIFT" >&2; exit 1; }

# 2) Sanitized compiler for the fuzz target: the whole compiler (parser + generators) is instrumented.
# fuzzer-no-link adds SanCov edge counters (their runtime comes with ASan). lsan_off.o disables leak
# detection: the compiler never frees its parse tree.
FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
OBJ="$B/obj"; mkdir -p "$OBJ"
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
cmake -S "$SRC" -B "$B/gv" "${COMMON_OPTS[@]}" -DBUILD_COMPILER=ON -DBUILD_TESTING=OFF \
  -DWITH_CPP=OFF -DWITH_C_GLIB=OFF \
  -DCMAKE_C_FLAGS="$FLAGS" -DCMAKE_CXX_FLAGS="$FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$FLAGS $OBJ/lsan_off.o"
cmake --build "$B/gv" -j"$MAYHEM_JOBS" --target thrift-compiler
GVBIN="$B/gv/compiler/cpp/bin/thrift"
[ -x "$GVBIN" ] || { echo "sanitized thrift compiler missing at $GVBIN" >&2; exit 1; }
cp "$GVBIN" "$SRC/thrift-gv"
