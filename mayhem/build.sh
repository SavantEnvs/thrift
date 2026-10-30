#!/usr/bin/env bash
#
# mayhem/build.sh — build Apache Thrift's libFuzzer harnesses (C++ and C GLib) with the project
# instrumented, plus a normally-built C++ test suite (mayhem/test.sh only RUNS it).
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

# 2) Sanitized C++ library, generated code for the fuzz IDL.
# fuzzer-no-link instruments the library and harness for coverage; the engine is linked per binary.
# -fno-sanitize=enum: thrift reads wire bytes straight into `enum TType` (TBinaryProtocol.tcc:265),
# which UBSan's enum check halts on for nearly every non-trivial input and would mask everything else.
FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link -fno-sanitize=enum $DEBUG_FLAGS"
cmake -S "$SRC" -B "$B/cpp" "${COMMON_OPTS[@]}" -DBUILD_COMPILER=OFF -DTHRIFT_COMPILER="$THRIFT" \
  -DBUILD_TESTING=OFF -DWITH_CPP=ON -DWITH_ZLIB=OFF -DWITH_C_GLIB=OFF \
  -DCMAKE_C_FLAGS="$FLAGS" -DCMAKE_CXX_FLAGS="$FLAGS"
cmake --build "$B/cpp" -j"$MAYHEM_JOBS" --target thrift

mkdir -p "$B/gen"
"$THRIFT" --gen cpp -o "$B/gen" "$SRC/test/FuzzTest.thrift"
"$THRIFT" --gen c_glib -o "$B/gen" "$SRC/test/v0.16/FuzzTestNoUuid.thrift"

# 3) Harness objects shared by the fuzzer and standalone links.
OBJ="$B/obj"; mkdir -p "$OBJ"
# shellcheck disable=SC2086
$CC $FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
# shellcheck disable=SC2086
$CXX $FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"

CPP_INC=(-I"$SRC/lib/cpp/src" -I"$B/cpp/lib/cpp/src" -I"$B/cpp" -I"$B/gen" -I"$SRC/lib/cpp/test/fuzz")
# shellcheck disable=SC2086
$CXX $FLAGS -std=c++17 "${CPP_INC[@]}" -c "$B/gen/gen-cpp/FuzzTest_types.cpp" -o "$OBJ/FuzzTest_types.o"
LIBTHRIFT="$(find "$B/cpp" \( -name libthrift.a -o -name libthriftd.a \) | head -1)"
[ -n "$LIBTHRIFT" ] || { echo "libthrift.a missing" >&2; exit 1; }

for h in FuzzParseBinary FuzzParseCompact FuzzParseJson FuzzRoundtripBinary FuzzRoundtripCompact FuzzRoundtripJson; do
  # shellcheck disable=SC2086
  $CXX $FLAGS -std=c++17 -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION "${CPP_INC[@]}" \
    -c "$SRC/lib/cpp/test/fuzz/$h.cpp" -o "$OBJ/$h.o"
  # shellcheck disable=SC2086
  $CXX $FLAGS "$OBJ/$h.o" "$OBJ/FuzzTest_types.o" "$OBJ/lsan_off.o" "$LIBTHRIFT" \
    $LIB_FUZZING_ENGINE -o "$SRC/$h"
  # shellcheck disable=SC2086
  $CXX $FLAGS "$OBJ/$h.o" "$OBJ/FuzzTest_types.o" "$OBJ/lsan_off.o" "$OBJ/standalone_main.o" "$LIBTHRIFT" \
    -o "$SRC/$h-standalone"
done

# 4) C GLib: sanitized library + the two upstream harnesses.
cmake -S "$SRC" -B "$B/glib" "${COMMON_OPTS[@]}" -DBUILD_COMPILER=OFF -DTHRIFT_COMPILER="$THRIFT" \
  -DBUILD_TESTING=OFF -DWITH_CPP=OFF -DWITH_C_GLIB=ON \
  -DCMAKE_C_FLAGS="$FLAGS" -DCMAKE_CXX_FLAGS="$FLAGS"
cmake --build "$B/glib" -j"$MAYHEM_JOBS" --target thrift_c_glib
LIBGLIB="$(find "$B/glib" \( -name libthrift_c_glib.a -o -name libthrift_c_glibd.a \) | head -1)"
[ -n "$LIBGLIB" ] || { echo "libthrift_c_glib.a missing" >&2; exit 1; }
read -r -a GLIB_CFLAGS <<<"$(pkg-config --cflags glib-2.0 gobject-2.0)"
read -r -a GLIB_LIBS <<<"$(pkg-config --libs glib-2.0 gobject-2.0)"
GLIB_INC=(-I"$SRC/lib/c_glib/src" -I"$B/gen" -I"$B/gen/gen-c_glib" "${GLIB_CFLAGS[@]}")
# shellcheck disable=SC2086
$CC $FLAGS "${GLIB_INC[@]}" -c "$B/gen/gen-c_glib/fuzz_test_no_uuid_types.c" -o "$OBJ/fuzz_test_no_uuid_types.o"
for h in fuzz_parse_binary fuzz_parse_compact; do
  # shellcheck disable=SC2086
  $CC $FLAGS "${GLIB_INC[@]}" -c "$SRC/lib/c_glib/test/fuzz/$h.c" -o "$OBJ/$h.o"
  # shellcheck disable=SC2086
  $CC $FLAGS "$OBJ/$h.o" "$OBJ/fuzz_test_no_uuid_types.o" "$OBJ/lsan_off.o" "$LIBGLIB" "${GLIB_LIBS[@]}" \
    $LIB_FUZZING_ENGINE -lstdc++ -o "$SRC/$h"
  # shellcheck disable=SC2086
  $CC $FLAGS "$OBJ/$h.o" "$OBJ/fuzz_test_no_uuid_types.o" "$OBJ/lsan_off.o" "$OBJ/standalone_main.o" "$LIBGLIB" \
    "${GLIB_LIBS[@]}" -lstdc++ -o "$SRC/$h-standalone"
done
