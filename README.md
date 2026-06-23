<p align="center">
  <img src="assets/logo.png" alt="shaln — sharded alignment" width="640">
</p>

<p align="center"><b>Sharded sequence alignment as a single bash + DuckDB binary.</b></p>

`shaln` wraps the [`duckdb-miint`](https://github.com/the-miint/duckdb-miint) extension's
sharded aligners (`align_minimap2_sharded`, `align_bowtie2_sharded`) in a small, dependency-light
CLI. You build a **bundle** of reference shards once, then align reads against it — routed to the
right shard by a [rype](https://github.com/wasade/rype) index, or broadcast to every shard.

Its only runtime dependencies are **DuckDB ≥ 1.5.4** and **bash**.

```
reads ──▶ shaln align ──▶ route (rype | broadcast) ──▶ per-shard minimap2/bowtie2 ──▶ SAM / BAM / Parquet / Arrow
                              against a bundle built by `shaln index`
```

## Install

```bash
git clone https://github.com/the-miint/shaln && cd shaln
./install.sh          # vendors a pinned DuckDB CLI next to ./shaln
./shaln help
```

`install.sh` downloads a DuckDB CLI build into the repo (auto-detecting macOS/Linux + arch).
The `miint` extension is fetched on demand by DuckDB (`INSTALL miint FROM community`).

Overrides:

| Variable | Purpose |
| --- | --- |
| `SHALN_DUCKDB` | Path to a `duckdb` binary (≥ 1.5.4) to use instead of the vendored one. |
| `SHALN_EXTENSION_PATH` | Load a local (unsigned) `miint.duckdb_extension` instead of the community build. |
| `SHALN_DUCKDB_VERSION` / `SHALN_DUCKDB_URL` | Pin / override what `install.sh` fetches. |

## Quickstart — a real, end-to-end example

Build a 2-shard bundle from two small public genomes, then align a public sequencing run
against it. `$DUCKDB` is your DuckDB binary (`./duckdb` after `install.sh`, or any `duckdb ≥ 1.5.4`).

```bash
DUCKDB=./duckdb     # or: DUCKDB=duckdb

# 1. Fetch references (phiX174 + lambda) and write a FASTA.
"$DUCKDB" -c "INSTALL miint FROM community; LOAD miint;
  COPY (SELECT read_id, sequence1 FROM read_ncbi_fasta(['NC_001422.1','NC_001416.1']))
  TO 'refs.fasta' (FORMAT fasta);"

# 2. Derive a shard map (reference_id <TAB> shard_name) straight from the FASTA's ids,
#    round-robin into two shards. Edit this to group references however you like.
"$DUCKDB" -c "INSTALL miint FROM community; LOAD miint;
  COPY (
    SELECT read_id AS reference_id,
           'shard_' || ((row_number() OVER (ORDER BY read_id) - 1) % 2)::VARCHAR AS shard_name
    FROM read_fastx('refs.fasta')
  ) TO 'shard-map.tsv' (FORMAT csv, DELIMITER '\t', HEADER false);"

# 3. Build the bundle (per-shard .mmi indexes + rype routing index + lengths + manifest).
./shaln index --references refs.fasta --shard-map shard-map.tsv -o bundle --verbose

# 4. Fetch a public sequencing run and align it against the bundle.
"$DUCKDB" -c "INSTALL miint FROM community; LOAD miint;
  COPY (SELECT * FROM read_ena_sequences('ERR1074767', max_sequences := 2000))
  TO 'reads.parquet' (FORMAT PARQUET);"

# 5. Align -> BAM and Parquet. (--recover-names writes original read names as QNAMEs;
#    omit it to stream with the integer sequence_index instead — see "Read names" below.)
./shaln align --bundle bundle --parquet reads.parquet --recover-names -o aln.bam --verbose
./shaln align --bundle bundle --parquet reads.parquet --recover-names --format parquet -o aln.parquet
```

phiX174 is the standard Illumina spike-in, so a typical Illumina run aligns its spike-in reads to
the phiX shard. Reads that match no shard above the routing threshold are simply not aligned — pass
`--broadcast` to align every read against every shard instead of using rype routing.

> The bundled `tests/run.sh` exercises this exact pipeline (index → align → BAM/Parquet) offline on
> tiny fixtures, so the mechanics are verified without network access.

### bowtie2 variant (optional)

`shaln` can build and align bowtie2 bundles instead of minimap2. bowtie2 support comes from the
[`gpl-boundary`](https://github.com/the-miint/gpl-boundary) helper (it bundles `bowtie2`). You don't
need to install it by hand — the first `--aligner bowtie2` run **installs gpl-boundary automatically**
(it needs network access + `curl`), and prints a clear, actionable message if that can't be done:

```bash
./shaln index --aligner bowtie2 --references refs.fasta --shard-map shard-map.tsv -o bundle_bt2
./shaln align --bundle bundle_bt2 --parquet reads.parquet -o aln_bt2.bam
```

## Commands

Run `shaln <command> --help` for the full option list.

### `shaln index`

Build a bundle from references + a shard map.

```
shaln index --references <fasta|parquet> --shard-map <tsv> -o <bundle> [options]
```

- `--references` — FASTA/FASTQ, or Parquet in the `read_fastx` schema.
- `--shard-map` — headerless 2-column TSV: `reference_id <TAB> shard_name`. Only references listed
  here are indexed; others are ignored.
- `--aligner minimap2|bowtie2` (default `minimap2`; bowtie2 auto-installs gpl-boundary on first use).
- minimap2 index knobs `--preset/--k/--w/--eqx` are baked into the `.mmi` at index time.
- `--chunk-size`, `--threads`, `--verbose`.
- `--in-memory` — hold references in a RAM table instead of streaming them from a temp Parquet (see
  **Streaming & memory** below).

The bundle is a directory containing per-shard indexes (`<shard>.mmi` or `<shard>/index.*.bt2`), a
rype routing index (`rype.ryxdi`), `lengths.parquet` (for SAM/BAM headers), and `manifest.tsv`.

### `shaln align`

Align reads against a bundle.

```
shaln align --bundle <dir> <reads-input> [-o PATH] [--format sam|bam|parquet|arrow] [options]
```

- Reads input (choose one; `-` = stdin): `--fasta`/`--fastq` (single-end), `-1`/`-2` (paired),
  `--interleaved` (native de-interleave), `--parquet`, `--arrow` (Arrow IPC).
- Output: `-o PATH` (or stdout). Format inferred from the extension — including compound/compressed
  ones: `.sam`, **`.sam.gz`** (gzip/BGZF), `.bam`, `.parquet`/`.pq`, `.arrow` — else SAM. Parquet needs
  `-o`; SAM/BAM/Arrow can stream to stdout (`-o -`), e.g. piped into another DuckDB.
- `--compress gzip|none` — gzip-compress SAM output (default: gzip if `-o` ends in `.gz`, else none).
  BAM is always BGZF; **Parquet output is always zstd**.
- `--include-seq-qual` writes SEQ/QUAL into SAM/BAM (default `*`).
- `--recover-names` — emit each read's **original name** as the QNAME. **Off by default**: the QNAME
  is the integer `sequence_index` (the routing key), which keeps alignment fully streaming. See
  *Read names vs. sequence_index* below.
- Routing: rype by default, or `--broadcast` to align every read against every shard.
- **Alignment passthrough:** the full minimap2 / bowtie2 map-time option surface is exposed (scoring,
  gaps, bandwidth, chaining, seeding, mate constraints, …). Only options valid for the bundle's aligner
  are accepted; the rest are rejected loudly. Run `shaln align --help` for the complete, current list.
- The aligner is taken from the bundle manifest. Only mapped alignment records are written.

#### Streaming & memory

By default `shaln` is built to handle **read sets and reference sets larger than RAM**. It holds no
whole-input table in memory:

- Non-Parquet inputs (FASTA/FASTQ, interleaved, Arrow, stdin) and references are normalized **once** to
  a temporary **zstd Parquet** in `$TMPDIR`, then exposed as views and streamed input → output (each
  shard re-scans the Parquet from disk). The temp files are removed on exit.
- Parquet inputs are used directly (no copy). They must carry a unique `BIGINT sequence_index` column
  (which `read_fastx` assigns) — shaln verifies this and fails loudly otherwise.
- Routing and alignment join on the cheap **`BIGINT sequence_index`**, not the VARCHAR read name; the
  original read name is recovered for the output. (QNAMEs in the SAM/BAM are always the original names.)

Flags to control this:

| Flag | Effect |
| --- | --- |
| `--in-memory` | Hold reads + routing (or references, for `shaln index`) in RAM tables — the fast path for inputs that comfortably fit. Skips the Parquet round-trip. |
| `--reads-cache PATH` | Persist the normalized reads Parquet at `PATH` (reuse across runs) instead of an auto-deleted temp file. |
| `--save-routing PATH` | Write the read→shard map (zstd Parquet) to `PATH`. Keyed by `sequence_index`. |

#### Read names vs. `sequence_index`

To stay streaming, alignment routes and reports on the cheap **`BIGINT sequence_index`**, not the
read name. So **by default the output QNAME is the integer `sequence_index`**, not the original read
name. This avoids a read-scale join on the hot path (recovering names means hash-joining every
alignment back to the full read→name map, which is read-scale and spills to disk under memory pressure).

Two ways to get names:

- **`--recover-names`** — shaln does the join for you and writes original names inline. Convenient for
  smaller runs; pay the read-scale join.
- **Map back afterwards** (recommended at scale) — keep the reads with `--reads-cache reads.parquet`
  (it has `sequence_index` + `read_id`), then join your alignments on `sequence_index`. For example,
  with Parquet output:

  ```sql
  SELECT r.read_id AS qname, a.* EXCLUDE (read_id)
  FROM read_parquet('aln.parquet') a
  JOIN read_parquet('reads.parquet') r ON a.read_id = r.sequence_index;
  ```

## Requirements

- **DuckDB ≥ 1.5.4** (`install.sh` vendors one, or set `SHALN_DUCKDB`).
- The **`miint`** DuckDB extension (auto-installed from the community repo, or `SHALN_EXTENSION_PATH`).
- **bowtie2 bundles** additionally need the `gpl-boundary` daemon — `shaln` installs it automatically
  on first use (needs network + `curl`).
- **Arrow I/O** loads the community `arrow` extension on demand.

## Development

```bash
# Run the test suite (bash 3.2+; no extra deps).
bash tests/run.sh
```

Unit tests run anywhere; the integration tests run only when `SHALN_DUCKDB` and
`SHALN_EXTENSION_PATH` point at a real DuckDB + `miint` build (otherwise they skip).
