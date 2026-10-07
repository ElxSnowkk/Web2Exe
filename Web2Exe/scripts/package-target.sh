#!/usr/bin/env bash
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF/common.sh"
target="${1:?uso: package-target.sh x86|x64|arm64}"

prop_load "$PROJECT_ROOT/build.prop"
dir="$PROJECT_ROOT/dist/$target"
exe="$dir/${APP_ID_SAFE}.exe"
[[ -f "$exe" ]] || fail "Executável ausente: $exe"

tool() { # tool <nome> -> caminho (TOOL_DIR, depois PATH)
  local t="$1"
  if [[ -n "${TOOL_DIR:-}" && -x "$TOOL_DIR/$t" ]]; then echo "$TOOL_DIR/$t"; return; fi
  command -v "$t" || true
}
readobj="$(tool llvm-readobj)"; [[ -n "$readobj" ]] || fail "llvm-readobj ausente (pkg install llvm)"
objdump="$(tool llvm-objdump)"; [[ -n "$objdump" ]] || fail "llvm-objdump ausente (pkg install llvm)"

hdr="$("$readobj" --file-headers "$exe")"
case "$target" in
  x86)   [[ "$hdr" == *I386* ]]  || fail "PE não corresponde a x86";;
  x64)   [[ "$hdr" == *AMD64* || "$hdr" == *X86_64* ]] || fail "PE não corresponde a x64";;
  arm64) [[ "$hdr" == *ARM64* ]] || fail "PE não corresponde a ARM64";;
esac

mkdir -p "$TMP_DIR"
deps="$TMP_DIR/deps-$target.txt"
"$objdump" -p "$exe" | awk '/DLL Name:/{print $3}' | sort -u > "$deps"

# DLLs do próprio Windows: nunca empacotar.
is_system_dll() {
  case "${1,,}" in
    kernel32.dll|user32.dll|gdi32.dll|advapi32.dll|shell32.dll|ole32.dll|oleaut32.dll|shlwapi.dll|version.dll|comdlg32.dll|combase.dll|\
    msvcrt.dll|ucrtbase.dll|ntdll.dll|rpcrt4.dll|sechost.dll|bcrypt.dll|ws2_32.dll|imm32.dll|comctl32.dll|dwmapi.dll|crypt32.dll|\
    uxtheme.dll|winmm.dll|api-ms-win-*) return 0;;
  esac
  return 1
}

while IFS= read -r dll; do
  [[ -n "$dll" ]] || continue
  is_system_dll "$dll" && continue
  src="$(find "${LLVM_ROOT:-/nonexistent}" -type f -ipath "*/$(triple_prefix "$target")-w64-mingw32/*" -iname "$dll" -print -quit 2>/dev/null || true)"
  if [[ -n "$src" ]]; then
    [[ -f "$dir/$dll" ]] || cp "$src" "$dir/"
    log "[$target] DLL do runtime empacotada: $dll"
  else
    warn "[$target] dependência '$dll' não é do MinGW; assumindo DLL do Windows."
  fi
done < "$deps"

[[ -f "$dir/WebView2Loader.dll" ]] || fail "WebView2Loader.dll ausente em $dir"
ok "$target validado e empacotado"
