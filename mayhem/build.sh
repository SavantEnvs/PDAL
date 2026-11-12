#!/usr/bin/env bash
#
# mayhem/build.sh — builds PDAL twice and every harness:
#   1) build-fuzz/   shared PDAL, ASan+UBSan+SanCov, DWARF 3  -> linked into the fuzz harnesses
#   2) build-tests/  normal Release build with the unit tests -> what mayhem/test.sh runs
# Both build dirs live under /mayhem/build-* (covered by upstream's `/build*` gitignore entry).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# ---- 1) sanitized, SanCov-instrumented PDAL (the fuzzed code) ----------------------------------
# Built as a shared library so the 15 harnesses stay small (a static link with DWARF is ~280 MB each);
# the executables find it through $ORIGIN, so it only has to stay at /mayhem/build-fuzz/lib.
# -fsanitize=fuzzer-no-link goes on unconditionally: without it the library has no SanCov edges.
# -fno-sanitize=bool: CopcReader::Private::done is a never-initialised std::atomic<bool> that ASan's malloc
# fill turns into 0xbe, so UBSan halts the reader on every valid COPC file before it parses anything.
# -fno-sanitize=enum: QfitReader::initialize does static_cast<QFIT_Format_Type>(recordLength / 4) on a raw
# file word and then only compares it to named values, so any record length outside 0..255 (a one-bit
# mutation of the seed) halts on the cast before the parser runs, and libFuzzer's 5-iteration sanity check
# fails. ASan and every other UBSan check stay halting.
FUZZ_FLAGS="$SANITIZER_FLAGS -fno-sanitize=bool,enum -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
cmake -S . -B build-fuzz -G Ninja \
  -DBUILD_SHARED_LIBS=ON -DWITH_TESTS=OFF -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS"
cmake --build build-fuzz -j"$MAYHEM_JOBS" --target pdalcpp pdal

# Harness include/define flags come from the build tree itself.
read -ra W <<<"$(cd build-fuzz && ninja -t commands CMakeFiles/pdalcpp.dir/io/LasReader.cpp.o | tail -1)"
INC=()
for ((i = 0; i < ${#W[@]}; i++)); do
  case "${W[i]}" in
    -isystem) INC+=("${W[i]}" "${W[i+1]}"); i=$((i + 1)) ;;
    -D*|-I*|-std=*) INC+=("${W[i]}") ;;
  esac
done
PDALLIB="$SRC/build-fuzz/lib"
LIBS=(-L"$PDALLIB" -lpdalcpp "-Wl,-rpath,\$ORIGIN/build-fuzz/lib")

# lsan_off.cc: leak detection off at build time (ASan/UBSan stay on).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build-fuzz/lsan_off.o
# $STANDALONE_FUZZ_MAIN is C: compile it as C so the C++ harness's extern "C" entry links.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build-fuzz/standalone_main.o

# target | source | NAME=value macros (each becomes -DNAME="value")
TARGETS=(
  "fuzz_las|harness_reader.cpp|PDAL_DRIVER=readers.las|FILE_EXT=.las"
  "fuzz_copc|harness_reader.cpp|PDAL_DRIVER=readers.copc|FILE_EXT=.copc.laz"
  "fuzz_bpf|harness_reader.cpp|PDAL_DRIVER=readers.bpf|FILE_EXT=.bpf"
  "fuzz_text|harness_reader.cpp|PDAL_DRIVER=readers.text|FILE_EXT=.txt"
  "fuzz_ply|harness_reader.cpp|PDAL_DRIVER=readers.ply|FILE_EXT=.ply"
  "fuzz_pcd|harness_reader.cpp|PDAL_DRIVER=readers.pcd|FILE_EXT=.pcd"
  "fuzz_pts|harness_reader.cpp|PDAL_DRIVER=readers.pts|FILE_EXT=.pts"
  "fuzz_ptx|harness_reader.cpp|PDAL_DRIVER=readers.ptx|FILE_EXT=.ptx"
  "fuzz_obj|harness_reader.cpp|PDAL_DRIVER=readers.obj|FILE_EXT=.obj"
  "fuzz_sbet|harness_reader.cpp|PDAL_DRIVER=readers.sbet|FILE_EXT=.sbet"
  "fuzz_qfit|harness_reader.cpp|PDAL_DRIVER=readers.qfit|FILE_EXT=.qi"
  "fuzz_terrasolid|harness_reader.cpp|PDAL_DRIVER=readers.terrasolid|FILE_EXT=.bin"
  "fuzz_pipeline|harness_pipeline.cpp"
  "fuzz_expression|harness_expr.cpp|PDAL_FILTER=filters.expression|FILTER_OPTION=expression"
  "fuzz_assign|harness_expr.cpp|PDAL_FILTER=filters.assign|FILTER_OPTION=assignment"
)

build_harness() {
  local name="$1" src="$2"; shift 2
  local defs=() d
  for d in "$@"; do defs+=("-D${d%%=*}=\"${d#*=}\""); done
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O2 "${INC[@]}" "${defs[@]}" -c "$SRC/mayhem/$src" -o "build-fuzz/$name.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "build-fuzz/$name.o" build-fuzz/lsan_off.o \
    "${LIBS[@]}" -o "$SRC/$name"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "build-fuzz/$name.o" build-fuzz/standalone_main.o build-fuzz/lsan_off.o \
    "${LIBS[@]}" -o "$SRC/$name-standalone"
}

pids=()
for t in "${TARGETS[@]}"; do
  IFS='|' read -ra F <<<"$t"
  build_harness "${F[@]}" &
  pids+=($!)
  while [ "$(jobs -rp | wc -l)" -ge "$MAYHEM_JOBS" ]; do sleep 0.5; done
done
for p in "${pids[@]}"; do wait "$p"; done

# ---- 2) the test suite, project's NORMAL flags (no sanitizers, no -gdwarf-3) ----------------------
cmake -S . -B build-tests -G Ninja -DWITH_TESTS=ON -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build-tests -j"$MAYHEM_JOBS" --target \
  pdal \
  pdal_io_las_reader_test pdal_io_bpf_base_test pdal_io_text_reader_test pdal_io_ply_reader_test \
  pdal_io_pts_reader_test pdal_io_pcd_reader_test pdal_io_copc_reader_test \
  pdal_filters_expression_test pdal_filters_assign_test pdal_where_test pdal_pipeline_manager_test
