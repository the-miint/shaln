#!/usr/bin/env bash
#
# install.sh — vendor a pinned DuckDB CLI next to `shaln` so the tool works out
# of the box. After this, `shaln` discovers ./duckdb automatically.
#
#   ./install.sh
#
# Overrides:
#   SHALN_DUCKDB_VERSION   DuckDB version to fetch (default below).
#   SHALN_DUCKDB_URL       Full download URL (bypasses version/platform logic).
#
# This only provides duckdb. The miint extension is fetched on demand by DuckDB
# (`INSTALL miint FROM community`); to use a local build instead, set
# SHALN_EXTENSION_PATH when running `shaln`.
#
# Safe to `source` (for tests): defines functions; runs only when executed.

SHALN_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHALN_DUCKDB_DEFAULT_VERSION="1.5.4"

shaln_install_err() { printf 'install: error: %s\n' "$*" >&2; }

# shaln_install_asset <os> <arch> — map uname output to the DuckDB CLI release
# asset platform tag. Errors to stderr + return 1 on an unsupported platform.
shaln_install_asset() {
  case "$1" in
  Darwin) printf 'osx-universal' ;;
  Linux)
    case "$2" in
    x86_64 | amd64) printf 'linux-amd64' ;;
    aarch64 | arm64) printf 'linux-arm64' ;;
    *)
      shaln_install_err "unsupported Linux architecture '$2'"
      return 1
      ;;
    esac
    ;;
  *)
    shaln_install_err "unsupported OS '$1' (set SHALN_DUCKDB_URL to install manually)"
    return 1
    ;;
  esac
}

# shaln_install_url <version> <asset> — DuckDB CLI zip download URL.
shaln_install_url() {
  printf 'https://github.com/duckdb/duckdb/releases/download/v%s/duckdb_cli-%s.zip' "$1" "$2"
}

shaln_install_main() {
  set -euo pipefail
  local version asset url os arch
  version="${SHALN_DUCKDB_VERSION:-$SHALN_DUCKDB_DEFAULT_VERSION}"
  os="$(uname -s)"
  arch="$(uname -m)"
  asset="$(shaln_install_asset "$os" "$arch")" || exit 1
  url="${SHALN_DUCKDB_URL:-$(shaln_install_url "$version" "$asset")}"

  command -v curl >/dev/null 2>&1 || {
    shaln_install_err "curl is required"
    exit 1
  }
  command -v unzip >/dev/null 2>&1 || {
    shaln_install_err "unzip is required"
    exit 1
  }

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/shaln-install.XXXXXX")"
  printf 'install: fetching DuckDB %s (%s)\n' "$version" "$asset" >&2
  printf 'install:   %s\n' "$url" >&2
  curl -fSL "$url" -o "$tmp/duckdb.zip" || {
    shaln_install_err "download failed; set SHALN_DUCKDB_URL to a valid DuckDB CLI zip and retry"
    exit 1
  }
  # Extract to a temp dir and move only the duckdb binary into place — avoids
  # zip-slip and stray files if the archive layout ever changes.
  unzip -o -q "$tmp/duckdb.zip" -d "$tmp/x" || {
    shaln_install_err "unzip failed"
    exit 1
  }
  [[ -f "$tmp/x/duckdb" ]] || {
    shaln_install_err "archive did not contain a 'duckdb' binary"
    exit 1
  }
  mv "$tmp/x/duckdb" "$SHALN_HOME/duckdb"
  chmod +x "$SHALN_HOME/duckdb"

  local got
  got="$("$SHALN_HOME/duckdb" --version 2>/dev/null || true)"
  printf 'install: vendored duckdb -> %s (%s)\n' "$SHALN_HOME/duckdb" "$got" >&2
  printf "install: done. Run '%s/shaln help' to get started.\n" "$SHALN_HOME" >&2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  shaln_install_main "$@"
fi
