#!/usr/bin/env bash
#
# examples/fetch-data.sh — fetch the Quickstart's example data.
#
# Downloads two small public genomes + a public sequencing run, and writes a
# round-robin shard map, so you can run the `shaln index` / `shaln align`
# Quickstart without writing any SQL. Everything is done for you here.
#
# Run it from anywhere; it writes three files into the CURRENT directory:
#
#   refs.fasta      phiX174 (NC_001422.1) + lambda (NC_001416.1) genomes
#   shard-map.tsv   reference_id <TAB> shard_name, split round-robin into 2 shards
#   reads.parquet   up to 2000 reads from public run ERR1074767
#
# Needs network access. Honors the same overrides as shaln itself:
#   SHALN_DUCKDB           a duckdb binary to use (>= 1.5.4)
#   SHALN_EXTENSION_PATH   a local (unsigned) miint extension to load

# SHALN_VERBOSE / SHALN_DUCKDB_BIN / SHALN_DUCKDB_FLAGS below are read by the
# helpers we source from ../shaln; shellcheck can't see that across the source.
# shellcheck disable=SC2034
set -euo pipefail

# Reuse shaln's DuckDB discovery + miint-load helpers (the shaln script is safe
# to source — sourcing only defines functions, it doesn't run a command).
EXAMPLES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$EXAMPLES_DIR/../shaln"

SHALN_VERBOSE=1   # narrate each step to stderr

SHALN_DUCKDB_BIN="$(shaln_require_duckdb)" || exit 1
SHALN_DUCKDB_FLAGS="$(shaln_duckdb_flags)"

# httpfs lets DuckDB read the NCBI / ENA https endpoints; miint does not pull it
# in on its own. It is a core DuckDB extension, installed on demand.
PREAMBLE="INSTALL httpfs;
LOAD httpfs;
$(shaln_extension_preamble)"

shaln_log "downloading references (phiX174 + lambda) -> refs.fasta"
shaln_run_sql "$PREAMBLE
COPY (SELECT read_id, sequence1 FROM read_ncbi_fasta(['NC_001422.1','NC_001416.1']))
TO 'refs.fasta' (FORMAT fasta);"

shaln_log "splitting references round-robin into 2 shards -> shard-map.tsv"
shaln_run_sql "$PREAMBLE
COPY (
  SELECT read_id AS reference_id,
         'shard_' || ((row_number() OVER (ORDER BY read_id) - 1) % 2)::VARCHAR AS shard_name
  FROM read_fastx('refs.fasta')
) TO 'shard-map.tsv' (FORMAT csv, DELIMITER '\t', HEADER false);"

shaln_log "downloading reads (public run ERR1074767, up to 2000) -> reads.parquet"
shaln_run_sql "$PREAMBLE
COPY (SELECT * FROM read_ena_sequences('ERR1074767', max_sequences := 2000))
TO 'reads.parquet' (FORMAT PARQUET);"

shaln_log "done — wrote refs.fasta, shard-map.tsv, reads.parquet"
