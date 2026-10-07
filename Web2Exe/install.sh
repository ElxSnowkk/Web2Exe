#!/usr/bin/env bash
# Instala o Web2Exe no Termux: CLI em $PREFIX/bin/web2exe, recursos em $PREFIX/share/web2exe.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-}"
if [[ -z "$PREFIX" || ! -d "$PREFIX" ]]; then printf '%s\n' '[ERR ] PREFIX do Termux não está disponível. (Em Linux comum use ./linux-build.sh)' >&2; exit 1; fi
for t in cmake clang bash; do
  command -v "$t" >/dev/null 2>&1 || { printf '%s\n' "[ERR ] '$t' ausente. Instale: pkg install cmake clang" >&2; exit 2; }
done

DATA="$PREFIX/share/web2exe"
TMP="${TMPDIR:-$PREFIX/tmp}/web2exe-install.$$"
trap 'rm -rf "$TMP"' EXIT
rm -rf "$TMP" "$DATA"
mkdir -p "$TMP" "$DATA" "$PREFIX/bin"

printf '%s\n' '[INFO] Compilando o CLI com o compilador nativo do Termux...'
cmake -S "$SRC" -B "$TMP/build" -DCMAKE_BUILD_TYPE=Release -DWEB2EXE_BUILD_CLI=ON -DWEB2EXE_BUILD_APP=OFF
cmake --build "$TMP/build" --parallel

for item in scripts cmake src assets termux-proot; do [[ -e "$SRC/$item" ]] && cp -a "$SRC/$item" "$DATA/"; done
cp "$SRC/CMakeLists.txt" "$SRC/LICENSE" "$DATA/"
# O zip/cópia pode perder o bit +x; garante permissões.
find "$DATA/scripts" "$DATA/termux-proot" -type f -name '*.sh' -exec chmod 755 {} + 2>/dev/null || true
cp "$TMP/build/web2exe" "$DATA/web2exe"
chmod 755 "$DATA/web2exe"

# Launcher: o PROJECT_ROOT é o diretório atual; BASH/BASH_ENV herdados são descartados
# (um $BASH inválido no ambiente causava "exit 127" mudo).
cat > "$PREFIX/bin/web2exe" <<LAUNCHER
#!$PREFIX/bin/bash
set -euo pipefail
unset BASH BASH_ENV ENV
export WEB2EXE_DATA_ROOT="$DATA"
export WEB2EXE_PROJECT_ROOT="\${WEB2EXE_PROJECT_ROOT:-\$PWD}"
exec "$DATA/web2exe" "\$@"
LAUNCHER
chmod 755 "$PREFIX/bin/web2exe"

printf '%s\n' '[ OK ] Web2Exe instalado.' "[ OK ] CLI:   $PREFIX/bin/web2exe" "[ OK ] Dados: $DATA"
printf '%s\n' '[INFO] Diagnóstico: web2exe doctor'
