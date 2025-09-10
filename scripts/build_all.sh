#!/usr/bin/env bash
set -euo pipefail

# Build CipherCopy GUI (Flutter desktop) and CLI (Dart) executables.
# This script builds for the current host OS by default.
# To attempt all platforms, pass --platforms=all (non-host platforms will be skipped with a note).
#
# Usage:
#   scripts/build_all.sh [--app] [--cli] [--platforms=macos|linux|windows|all]
#
# Outputs:
#   - app/build/<platform>/... (Flutter desktop artifacts)
#   - cli/dist/cli/<platform>/ciphercopy[.exe] (native CLI)

ROOT_DIR="$({ cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; } 2>/dev/null)"
APP_DIR="${ROOT_DIR}/app"
CLI_DIR="${ROOT_DIR}/cli"

has_cmd() { command -v "$1" >/dev/null 2>&1; }

normalize_os() {
  local u
  u=$(uname -s 2>/dev/null || echo unknown)
  case "$u" in
    Darwin) echo macos ;;
    Linux) echo linux ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}

HOST_OS=$(normalize_os)
DO_APP=1
DO_CLI=1
PLATFORMS="$HOST_OS"

for arg in "$@"; do
  case "$arg" in
    --app) DO_APP=1; DO_CLI=0 ;;
    --cli) DO_APP=0; DO_CLI=1 ;;
    --platforms=*) PLATFORMS="${arg#*=}" ;;
    -h|--help)
      sed -n '1,40p' "$0"; exit 0 ;;
  esac
done

IFS=',' read -r -a REQ_PLATS <<< "$PLATFORMS"

echo "==> Host OS: ${HOST_OS}"

echo "==> Targets: ${REQ_PLATS[*]} | Components: app=${DO_APP} cli=${DO_CLI}"

build_app() {
  local plat="$1"
  if [[ ${DO_APP} -ne 1 ]]; then return 0; fi
  if ! has_cmd flutter; then
    echo "[app/${plat}] Skipped: 'flutter' not found" >&2
    return 0
  fi
  if [[ "$plat" != "$HOST_OS" ]]; then
    echo "[app/${plat}] Skipped: build must run on ${plat} host" >&2
    return 0
  fi
  echo "[app/${plat}] Running flutter build ${plat}..."
  pushd "$APP_DIR" >/dev/null
  flutter pub get >/dev/null
  case "$plat" in
    macos) flutter config --enable-macos-desktop >/dev/null || true; flutter build macos ;;
    linux) flutter config --enable-linux-desktop  >/dev/null || true; flutter build linux ;;
    windows) flutter config --enable-windows-desktop >/dev/null || true; flutter build windows ;;
    *) echo "[app/${plat}] Unknown platform" >&2 ;;
  esac
  popd >/dev/null
}

build_cli() {
  local plat="$1"
  if [[ ${DO_CLI} -ne 1 ]]; then return 0; fi
  if ! has_cmd dart; then
    echo "[cli/${plat}] Skipped: 'dart' not found" >&2
    return 0
  fi
  if [[ "$plat" != "$HOST_OS" ]]; then
    echo "[cli/${plat}] Skipped: native compile must run on ${plat} host" >&2
    return 0
  fi
  echo "[cli/${plat}] Compiling dart -> native exe..."
  pushd "$CLI_DIR" >/dev/null
  dart pub get >/dev/null
  local OUT_DIR="${CLI_DIR}/dist/cli/${plat}"
  mkdir -p "$OUT_DIR"
  local BIN_NAME="ciphercopy"
  [[ "$plat" == "windows" ]] && BIN_NAME+=".exe"
  dart compile exe "bin/ciphercopy_cli.dart" -o "${OUT_DIR}/${BIN_NAME}"
  echo "[cli/${plat}] → ${OUT_DIR}/${BIN_NAME}"
  popd >/dev/null
}

STATUS=0
for p in "${REQ_PLATS[@]}"; do
  case "$p" in
    macos|linux|windows) : ;;
    all) REQ_PLATS=(macos linux windows); break ;;
    *) echo "Unknown platform: $p" >&2; STATUS=1 ;;
  esac
done

if [[ $STATUS -ne 0 ]]; then exit $STATUS; fi

for p in "${REQ_PLATS[@]}"; do
  build_app "$p" || STATUS=$?
  build_cli "$p" || STATUS=$?
  echo
done

echo "==> Done"
exit $STATUS
