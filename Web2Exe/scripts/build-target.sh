#!/usr/bin/env bash
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF/common.sh"
target="${1:?uso: build-target.sh x86|x64|arm64}"

prop_load "$PROJECT_ROOT/build.prop"; prop_validate
[[ -n "${TOOL_DIR:-}" ]] || prepare_tools
[[ -n "${WEBVIEW2_SDK:-}" ]] || prepare_webview
[[ -x "$TMP_DIR/host/app_generator" ]] || { mkdir -p "$TMP_DIR"; build_host_tools; }
select_toolchain "$target"

case "$target" in
  x86) tc=windows-x86.cmake; loader=x86;; wine) tc=windows-x86.cmake; loader="";; x64) tc=windows-x64.cmake; loader=x64;; arm64) tc=windows-arm64.cmake; loader=arm64;;
esac
B="$PROJECT_ROOT/build/$target"
rm -rf "$B"; mkdir -p "$B/generated" "$PROJECT_ROOT/dist/$target"

"$TMP_DIR/host/app_generator" \
  "$ROOT/src/app/main.cpp" "$ROOT/src/app/resources.rc" "$ROOT/src/app/app.manifest" \
  "$APP_NAME" "$APP_VERSION" "$APP_ID" "$APP_URL" "$APP_ICON" \
  "$B/generated/main.cpp" "$B/generated/resources.rc" "$B/generated/app.manifest"

wine_args=(); wine_flags=""
if [[ "$target" == wine ]]; then
  [[ "${WINE_COMPAT:-0}" == 1 ]] || fail "A variante wine exige WINE_COMPAT=1"
  wine_args=(-DWEB2EXE_WINE=ON)
  wine_flags="${WINE_FLAGS[*]:-}"
  log "[$target] modo Wine ativo (${wine_flags:-msvcrt nativo do toolchain})"
fi

gen=(); command -v ninja >/dev/null 2>&1 && gen=(-G Ninja)
cmake -S "$ROOT" -B "$B" "${gen[@]}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/cmake/$tc" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_RC_COMPILER="$RC" \
  -DWEBVIEW2_SDK="$WEBVIEW2_SDK" ${wine_args[@]+"${wine_args[@]}"} \
  ${wine_flags:+-DCMAKE_C_FLAGS="$wine_flags" -DCMAKE_CXX_FLAGS="$wine_flags"} \
  -DWEB2EXE_BUILD_CLI=OFF -DWEB2EXE_BUILD_APP=ON \
  -DWEB2EXE_GENERATED_APP_DIR_OVERRIDE="$B/generated"
cmake --build "$B" --parallel

if [[ "$target" == wine ]]; then verify_wine_pe "$B/web2exe_app.exe" "app $target"; fi
cp "$B/web2exe_app.exe" "$PROJECT_ROOT/dist/$target/${APP_ID_SAFE}.exe"
if [[ -n "$loader" ]]; then   # a variante wine não usa WebView2
  loader_dll="$WEBVIEW2_SDK/build/native/$loader/WebView2Loader.dll"
  [[ -f "$loader_dll" ]] || fail "WebView2Loader.dll ausente no SDK: $loader_dll"
  cp "$loader_dll" "$PROJECT_ROOT/dist/$target/"
fi
ok "[$target] ${APP_ID_SAFE}.exe gerado"
