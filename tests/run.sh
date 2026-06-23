#!/usr/bin/env bash
#
# tests/run.sh — dependency-free test harness for shaln (no bats).
#
# Runs every test_* function below and exits 0 iff all pass. Designed to work
# on the stock macOS bash 3.2, using only builtins + committed fixtures.
#
#   Usage: tests/run.sh

# No `set -e`: assertions record failures via _diag and the run must continue
# through every test. run_test also treats a nonzero return from a test function
# (a crash with no assertion) as a failure, so omitting -e doesn't hide errors.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHALN="$ROOT/shaln"
INSTALL_SH="$ROOT/install.sh"
FIX="$HERE/fixtures"

# Integration tests (B1+) need a real duckdb + miint extension. Capture whatever
# the dev workflow exported (SHALN_DUCKDB / SHALN_EXTENSION_PATH) BEFORE we unset
# them, so unit tests stay hermetic but integration tests can opt in.
SHALN_TEST_DUCKDB="${SHALN_DUCKDB:-}"
SHALN_TEST_EXT="${SHALN_EXTENSION_PATH:-}"

# Keep unit tests hermetic regardless of the caller's shell.
unset SHALN_DUCKDB SHALN_EXTENSION_PATH 2>/dev/null || true

# Source shaln so unit-level tests can call its functions directly. The script
# guards `main` behind a BASH_SOURCE check, so sourcing defines functions only.
if [[ -f "$SHALN" ]]; then
  # shellcheck disable=SC1090
  source "$SHALN"
fi
if [[ -f "$INSTALL_SH" ]]; then
  # shellcheck disable=SC1090
  source "$INSTALL_SH"
fi

# --- assertion + reporting machinery ---------------------------------------

_T_FAIL=0
_T_SKIP=""
PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

_diag() { printf '      %s\n' "$*" >&2; _T_FAIL=1; }

# skip <reason> — mark the current test skipped (e.g. an optional dependency is
# absent). Mirrors the project's require-env convention: skipped, not failed.
skip() { _T_SKIP="$1"; }

assert_eq() { # <expected> <actual> [msg]
  [[ "$1" == "$2" ]] || _diag "${3:-assert_eq}: expected [$1], got [$2]"
}
assert_ne() { # <unexpected> <actual> [msg]
  [[ "$1" != "$2" ]] || _diag "${3:-assert_ne}: did not expect [$1]"
}
assert_contains() { # <haystack> <needle> [msg]
  [[ "$1" == *"$2"* ]] || _diag "${3:-assert_contains}: [$2] not found in [$1]"
}
assert_not_contains() { # <haystack> <needle> [msg]
  [[ "$1" != *"$2"* ]] || _diag "${3:-assert_not_contains}: [$2] unexpectedly present in [$1]"
}
assert_rc() { # <expected_rc> <actual_rc> [msg]
  [[ "$1" == "$2" ]] || _diag "${3:-assert_rc}: expected exit $1, got $2"
}

# capture <cmd...> — run cmd, set CAP_OUT (stdout+stderr merged) and CAP_RC.
capture() {
  CAP_OUT="$("$@" 2>&1)"
  CAP_RC=$?
}

run_test() { # <test_function_name>
  local name="$1"
  _T_FAIL=0
  _T_SKIP=""
  "$name"
  local rc=$?
  if [[ -n "$_T_SKIP" ]]; then
    SKIP=$((SKIP + 1))
    printf '  skip  %s (%s)\n' "$name" "$_T_SKIP"
  elif [[ "$_T_FAIL" -eq 0 && "$rc" -eq 0 ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    # A nonzero return with no recorded assertion failure means the test
    # function itself crashed (e.g. an unguarded command failed) — surface it,
    # don't let it masquerade as a pass.
    if [[ "$_T_FAIL" -eq 0 && "$rc" -ne 0 ]]; then
      printf '  FAIL  %s (test returned %d with no assertion failure — crashed?)\n' "$name" "$rc"
    else
      printf '  FAIL  %s\n' "$name"
    fi
  fi
}

# --- integration-test helpers ----------------------------------------------

# require_duckdb_ext — skip the current test unless a real duckdb + miint
# extension are wired up (SHALN_DUCKDB + SHALN_EXTENSION_PATH from the dev
# workflow). Sets INT_DUCKDB / INT_EXT for the test to pass through.
require_duckdb_ext() {
  if [[ -z "$SHALN_TEST_DUCKDB" || ! -x "$SHALN_TEST_DUCKDB" ]]; then
    skip "SHALN_DUCKDB not set/executable"
    return 1
  fi
  if [[ -z "$SHALN_TEST_EXT" || ! -f "$SHALN_TEST_EXT" ]]; then
    skip "SHALN_EXTENSION_PATH not set/found"
    return 1
  fi
  INT_DUCKDB="$SHALN_TEST_DUCKDB"
  INT_EXT="$SHALN_TEST_EXT"
  return 0
}

# shaln_int <args...> — run shaln with the integration duckdb + extension wired
# in. Sets CAP_OUT (stdout+stderr) and CAP_RC.
shaln_int() {
  CAP_OUT="$(SHALN_DUCKDB="$INT_DUCKDB" SHALN_EXTENSION_PATH="$INT_EXT" "$SHALN" "$@" 2>&1)"
  CAP_RC=$?
}

# new_bundle_dir — a fresh mktemp bundle dir (left in place; no rm per policy).
new_bundle_dir() {
  mktemp -d "${TMPDIR:-/tmp}/shaln-bundle.XXXXXX"
}

# gpl_boundary_ready — true iff the wired duckdb+ext reports bowtie2_available().
gpl_boundary_ready() {
  local out
  out="$(printf ".bail on\nLOAD '%s';\nSELECT bowtie2_available();\n" "$INT_EXT" \
    | "$INT_DUCKDB" -unsigned -noheader -list 2>/dev/null)"
  [[ "$out" == *true* ]]
}

# arrow_ready — true iff the community 'arrow' extension installs + loads.
arrow_ready() {
  printf "INSTALL arrow FROM community; LOAD arrow; SELECT 1;" \
    | "$INT_DUCKDB" -noheader -list >/dev/null 2>&1
}

# reads_relation_count <relation-sql> <select-list> — run `LOAD ext; SELECT
# <select-list> FROM <relation>` (file-based, no stdin) and set CAP_OUT/CAP_RC.
reads_relation_count() {
  CAP_OUT="$(printf ".bail on\nLOAD '%s';\nSELECT %s FROM %s;\n" "$INT_EXT" "$2" "$1" \
    | "$INT_DUCKDB" -unsigned -noheader -list 2>&1)"
  CAP_RC=$?
}

# Cached bundles built once and reused across align tests (build is ~instant but
# this keeps the suite tidy). Left in place (no rm per policy).
ALIGN_BUNDLE_MM2=""
ALIGN_BUNDLE_BT2=""

ensure_align_bundle_mm2() {
  if [[ -n "$ALIGN_BUNDLE_MM2" && -f "$ALIGN_BUNDLE_MM2/manifest.tsv" ]]; then return 0; fi
  ALIGN_BUNDLE_MM2="$(new_bundle_dir)"
  SHALN_DUCKDB="$INT_DUCKDB" SHALN_EXTENSION_PATH="$INT_EXT" "$SHALN" index \
    --references "$FIX/refs.fasta" --shard-map "$FIX/shard-map.tsv" -o "$ALIGN_BUNDLE_MM2" >/dev/null 2>&1 ||
    _diag "ensure_align_bundle_mm2: 'shaln index' failed"
}

ensure_align_bundle_bt2() {
  if [[ -n "$ALIGN_BUNDLE_BT2" && -f "$ALIGN_BUNDLE_BT2/manifest.tsv" ]]; then return 0; fi
  ALIGN_BUNDLE_BT2="$(new_bundle_dir)"
  SHALN_DUCKDB="$INT_DUCKDB" SHALN_EXTENSION_PATH="$INT_EXT" "$SHALN" index --aligner bowtie2 \
    --references "$FIX/refs.fasta" --shard-map "$FIX/shard-map.tsv" -o "$ALIGN_BUNDLE_BT2" >/dev/null 2>&1 ||
    _diag "ensure_align_bundle_bt2: 'shaln index' failed"
}

# duckdb_query <sql> — run SQL with the wired duckdb+ext; set CAP_OUT/CAP_RC.
duckdb_query() {
  CAP_OUT="$(printf ".bail on\nLOAD '%s';\n%s\n" "$INT_EXT" "$1" \
    | "$INT_DUCKDB" -unsigned -noheader -list 2>&1)"
  CAP_RC=$?
}

# --- subcommand dispatch ---------------------------------------------------

test_version_succeeds() {
  capture "$SHALN" version
  assert_rc 0 "$CAP_RC" "version exit code"
  assert_contains "$CAP_OUT" "shaln" "version output mentions shaln"
  assert_contains "$CAP_OUT" "0.1.0" "version output shows the version number"
}

test_help_succeeds() {
  capture "$SHALN" help
  assert_rc 0 "$CAP_RC" "help exit code"
  assert_contains "$CAP_OUT" "Usage" "help shows usage"
  assert_contains "$CAP_OUT" "index" "help lists the index command"
  assert_contains "$CAP_OUT" "align" "help lists the align command"
}

test_help_flag_succeeds() {
  capture "$SHALN" --help
  assert_rc 0 "$CAP_RC" "--help exit code"
  assert_contains "$CAP_OUT" "Usage" "--help shows usage"
}

test_no_subcommand_errors() {
  capture "$SHALN"
  assert_rc 2 "$CAP_RC" "no-subcommand exit code"
  assert_contains "$CAP_OUT" "Usage" "no-subcommand prints usage"
}

test_unknown_subcommand_errors() {
  capture "$SHALN" bogus-cmd
  assert_rc 2 "$CAP_RC" "unknown-subcommand exit code"
  assert_contains "$CAP_OUT" "unknown" "unknown-subcommand error mentions 'unknown'"
}

# --- extension preamble selection ------------------------------------------

test_preamble_default_is_community() {
  local out
  out="$(shaln_extension_preamble)"
  assert_contains "$out" "INSTALL miint FROM community" "default installs from community"
  assert_contains "$out" "LOAD miint" "default loads miint"
  assert_not_contains "$out" "allow_unsigned_extensions" "default does not allow unsigned"
}

test_preamble_extension_path_loads_local() {
  local out
  out="$(shaln_extension_preamble /path/to/miint.duckdb_extension)"
  assert_contains "$out" "LOAD '/path/to/miint.duckdb_extension'" "ext-path loads the given file"
  assert_not_contains "$out" "FROM community" "ext-path does not install from community"
  # allow_unsigned_extensions is a startup-only setting (see shaln_duckdb_flags),
  # not a SET statement, so it must NOT appear in the SQL preamble.
  assert_not_contains "$out" "allow_unsigned_extensions" "ext-path preamble has no runtime SET"
  assert_not_contains "$out" "SET " "ext-path preamble issues no SET statement"
}

test_duckdb_flags_unsigned_for_ext_path() {
  local out
  out="$(shaln_duckdb_flags /path/to/miint.duckdb_extension)"
  assert_eq "-unsigned" "$out" "a local extension path launches duckdb with -unsigned"
}

test_duckdb_flags_empty_by_default() {
  local out
  out="$(shaln_duckdb_flags)"
  assert_eq "" "$out" "the community-install path needs no extra duckdb flags"
}

test_preamble_reads_env_var() {
  local out
  out="$(SHALN_EXTENSION_PATH=/env/miint.ext bash -c 'source "$1"; shaln_extension_preamble' _ "$SHALN" 2>&1)"
  assert_contains "$out" "LOAD '/env/miint.ext'" "preamble honors SHALN_EXTENSION_PATH"
}

test_preamble_sql_quotes_path() {
  local out
  out="$(shaln_extension_preamble "/odd/it's/path.ext")"
  assert_contains "$out" "LOAD '/odd/it''s/path.ext'" "single quotes are doubled for SQL safety"
}

# --- duckdb version comparator (pure) --------------------------------------

test_version_ge_comparisons() {
  shaln_version_ge 1.5.4 1.5.4 && : || _diag "1.5.4 >= 1.5.4 should hold"
  shaln_version_ge 1.6.0 1.5.4 && : || _diag "1.6.0 >= 1.5.4 should hold"
  shaln_version_ge 2.0.0 1.5.4 && : || _diag "2.0.0 >= 1.5.4 should hold"
  shaln_version_ge 1.5.10 1.5.4 && : || _diag "1.5.10 >= 1.5.4 should hold (multi-digit patch)"
  shaln_version_ge 1.5.3 1.5.4 && _diag "1.5.3 >= 1.5.4 should NOT hold" || :
  shaln_version_ge 1.4.9 1.5.4 && _diag "1.4.9 >= 1.5.4 should NOT hold" || :
  shaln_version_ge 1.5 1.5.4 && _diag "1.5 >= 1.5.4 should NOT hold" || :
}

# --- duckdb discovery + version gate ---------------------------------------

test_resolve_duckdb_from_env() {
  CAP_OUT="$(SHALN_DUCKDB="$FIX/duckdb-stub-good" bash -c 'source "$1"; shaln_resolve_duckdb' _ "$SHALN" 2>&1)"
  CAP_RC=$?
  assert_rc 0 "$CAP_RC" "resolve via SHALN_DUCKDB succeeds"
  assert_eq "$FIX/duckdb-stub-good" "$CAP_OUT" "resolve returns the SHALN_DUCKDB path"
}

test_resolve_duckdb_missing_fails() {
  # Source with a normal PATH, then strip PATH so no `duckdb` is discoverable.
  CAP_OUT="$(bash -c 'source "$1"; PATH=/var/empty; unset SHALN_DUCKDB; shaln_resolve_duckdb' _ "$SHALN" 2>&1)"
  CAP_RC=$?
  assert_rc 1 "$CAP_RC" "missing duckdb returns 1"
  assert_contains "$CAP_OUT" "duckdb" "missing-duckdb error mentions duckdb"
}

test_require_duckdb_rejects_old_version() {
  CAP_OUT="$(SHALN_DUCKDB="$FIX/duckdb-stub-old" bash -c 'source "$1"; shaln_require_duckdb' _ "$SHALN" 2>&1)"
  CAP_RC=$?
  assert_rc 1 "$CAP_RC" "old duckdb is rejected"
  assert_contains "$CAP_OUT" "1.5.4" "rejection mentions the required version"
}

test_require_duckdb_accepts_good_version() {
  CAP_OUT="$(SHALN_DUCKDB="$FIX/duckdb-stub-good" bash -c 'source "$1"; shaln_require_duckdb' _ "$SHALN" 2>&1)"
  CAP_RC=$?
  assert_rc 0 "$CAP_RC" "good duckdb is accepted"
  assert_eq "$FIX/duckdb-stub-good" "$CAP_OUT" "require returns the duckdb path"
}

# --- shaln index: argument validation (no duckdb needed) -------------------

test_index_requires_references() {
  capture "$SHALN" index --shard-map /nope/map.tsv -o /nope/bundle
  assert_rc 2 "$CAP_RC" "missing --references is a usage error"
  assert_contains "$CAP_OUT" "--references" "error names the missing flag"
}

test_index_requires_shard_map() {
  capture "$SHALN" index --references /nope/refs.fa -o /nope/bundle
  assert_rc 2 "$CAP_RC" "missing --shard-map is a usage error"
  assert_contains "$CAP_OUT" "--shard-map" "error names the missing flag"
}

test_index_requires_output() {
  capture "$SHALN" index --references /nope/refs.fa --shard-map /nope/map.tsv
  assert_rc 2 "$CAP_RC" "missing -o/--output is a usage error"
  assert_contains "$CAP_OUT" "output" "error mentions the output bundle"
}

test_index_rejects_bad_aligner() {
  capture "$SHALN" index --references /nope/refs.fa --shard-map /nope/map.tsv -o /nope/b --aligner bowtie3
  assert_rc 2 "$CAP_RC" "unknown --aligner is a usage error"
  assert_contains "$CAP_OUT" "aligner" "error mentions the aligner"
}

test_index_errors_on_missing_references_file() {
  # All flags present + valid aligner, but the references file does not exist.
  capture "$SHALN" index --references /nope/refs.fa --shard-map "$FIX/shard-map.tsv" -o /nope/b
  assert_rc 2 "$CAP_RC" "a nonexistent references file is rejected"
  assert_contains "$CAP_OUT" "/nope/refs.fa" "error names the missing file"
}

# --- shaln index: integration (need a real duckdb + miint) -----------------

test_index_minimap2_builds_bundle() {
  require_duckdb_ext || return
  local bundle
  bundle="$(new_bundle_dir)"
  shaln_int index --references "$FIX/refs.fasta" --shard-map "$FIX/shard-map.tsv" -o "$bundle"
  assert_rc 0 "$CAP_RC" "minimap2 index build succeeds ($CAP_OUT)"
  [[ -f "$bundle/shard_a.mmi" ]] || _diag "shard_a.mmi not written"
  [[ -f "$bundle/shard_b.mmi" ]] || _diag "shard_b.mmi not written"
  [[ -d "$bundle/rype.ryxdi" ]] || _diag "rype.ryxdi directory not written"
  [[ -f "$bundle/lengths.parquet" ]] || _diag "lengths.parquet not written"
  [[ -f "$bundle/manifest.tsv" ]] || _diag "manifest.tsv not written"
  # Manifest records the aligner and every shard (Rule 7: encode intent).
  local man
  man="$(cat "$bundle/manifest.tsv" 2>/dev/null)"
  assert_contains "$man" "minimap2" "manifest records the minimap2 aligner"
  assert_contains "$man" "shard_a" "manifest lists shard_a"
  assert_contains "$man" "shard_b" "manifest lists shard_b"
  # lengths.parquet content: the two references with their correct lengths.
  local lq
  lq="$(printf ".bail on\nLOAD '%s';\nSELECT name || ':' || length FROM read_parquet('%s/lengths.parquet') ORDER BY name;\n" \
    "$INT_EXT" "$bundle" | "$INT_DUCKDB" -unsigned -noheader -list 2>&1)"
  assert_contains "$lq" "ref1:124" "lengths.parquet has ref1 length 124"
  assert_contains "$lq" "ref2:136" "lengths.parquet has ref2 length 136"
}

# --- shaln index: shard-name safety gate (no duckdb needed) -----------------

test_shard_names_rejects_unsafe() {
  local out rc
  out="$(shaln_read_shard_names "$FIX/shard-map-unsafe.tsv" 2>&1)"
  rc=$?
  assert_rc 1 "$rc" "an unsafe shard name (path traversal) is rejected"
  assert_contains "$out" "unsafe" "the error explains why it was rejected"
}

test_shard_names_rejects_malformed_tsv() {
  local out rc
  out="$(shaln_read_shard_names "$FIX/shard-map-malformed.tsv" 2>&1)"
  rc=$?
  assert_rc 1 "$rc" "a non-2-column shard-map is rejected"
  assert_contains "$out" "2-column" "the error names the expected format"
}

test_index_bowtie2_builds_bundle() {
  require_duckdb_ext || return
  gpl_boundary_ready || {
    skip "bowtie2_available() is false (gpl-boundary absent)"
    return
  }
  local bundle
  bundle="$(new_bundle_dir)"
  shaln_int index --aligner bowtie2 --references "$FIX/refs.fasta" --shard-map "$FIX/shard-map.tsv" -o "$bundle"
  assert_rc 0 "$CAP_RC" "bowtie2 index build succeeds ($CAP_OUT)"
  # bowtie2 layout: <bundle>/<shard>/index.*.bt2 (subdir per shard).
  ls "$bundle"/shard_a/index.*.bt2 >/dev/null 2>&1 || _diag "shard_a bowtie2 index files not written"
  ls "$bundle"/shard_b/index.*.bt2 >/dev/null 2>&1 || _diag "shard_b bowtie2 index files not written"
  [[ -d "$bundle/rype.ryxdi" ]] || _diag "rype.ryxdi directory not written (bowtie2)"
  local man
  man="$(cat "$bundle/manifest.tsv" 2>/dev/null)"
  assert_contains "$man" "bowtie2" "manifest records the bowtie2 aligner"
}

test_index_errors_on_unmapped_reference() {
  require_duckdb_ext || return
  local bundle
  bundle="$(new_bundle_dir)"
  shaln_int index --references "$FIX/refs.fasta" --shard-map "$FIX/shard-map-badref.tsv" -o "$bundle"
  assert_ne 0 "$CAP_RC" "a shard-map reference absent from --references is rejected"
  assert_contains "$CAP_OUT" "refX" "error names the offending reference id"
}

# --- shaln align input layer: parsing (no duckdb needed) -------------------

test_normalize_path_dash_is_stdin() {
  assert_eq "/dev/stdin" "$(shaln_normalize_path -)" "'-' maps to /dev/stdin"
  assert_eq "reads.fq" "$(shaln_normalize_path reads.fq)" "a real path is unchanged"
}

test_parse_reads_single_and_passthrough() {
  shaln_parse_reads_input --fastq reads.fq --bundle b --aligner minimap2
  assert_rc 0 "$?" "single-end parse succeeds"
  assert_eq "single" "$READS_MODE" "mode is single"
  assert_eq "reads.fq" "$READS_P1" "path captured"
  # Non-input flags pass through to SHALN_REST for the caller (B3) to parse.
  assert_eq "4" "${#SHALN_REST[@]}" "non-input args passed through"
  assert_eq "--bundle b --aligner minimap2" "${SHALN_REST[*]}" "passthrough content preserved"
}

test_parse_reads_paired_requires_both() {
  local rc
  shaln_parse_reads_input -1 r1.fq 2>/dev/null
  rc=$?
  assert_rc 2 "$rc" "paired input with only -1 is a usage error"
}

test_parse_reads_rejects_multiple_modes() {
  local rc
  shaln_parse_reads_input --fastq a.fq --parquet b.parquet 2>/dev/null
  rc=$?
  assert_rc 2 "$rc" "two input modes is a usage error"
}

test_parse_reads_rejects_no_input() {
  local rc
  shaln_parse_reads_input --bundle b 2>/dev/null
  rc=$?
  assert_rc 2 "$rc" "no input mode is a usage error"
}

test_parse_reads_stdin_and_modes() {
  shaln_parse_reads_input --fastq -
  assert_eq "/dev/stdin" "$READS_P1" "stdin '-' normalized in parse"
  shaln_parse_reads_input --parquet x.parquet
  assert_eq "parquet" "$READS_MODE" "parquet mode"
  shaln_parse_reads_input --arrow -
  assert_eq "arrow" "$READS_MODE" "arrow mode"
  shaln_parse_reads_input --interleaved x.fq
  assert_eq "interleaved" "$READS_MODE" "interleaved mode"
  shaln_parse_reads_input -1 a.fq -2 b.fq
  assert_eq "paired" "$READS_MODE" "paired mode"
  assert_eq "b.fq" "$READS_P2" "paired r2 captured"
}

# --- shaln align input layer: normalization (need duckdb) ------------------

test_reads_single_fastq() {
  require_duckdb_ext || return
  reads_relation_count "$(shaln_reads_relation single "$FIX/reads_se.fq")" \
    "count(*), count(sequence2), count(qual1)"
  assert_rc 0 "$CAP_RC" "single-end fastq normalizes ($CAP_OUT)"
  # 3 reads, no sequence2 (single-end), quals present.
  assert_eq "3|0|3" "$CAP_OUT" "3 SE reads, no mate, quals present"
}

test_reads_single_fasta() {
  require_duckdb_ext || return
  reads_relation_count "$(shaln_reads_relation single "$FIX/reads.fa")" \
    "count(*), count(qual1)"
  assert_rc 0 "$CAP_RC" "single-end fasta normalizes ($CAP_OUT)"
  # 3 reads, no quals (FASTA).
  assert_eq "3|0" "$CAP_OUT" "3 FASTA reads, no quals"
}

test_reads_paired() {
  require_duckdb_ext || return
  reads_relation_count "$(shaln_reads_relation paired "$FIX/reads_r1.fq" "$FIX/reads_r2.fq")" \
    "count(*), count(sequence2), count(qual2)"
  assert_rc 0 "$CAP_RC" "paired normalizes ($CAP_OUT)"
  assert_eq "2|2|2" "$CAP_OUT" "2 pairs, both mates + quals present"
}

test_reads_interleaved_pairs_correctly() {
  require_duckdb_ext || return
  # Assert the actual pairing, not just the count (Rule 7): pair1's R1/R2.
  reads_relation_count "$(shaln_reads_relation interleaved "$FIX/reads_il.fq")" \
    "count(*) FILTER (WHERE read_id='pair1' AND sequence1='AAAACCCCGGGG' AND sequence2='TTTTGGGGAAAA')"
  assert_rc 0 "$CAP_RC" "interleaved normalizes ($CAP_OUT)"
  assert_eq "1" "$CAP_OUT" "pair1 R1/R2 de-interleaved into one correctly-paired row"
}

test_reads_stdin_fastq() {
  require_duckdb_ext || return
  local rel
  rel="$(shaln_reads_relation single /dev/stdin)"
  CAP_OUT="$("$INT_DUCKDB" -unsigned -noheader -list \
    -c "LOAD '$INT_EXT'; SELECT count(*) FROM $rel;" <"$FIX/reads_se.fq" 2>&1)"
  CAP_RC=$?
  assert_rc 0 "$CAP_RC" "stdin fastq normalizes ($CAP_OUT)"
  assert_eq "3" "$CAP_OUT" "3 reads read from /dev/stdin"
}

test_reads_parquet() {
  require_duckdb_ext || return
  local pq
  pq="$(new_bundle_dir)/reads.parquet"
  "$INT_DUCKDB" -unsigned -c \
    "LOAD '$INT_EXT'; COPY (SELECT * FROM read_fastx('$FIX/reads_se.fq')) TO '$pq' (FORMAT PARQUET);" >/dev/null 2>&1
  reads_relation_count "$(shaln_reads_relation parquet "$pq")" "count(*)"
  assert_rc 0 "$CAP_RC" "parquet normalizes ($CAP_OUT)"
  assert_eq "3" "$CAP_OUT" "3 reads from the read_fastx-schema parquet"
}

test_reads_arrow_stdin() {
  require_duckdb_ext || return
  arrow_ready || {
    skip "community arrow extension not installable"
    return
  }
  local rel
  rel="$(shaln_reads_relation arrow /dev/stdin)"
  # Producer streams an Arrow IPC stream; consumer reads it from /dev/stdin.
  CAP_OUT="$("$INT_DUCKDB" -unsigned -c \
    "LOAD '$INT_EXT'; INSTALL arrow FROM community; LOAD arrow; COPY (SELECT read_id, sequence1, sequence2, qual1, qual2 FROM read_fastx('$FIX/reads_r1.fq', sequence2 := '$FIX/reads_r2.fq')) TO '/dev/stdout' (FORMAT arrow);" 2>/dev/null \
    | "$INT_DUCKDB" -unsigned -noheader -list \
      -c "INSTALL arrow FROM community; LOAD arrow; SELECT count(*) || '|' || count(sequence2) FROM $rel;" 2>&1)"
  CAP_RC=$?
  assert_rc 0 "$CAP_RC" "arrow stdin normalizes ($CAP_OUT)"
  assert_eq "2|2" "$CAP_OUT" "2 paired reads round-tripped through Arrow IPC over a pipe"
}

test_reads_schema_columns() {
  require_duckdb_ext || return
  # The normalized relation must expose exactly the read_fastx-schema columns.
  CAP_OUT="$(printf ".bail on\nLOAD '%s';\nSELECT string_agg(column_name, ',') FROM (DESCRIBE SELECT * FROM %s);\n" \
    "$INT_EXT" "$(shaln_reads_relation single "$FIX/reads_se.fq")" \
    | "$INT_DUCKDB" -unsigned -noheader -list 2>&1)"
  assert_rc 0 "$CAP_RC" "describe succeeds ($CAP_OUT)"
  assert_eq "read_id,sequence1,sequence2,qual1,qual2" "$CAP_OUT" "normalized schema is exactly the 5 columns"
}

# --- shaln align: argument validation (no duckdb needed) -------------------

test_align_requires_bundle() {
  capture "$SHALN" align --fastq /nope/reads.fq
  assert_rc 2 "$CAP_RC" "missing --bundle is a usage error"
  assert_contains "$CAP_OUT" "bundle" "error mentions the bundle"
}

test_align_requires_input() {
  capture "$SHALN" align --bundle /nope/bundle
  assert_rc 2 "$CAP_RC" "missing reads input is a usage error"
  assert_contains "$CAP_OUT" "input" "error mentions reads input"
}

# --- shaln align: routing + alignment + output (need duckdb) ---------------

test_align_minimap2_sam() {
  require_duckdb_ext || return
  ensure_align_bundle_mm2
  local out
  out="$(new_bundle_dir)/aln.sam"
  shaln_int align --bundle "$ALIGN_BUNDLE_MM2" --fasta "$FIX/align_reads.fa" --max-secondary 0 -o "$out"
  assert_rc 0 "$CAP_RC" "minimap2 align to SAM succeeds ($CAP_OUT)"
  [[ -f "$out" ]] || _diag "SAM file not written"
  local body
  body="$(grep -v '^@' "$out" 2>/dev/null)"
  assert_contains "$body" "readA"$'\t'"0"$'\t'"ref1" "readA maps to ref1"
  assert_contains "$body" "readB"$'\t'"0"$'\t'"ref2" "readB maps to ref2"
  # No --include-seq-qual -> SEQ column is '*'.
  duckdb_query "SELECT count(*) FROM read_alignments('$out');"
  assert_eq "2" "$CAP_OUT" "exactly 2 mapped alignments in the SAM"
}

test_align_minimap2_bam_roundtrip() {
  require_duckdb_ext || return
  ensure_align_bundle_mm2
  local out
  out="$(new_bundle_dir)/aln.bam"
  shaln_int align --bundle "$ALIGN_BUNDLE_MM2" --fasta "$FIX/align_reads.fa" --max-secondary 0 -o "$out"
  assert_rc 0 "$CAP_RC" "minimap2 align to BAM succeeds ($CAP_OUT)"
  duckdb_query "SELECT string_agg(read_id || '->' || reference, ',' ORDER BY read_id) FROM read_alignments('$out');"
  assert_eq "readA->ref1,readB->ref2" "$CAP_OUT" "BAM reads back the expected alignments"
}

test_align_parquet() {
  require_duckdb_ext || return
  ensure_align_bundle_mm2
  local out
  out="$(new_bundle_dir)/aln.parquet"
  shaln_int align --bundle "$ALIGN_BUNDLE_MM2" --fasta "$FIX/align_reads.fa" --max-secondary 0 --format parquet -o "$out"
  assert_rc 0 "$CAP_RC" "minimap2 align to Parquet succeeds ($CAP_OUT)"
  duckdb_query "SELECT count(*) FROM read_parquet('$out');"
  assert_eq "2" "$CAP_OUT" "2 mapped alignments in the Parquet"
}

test_align_stdout_sam_default() {
  require_duckdb_ext || return
  ensure_align_bundle_mm2
  # No -o -> SAM streamed to stdout.
  shaln_int align --bundle "$ALIGN_BUNDLE_MM2" --fasta "$FIX/align_reads.fa" --max-secondary 0
  assert_rc 0 "$CAP_RC" "align to stdout succeeds"
  assert_contains "$CAP_OUT" "@SQ" "stdout SAM has a header (@SQ lines)"
  assert_contains "$CAP_OUT" "readA" "stdout SAM has alignments"
}

test_align_broadcast_routing() {
  require_duckdb_ext || return
  ensure_align_bundle_mm2
  local out
  out="$(new_bundle_dir)/aln.bam"
  shaln_int align --bundle "$ALIGN_BUNDLE_MM2" --fasta "$FIX/align_reads.fa" --broadcast --max-secondary 0 -o "$out"
  assert_rc 0 "$CAP_RC" "broadcast routing succeeds ($CAP_OUT)"
  duckdb_query "SELECT string_agg(read_id || '->' || reference, ',' ORDER BY read_id) FROM read_alignments('$out');"
  assert_eq "readA->ref1,readB->ref2" "$CAP_OUT" "broadcast yields the same correct alignments"
}

test_align_include_seq_qual() {
  require_duckdb_ext || return
  ensure_align_bundle_mm2
  local out_no out_yes
  out_no="$(new_bundle_dir)/no.sam"
  out_yes="$(new_bundle_dir)/yes.sam"
  shaln_int align --bundle "$ALIGN_BUNDLE_MM2" --fasta "$FIX/align_reads.fa" --max-secondary 0 -o "$out_no"
  shaln_int align --bundle "$ALIGN_BUNDLE_MM2" --fasta "$FIX/align_reads.fa" --max-secondary 0 --include-seq-qual -o "$out_yes"
  # Without the flag, SEQ is '*'; with it, SEQ is the actual read sequence.
  local seq_no seq_yes
  seq_no="$(grep '^readA' "$out_no" 2>/dev/null | cut -f10)"
  seq_yes="$(grep '^readA' "$out_yes" 2>/dev/null | cut -f10)"
  assert_eq "*" "$seq_no" "SEQ is '*' without --include-seq-qual"
  assert_contains "$seq_yes" "ACGTACGT" "SEQ is the read with --include-seq-qual"
}

test_align_arrow_stdout() {
  require_duckdb_ext || return
  arrow_ready || {
    skip "community arrow extension not installable"
    return
  }
  ensure_align_bundle_mm2
  # Arrow IPC to stdout, consumed by a downstream duckdb via read_arrow.
  CAP_OUT="$(SHALN_DUCKDB="$INT_DUCKDB" SHALN_EXTENSION_PATH="$INT_EXT" "$SHALN" align \
    --bundle "$ALIGN_BUNDLE_MM2" --fasta "$FIX/align_reads.fa" --max-secondary 0 --format arrow 2>/dev/null \
    | "$INT_DUCKDB" -unsigned -noheader -list \
      -c "INSTALL arrow FROM community; LOAD arrow; SELECT count(*) FROM read_arrow('/dev/stdin');" 2>&1)"
  CAP_RC=$?
  assert_rc 0 "$CAP_RC" "arrow stdout pipes to a consumer ($CAP_OUT)"
  assert_eq "2" "$CAP_OUT" "2 mapped alignments round-tripped through Arrow IPC"
}

test_align_bowtie2() {
  require_duckdb_ext || return
  gpl_boundary_ready || {
    skip "bowtie2_available() is false (gpl-boundary absent)"
    return
  }
  ensure_align_bundle_bt2
  local out
  out="$(new_bundle_dir)/aln.bam"
  shaln_int align --bundle "$ALIGN_BUNDLE_BT2" --fasta "$FIX/align_reads.fa" -o "$out"
  assert_rc 0 "$CAP_RC" "bowtie2 align succeeds ($CAP_OUT)"
  duckdb_query "SELECT string_agg(DISTINCT read_id || '->' || reference, ',') FROM read_alignments('$out');"
  assert_contains "$CAP_OUT" "readA->ref1" "bowtie2: readA maps to ref1"
  assert_contains "$CAP_OUT" "readB->ref2" "bowtie2: readB maps to ref2"
}

test_align_rejects_bad_threshold() {
  require_duckdb_ext || return
  ensure_align_bundle_mm2
  shaln_int align --bundle "$ALIGN_BUNDLE_MM2" --fasta "$FIX/align_reads.fa" --route-threshold 1.2.3
  assert_rc 2 "$CAP_RC" "a malformed --route-threshold is a usage error"
  assert_contains "$CAP_OUT" "number" "error explains it must be a number"
}

test_align_rejects_corrupt_manifest() {
  require_duckdb_ext || return
  local bundle
  bundle="$(new_bundle_dir)"
  SHALN_DUCKDB="$INT_DUCKDB" SHALN_EXTENSION_PATH="$INT_EXT" "$SHALN" index \
    --references "$FIX/refs.fasta" --shard-map "$FIX/shard-map.tsv" -o "$bundle" >/dev/null 2>&1 ||
    {
      _diag "index build failed"
      return 1
    }
  # Strip the 'rype' key to simulate a hand-corrupted manifest (mv, not rm).
  grep -v "^rype$(printf '\t')" "$bundle/manifest.tsv" >"$bundle/manifest.new" && mv "$bundle/manifest.new" "$bundle/manifest.tsv"
  shaln_int align --bundle "$bundle" --fasta "$FIX/align_reads.fa"
  assert_ne 0 "$CAP_RC" "a manifest missing the rype key is rejected"
  assert_contains "$CAP_OUT" "rype" "error names the missing key"
}

test_align_verbose_layers() {
  require_duckdb_ext || return
  ensure_align_bundle_mm2
  local out err
  out="$(new_bundle_dir)/aln.bam"
  # Verbose: capture stderr only (stdout is the BAM-to-file; here -o is a file).
  err="$(SHALN_DUCKDB="$INT_DUCKDB" SHALN_EXTENSION_PATH="$INT_EXT" "$SHALN" align --verbose \
    --bundle "$ALIGN_BUNDLE_MM2" --fasta "$FIX/align_reads.fa" --max-secondary 0 -o "$out" 2>&1 1>/dev/null)"
  # Layer 1 (bash milestones) and Layer 2 (per-shard progress from the align fn).
  assert_contains "$err" "aligning against bundle" "Layer-1 milestone present"
  assert_contains "$err" "[minimap2]" "Layer-2 per-shard progress present"
  assert_contains "$err" "shard 1/" "Layer-2 names the shard"
  # Timestamps (HH:MM:SS) on the verbose lines.
  printf '%s' "$err" | grep -qE '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' || _diag "verbose lines lack timestamps"

  # Non-verbose: stderr must carry none of the progress/milestone chatter.
  err="$(SHALN_DUCKDB="$INT_DUCKDB" SHALN_EXTENSION_PATH="$INT_EXT" "$SHALN" align \
    --bundle "$ALIGN_BUNDLE_MM2" --fasta "$FIX/align_reads.fa" --max-secondary 0 -o "$out" 2>&1 1>/dev/null)"
  assert_not_contains "$err" "aligning against bundle" "non-verbose emits no Layer-1 milestones"
  assert_not_contains "$err" "[minimap2]" "non-verbose emits no Layer-2 progress"
}

# --- install.sh: platform detection + URL (no network) ---------------------

test_install_asset_macos() {
  assert_eq "osx-universal" "$(shaln_install_asset Darwin arm64)" "macOS arm64 -> osx-universal"
  assert_eq "osx-universal" "$(shaln_install_asset Darwin x86_64)" "macOS x86_64 -> osx-universal"
}

test_install_asset_linux() {
  assert_eq "linux-amd64" "$(shaln_install_asset Linux x86_64)" "linux x86_64 -> linux-amd64"
  assert_eq "linux-arm64" "$(shaln_install_asset Linux aarch64)" "linux aarch64 -> linux-arm64"
  assert_eq "linux-arm64" "$(shaln_install_asset Linux arm64)" "linux arm64 -> linux-arm64"
}

test_install_asset_unknown_fails() {
  local rc
  shaln_install_asset Plan9 pdp11 >/dev/null 2>&1
  rc=$?
  assert_rc 1 "$rc" "an unsupported platform fails loud"
}

test_install_url() {
  assert_eq "https://github.com/duckdb/duckdb/releases/download/v1.5.4/duckdb_cli-linux-amd64.zip" \
    "$(shaln_install_url 1.5.4 linux-amd64)" "linux URL is the DuckDB CLI release asset"
  # macOS asset doesn't follow the {os}-{arch} pattern, so pin it explicitly.
  assert_eq "https://github.com/duckdb/duckdb/releases/download/v1.5.4/duckdb_cli-osx-universal.zip" \
    "$(shaln_install_url 1.5.4 osx-universal)" "macOS URL uses the osx-universal asset"
}

# --- README e2e pipeline on local fixtures (network steps stand in) --------

test_readme_pipeline_smoke() {
  require_duckdb_ext || return
  # Stands in for: read_ncbi_fasta -> refs.fasta ; read_ena_sequences -> reads.
  local bundle bam pq
  bundle="$(new_bundle_dir)"
  shaln_int index --references "$FIX/refs.fasta" --shard-map "$FIX/shard-map.tsv" -o "$bundle"
  assert_rc 0 "$CAP_RC" "README pipeline: index ($CAP_OUT)"

  bam="$(new_bundle_dir)/aln.bam"
  pq="$(new_bundle_dir)/aln.parquet"
  shaln_int align --bundle "$bundle" --fasta "$FIX/align_reads.fa" --max-secondary 0 -o "$bam"
  assert_rc 0 "$CAP_RC" "README pipeline: align -> BAM ($CAP_OUT)"
  shaln_int align --bundle "$bundle" --fasta "$FIX/align_reads.fa" --max-secondary 0 --format parquet -o "$pq"
  assert_rc 0 "$CAP_RC" "README pipeline: align -> Parquet ($CAP_OUT)"

  [[ -s "$bam" ]] || _diag "BAM output is empty"
  [[ -s "$pq" ]] || _diag "Parquet output is empty"
  duckdb_query "SELECT count(*) FROM read_alignments('$bam');"
  assert_eq "2" "$CAP_OUT" "BAM has the 2 expected alignments"
  duckdb_query "SELECT count(*) FROM read_parquet('$pq');"
  assert_eq "2" "$CAP_OUT" "Parquet has the 2 expected alignments"
}

# --- run all ---------------------------------------------------------------

main() {
  printf 'shaln test suite\n'
  local t
  for t in \
    test_version_succeeds \
    test_help_succeeds \
    test_help_flag_succeeds \
    test_no_subcommand_errors \
    test_unknown_subcommand_errors \
    test_preamble_default_is_community \
    test_preamble_extension_path_loads_local \
    test_duckdb_flags_unsigned_for_ext_path \
    test_duckdb_flags_empty_by_default \
    test_preamble_reads_env_var \
    test_preamble_sql_quotes_path \
    test_version_ge_comparisons \
    test_resolve_duckdb_from_env \
    test_resolve_duckdb_missing_fails \
    test_require_duckdb_rejects_old_version \
    test_require_duckdb_accepts_good_version \
    test_index_requires_references \
    test_index_requires_shard_map \
    test_index_requires_output \
    test_index_rejects_bad_aligner \
    test_index_errors_on_missing_references_file \
    test_shard_names_rejects_unsafe \
    test_shard_names_rejects_malformed_tsv \
    test_index_minimap2_builds_bundle \
    test_index_bowtie2_builds_bundle \
    test_index_errors_on_unmapped_reference \
    test_normalize_path_dash_is_stdin \
    test_parse_reads_single_and_passthrough \
    test_parse_reads_paired_requires_both \
    test_parse_reads_rejects_multiple_modes \
    test_parse_reads_rejects_no_input \
    test_parse_reads_stdin_and_modes \
    test_reads_single_fastq \
    test_reads_single_fasta \
    test_reads_paired \
    test_reads_interleaved_pairs_correctly \
    test_reads_stdin_fastq \
    test_reads_parquet \
    test_reads_arrow_stdin \
    test_reads_schema_columns \
    test_align_requires_bundle \
    test_align_requires_input \
    test_align_minimap2_sam \
    test_align_minimap2_bam_roundtrip \
    test_align_parquet \
    test_align_stdout_sam_default \
    test_align_broadcast_routing \
    test_align_include_seq_qual \
    test_align_arrow_stdout \
    test_align_bowtie2 \
    test_align_rejects_bad_threshold \
    test_align_rejects_corrupt_manifest \
    test_align_verbose_layers \
    test_install_asset_macos \
    test_install_asset_linux \
    test_install_asset_unknown_fails \
    test_install_url \
    test_readme_pipeline_smoke; do
    run_test "$t"
  done
  printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  if [[ "$FAIL" -gt 0 ]]; then
    printf 'failed: %s\n' "${FAILED_NAMES[*]}" >&2
    exit 1
  fi
}

main "$@"
