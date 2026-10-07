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

# Variante Wine no instalador único: auto = tenta e, se não houver toolchain msvcrt, segue sem ela.
if [[ "$WINE_COMPAT" == auto ]]; then
  if ( WINE_COMPAT=1; select_toolchain installer ) >/dev/null 2>"$TMP_DIR/wine-probe.log"; then
    WINE_COMPAT=1; ok "Modo Wine disponível: o instalador incluirá a variante Wine"
  else
    WINE_COMPAT=0; warn "Sem toolchain msvcrt: instalador sem variante Wine (detalhes: $TMP_DIR/wine-probe.log). Veja o README, seção Modo Wine."
  fi
fi
export WEB2EXE_WINE="$WINE_COMPAT"

for target in x86 x64 arm64; do
  log "[$target] Compilando"
  "${BASH:-bash}" "$SELF/build-target.sh" "$target"
done
if [[ "$WINE_COMPAT" == 1 ]]; then
  log "[wine] Compilando variante Wine (x86, msvcrt)"
  "${BASH:-bash}" "$SELF/build-target.sh" wine
fi
log "Validando PE e coletando DLLs"
for target in x86 x64 arm64; do "${BASH:-bash}" "$SELF/package-target.sh" "$target"; done
log "Gerando instalador universal"
"${BASH:-bash}" "$SELF/make-installer.sh"
ok "Build concluído: $PROJECT_ROOT/dist/${APP_NAME_SAFE}-Setup.exe"
