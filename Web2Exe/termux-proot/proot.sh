#!/usr/bin/env bash
# Atalho: compila o projeto atual dentro do Debian do proot-distro.
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEB2EXE_DATA_ROOT="${WEB2EXE_DATA_ROOT:-$SELF}" WEB2EXE_PROJECT_ROOT="${WEB2EXE_PROJECT_ROOT:-$PWD}"
exec bash "$SELF/scripts/termux-build.sh" proot
