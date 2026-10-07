#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"&&pwd)";cmake -S "$ROOT" -B "$ROOT/build/cli" -DWEB2EXE_BUILD_CLI=ON -DWEB2EXE_BUILD_APP=OFF -DWEB2EXE_BUILD_INSTALLER=OFF;cmake --build "$ROOT/build/cli" --parallel
