#!/usr/bin/env bash
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF/common.sh"

prop_load "$PROJECT_ROOT/build.prop"; prop_validate
[[ -n "${TOOL_DIR:-}" ]] || prepare_tools
[[ -x "$TMP_DIR/host/archive_builder" ]] || { mkdir -p "$TMP_DIR"; build_host_tools; }

W="$TMP_DIR/installer"; mkdir -p "$W" "$PROJECT_ROOT/dist"
"$TMP_DIR/host/archive_builder" "$PROJECT_ROOT/dist" "$W/payload.bin" || fail "Falha ao montar o payload (dist/x86, x64 e arm64 precisam existir)"
"$TMP_DIR/host/installer_generator" "$ROOT/src/installer/installer.cpp" "$W/installer.cpp" \
  "$APP_NAME" "$APP_ID_SAFE" "$APP_ID_SAFE" "$APP_VERSION" "$INSTALL_DIR"

# Manifesto do instalador = manifesto do app (asInvoker, per-user).
cp "$ROOT/src/installer/installer.manifest" "$W/installer.manifest"
icon="${APP_ICON//\\//}"
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
cat > "$W/installer.rc" <<RCEOF
#pragma code_page(65001)
#include <windows.h>
1 ICON "$(esc "$icon")"
1 RT_MANIFEST "$(esc "$W/installer.manifest")"
W2E_PAYLOAD RCDATA "$(esc "$W/payload.bin")"
VS_VERSION_INFO VERSIONINFO
 FILEVERSION 1,0,0,0
 PRODUCTVERSION 1,0,0,0
 FILEFLAGSMASK 0x3fL
 FILEOS 0x40004L
 FILETYPE 0x1L
BEGIN
 BLOCK "StringFileInfo"
 BEGIN
  BLOCK "040904b0"
  BEGIN
   VALUE "FileDescription", "$(esc "$APP_NAME") Setup"
   VALUE "ProductName", "$(esc "$APP_NAME")"
   VALUE "ProductVersion", "$APP_VERSION"
   VALUE "CompanyName", "Web2Exe"
  END
 END
 BLOCK "VarFileInfo" BEGIN VALUE "Translation", 0x409, 1200 END
END
RCEOF

select_toolchain installer   # instalador universal = PE x86 (msvcrt quando WINE_COMPAT=1)
out="$PROJECT_ROOT/dist/${APP_NAME_SAFE}-Setup.exe"
rc_obj="$W/installer_res.o"
case "$(basename "$RC")" in
  *windres*) "$RC" -O coff -i "$W/installer.rc" -o "$rc_obj" -c 65001;;
  *)         "$RC" /fo "$W/installer.res" "$W/installer.rc"; rc_obj="$W/installer.res";;
esac
"$CXX" ${WINE_FLAGS[@]+"${WINE_FLAGS[@]}"} -std=c++20 -O2 -s -static -fuse-ld=lld -DUNICODE -D_UNICODE -municode -mwindows \
  "$W/installer.cpp" "$rc_obj" -o "$out" \
  -lshell32 -lole32 -loleaut32 -ladvapi32 -luser32 -lgdi32 -lcomctl32 -luuid
[[ -f "$out" ]] || fail "Instalador não foi gerado"
if [[ "${WINE_COMPAT:-0}" == 1 ]]; then verify_wine_pe "$out" "instalador"; fi
ok "Instalador universal gerado: $out ($(du -h "$out" | cut -f1))"
