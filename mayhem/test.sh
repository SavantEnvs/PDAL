#!/usr/bin/env bash
#
# mayhem/test.sh — runs PDAL's own gtest binaries plus known-answer probes (all pre-built by
# mayhem/build.sh in build-tests/, with the project's normal flags). It never compiles.
# Emits a CTRF summary; exit 0 iff nothing failed.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

BIN="$SRC/build-tests/bin"
PDAL="$BIN/pdal"
DATA="$SRC/test/data"
passed=0; failed=0

# 1) PDAL's gtest binaries. A binary that prints no "[  PASSED  ] N tests." line (crash, abort, or a
#    sabotaged exit(0)) counts as a failure.
for t in pdal_io_las_reader_test pdal_io_copc_reader_test pdal_io_bpf_base_test pdal_io_text_reader_test \
         pdal_io_ply_reader_test pdal_io_pts_reader_test pdal_io_pcd_reader_test \
         pdal_filters_expression_test pdal_filters_assign_test pdal_where_test pdal_pipeline_manager_test; do
  if [ ! -x "$BIN/$t" ]; then
    echo "MISSING test binary $t (mayhem/build.sh should have built it)" >&2
    failed=$((failed + 1)); continue
  fi
  out="$(timeout 900 "$BIN/$t" 2>&1)"; rc=$?
  p="$(grep -E '^\[  PASSED  \] [0-9]+ tests?\.' <<<"$out" | grep -oE '[0-9]+' | head -1)"
  f="$(grep -E '^\[  FAILED  \] [0-9]+ tests?, listed below' <<<"$out" | grep -oE '[0-9]+' | head -1)"
  p="${p:-0}"; f="${f:-0}"
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then f=1; fi
  if [ "$p" -eq 0 ] && [ "$f" -eq 0 ]; then f=1; fi
  echo "$t: passed=$p failed=$f rc=$rc"
  if [ "$f" -gt 0 ]; then grep -E '^\[  FAILED  \]' <<<"$out" | head -10; fi
  passed=$((passed + p)); failed=$((failed + f))
done

# 2) Known-answer probes: real files through the real binary, exact expected values. A no-op or
#    exit(0) replacement of pdal can't produce them.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
kat() { # kat <name> <expected> <actual>
  if [ "$2" = "$3" ]; then passed=$((passed + 1)); echo "KAT ok   $1"
  else failed=$((failed + 1)); echo "KAT FAIL $1: expected [$2] got [$3]"; fi
}
info() { "$PDAL" info --summary "$1" 2>/dev/null | tr -d ' '; }
field() { grep -m1 "\"$1\"" | sed -E 's/.*:([^,]*),?$/\1/'; }

s="$(info "$DATA/las/simple.las")"
kat las.num_points   1065      "$(field num_points <<<"$s")"
kat las.maxx         638982.55 "$(field maxx <<<"$s")"
kat las.minz         406.59    "$(field minz <<<"$s")"
s="$(info "$DATA/copc/1.2-with-color.copc.laz")"
kat copc.num_points  1065      "$(field num_points <<<"$s")"
kat copc.maxx        638982.55 "$(field maxx <<<"$s")"
s="$(info "$DATA/bpf/utm15.bpf")"
kat bpf.num_points   1         "$(field num_points <<<"$s")"
kat bpf.maxx         470692.44 "$(field maxx <<<"$s")"
"$PDAL" translate "$DATA/text/utm17_1.txt" "$tmp/t.csv" --writers.text.order=X,Y,Z --writers.text.precision=2 >/dev/null 2>&1
kat text.row10       "289818.50,4320980.59,170.58" "$(sed -n 11p "$tmp/t.csv" 2>/dev/null)"
s="$(info "$DATA/ply/mesh.ply")"
kat ply.num_points   4         "$(field num_points <<<"$s")"

stats="$("$PDAL" info --stats --dimensions=Z "$DATA/las/simple.las" 2>/dev/null | tr -d ' ')"
kat stats.z.average  434.0978404 "$(field average <<<"$stats")"
kat stats.z.maximum  586.38      "$(field maximum <<<"$stats")"

"$PDAL" translate "$DATA/las/simple.las" "$tmp/o.csv" --writers.text.order=X,Y,Z,Intensity --writers.text.precision=2 >/dev/null 2>&1
kat translate.rows   1066 "$(wc -l < "$tmp/o.csv" 2>/dev/null)"
kat translate.row1   "637012.24,849028.31,431.66,143.00,1.00,1.00,1.00,0.00,1.00,0.00,0.00,0.00,0.00,-9.00,132.00,7326.00,245380.78,68.00,77.00,88.00" "$(sed -n 2p "$tmp/o.csv" 2>/dev/null)"

"$PDAL" translate "$DATA/las/simple.las" "$tmp/r.csv" range --filters.range.limits="Z[500:600]" >/dev/null 2>&1
kat range.rows       32 "$(wc -l < "$tmp/r.csv" 2>/dev/null)"

"$PDAL" translate "$DATA/las/simple.las" "$tmp/a.csv" assign --filters.assign.assignment="Intensity[:]=7" --writers.text.order=Intensity >/dev/null 2>&1
kat assign.values    "7.000" "$(tail -n +2 "$tmp/a.csv" 2>/dev/null | cut -d, -f1 | sort -u | tr -d '\n')"

emit_ctrf "gtest+kat" "$passed" "$failed" 0
