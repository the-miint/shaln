# shaln

**Sharded sequence alignment as a single bash + DuckDB binary.**

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

# 5. Align -> BAM and Parquet.
./shaln align --bundle bundle --parquet reads.parquet -o aln.bam --verbose
./shaln align --bundle bundle --parquet reads.parquet --format parquet -o aln.parquet
```

phiX174 is the standard Illumina spike-in, so a typical Illumina run aligns its spike-in reads to
the phiX shard. Reads that match no shard above the routing threshold are simply not aligned — pass
`--broadcast` to align every read against every shard instead of using rype routing.

> The bundled `tests/run.sh` exercises this exact pipeline (index → align → BAM/Parquet) offline on
> tiny fixtures, so the mechanics are verified without network access.

### bowtie2 variant (optional)

`shaln` can build and align bowtie2 bundles instead of minimap2. This requires the
[`gpl-boundary`](https://github.com/the-miint/gpl-boundary) daemon (it bundles `bowtie2`):

```bash
"$DUCKDB" -c "INSTALL miint FROM community; LOAD miint; SELECT install_gpl_boundary();"
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
- `--aligner minimap2|bowtie2` (default `minimap2`; bowtie2 needs gpl-boundary).
- minimap2 index knobs `--preset/--k/--w/--eqx` are baked into the `.mmi` at index time.
- `--chunk-size`, `--threads`, `--verbose`.

The bundle is a directory containing per-shard indexes (`<shard>.mmi` or `<shard>/index.*.bt2`), a
rype routing index (`rype.ryxdi`), `lengths.parquet` (for SAM/BAM headers), and `manifest.tsv`.

### `shaln align`

Align reads against a bundle.

```
shaln align --bundle <dir> <reads-input> [-o PATH] [--format sam|bam|parquet|arrow] [options]
```

- Reads input (choose one; `-` = stdin): `--fasta`/`--fastq` (single-end), `-1`/`-2` (paired),
  `--interleaved`, `--parquet`, `--arrow` (Arrow IPC).
- Output: `-o PATH` (or stdout). Format inferred from the extension, else SAM. Parquet needs `-o`.
  SAM/BAM/Arrow can stream to stdout (`-o -`), e.g. piped into another DuckDB.
- `--include-seq-qual` writes SEQ/QUAL into SAM/BAM (default `*`).
- Routing: rype by default, or `--broadcast` to align every read against every shard.
- The aligner is taken from the bundle manifest. Only mapped alignment records are written.

## Requirements

- **DuckDB ≥ 1.5.4** (`install.sh` vendors one, or set `SHALN_DUCKDB`).
- The **`miint`** DuckDB extension (auto-installed from the community repo, or `SHALN_EXTENSION_PATH`).
- **bowtie2 bundles** additionally need the `gpl-boundary` daemon (`SELECT install_gpl_boundary();`).
- **Arrow I/O** loads the community `arrow` extension on demand.

## Development

```bash
# Run the test suite (bash 3.2+; no extra deps).
bash tests/run.sh
```

Unit tests run anywhere; the integration tests run only when `SHALN_DUCKDB` and
`SHALN_EXTENSION_PATH` point at a real DuckDB + `miint` build (otherwise they skip).
