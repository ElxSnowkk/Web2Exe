#!/usr/bin/env bash
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF/common.sh"

prop_load "$PROJECT_ROOT/build.prop"
prop_validate

if [[ "${WEB2EXE_TOOLCHAIN_MODE:-}" == "termux-native" ]]; then
  prepare_termux_native_tools
else
  prepare_tools
fi
prepare_webview

rm -rf "$PROJECT_ROOT/build" "$PROJECT_ROOT/dist" "$TMP_DIR"
mkdir -p "$PROJECT_ROOT/build" "$PROJECT_ROOT/dist" "$TMP_DIR"
build_host_tools

for target in x86 x64 arm64; do
  log "[$target] Compilando"
  "${BASH:-bash}" "$SELF/build-target.sh" "$target"
done
log "Validando PE e coletando DLLs"
for target in x86 x64 arm64; do "${BASH:-bash}" "$SELF/package-target.sh" "$target"; done
log "Gerando instalador universal"
"${BASH:-bash}" "$SELF/make-installer.sh"
ok "Build concluído: $PROJECT_ROOT/dist/${APP_NAME_SAFE}-Setup.exe"
