#!/usr/bin/env bash
# Funções compartilhadas pelos scripts do Web2Exe.
# Este arquivo é "sourced"; não execute diretamente.

ROOT="${WEB2EXE_DATA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ROOT="${WEB2EXE_PROJECT_ROOT:-$PWD}"
CACHE="${WEB2EXE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/web2exe}"
TMP_DIR="$PROJECT_ROOT/.web2exe-tmp"

LLVM_VERSION="${WEB2EXE_LLVM_VERSION:-20260922}"
LLVM_CRT="ucrt"
WEBVIEW2_VERSION="${WEBVIEW2_VERSION:-1.0.4258.31}"
LLVM_BASE="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_VERSION}"
WEBVIEW2_URL="https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/${WEBVIEW2_VERSION}"

log()  { printf '%s\n' "[INFO] $*"; }
ok()   { printf '%s\n' "[ OK ] $*"; }
warn() { printf '%s\n' "[WARN] $*" >&2; }
fail() { printf '%s\n' "[ERR ] $*" >&2; exit 1; }

# Mostra onde o script morreu (nada de falhas mudas).
trap 'rc=$?; printf "%s\n" "[ERR ] falhou (código $rc) em ${BASH_SOURCE[0]##*/} linha $LINENO: $BASH_COMMAND" >&2' ERR

# ------------------------------------------------------------ build.prop ----
prop_load() {
  local f="$1" line key value current_key="" first
  [[ -f "$f" ]] || fail "Configuração ausente: $f"
  declare -gA PROP=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ -z "$line" ]]; then
      if [[ -n "$current_key" ]]; then PROP["$current_key"]+=$'\n'; fi
      continue
    fi
    if [[ "$line" == [[:space:]]* && -n "$current_key" ]]; then
      first="${line#"${line%%[!$' \t']*}"}"
      if [[ -n "${PROP[$current_key]:-}" ]]; then PROP["$current_key"]+=$'\n'; fi
      PROP["$current_key"]+="$first"
      continue
    fi
    if [[ "$line" == \#* || "$line" == \;* ]]; then continue; fi
    [[ "$line" == *=* ]] || fail "Linha inválida em build.prop: $line"
    key="${line%%=*}"; value="${line#*=}"
    key="${key//[[:space:]]/}"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || fail "Chave inválida: $key"
    current_key="$key"; PROP["$key"]="$value"
  done < "$f"
  for key in "${!PROP[@]}"; do
    while [[ "${PROP[$key]}" == *$'\n' ]]; do PROP["$key"]="${PROP[$key]%$'\n'}"; done
    # remove espaços nas pontas
    PROP["$key"]="${PROP[$key]#"${PROP[$key]%%[![:space:]]*}"}"
    PROP["$key"]="${PROP[$key]%"${PROP[$key]##*[![:space:]]}"}"
  done
  APP_NAME="${PROP[APP_NAME]:-}"; APP_ID="${PROP[APP_ID]:-}"; APP_VERSION="${PROP[APP_VERSION]:-1.0.0}"
  APP_URL="${PROP[APP_URL]:-}"; APP_LOGO="${PROP[APP_LOGO]:-}"; APP_ICON="${PROP[APP_ICON]:-}"
  INSTALL_DIR="${PROP[INSTALL_DIR]:-$APP_NAME}"
  [[ "$APP_LOGO" == "~/"* ]] && APP_LOGO="$HOME/${APP_LOGO#\~/}"
  [[ "$APP_ICON" == "~/"* ]] && APP_ICON="$HOME/${APP_ICON#\~/}"
  if [[ -n "$APP_LOGO" && "$APP_LOGO" != /* ]]; then APP_LOGO="$PROJECT_ROOT/$APP_LOGO"; fi
  if [[ -n "$APP_ICON" && "$APP_ICON" != /* ]]; then APP_ICON="$PROJECT_ROOT/$APP_ICON"; fi
  APP_NAME_SAFE="$(ascii_slug "$APP_NAME")"; APP_ID_SAFE="$(ascii_slug "$APP_ID")"
  [[ -n "$APP_NAME_SAFE" ]] || APP_NAME_SAFE="$APP_ID_SAFE"
  export APP_NAME APP_ID APP_VERSION APP_URL APP_LOGO APP_ICON INSTALL_DIR APP_NAME_SAFE APP_ID_SAFE
}

# "Imobiliária Terra e Prata" -> "Imobiliaria-Terra-e-Prata" (seguro para nome de arquivo).
ascii_slug() {
  # Substituições explícitas (funcionam byte a byte, em qualquer locale, inclusive no Termux).
  local s="$1" t="" pair
  local map=(á:a à:a â:a ã:a ä:a Á:A À:A Â:A Ã:A Ä:A é:e è:e ê:e ë:e É:E È:E Ê:E Ë:E
             í:i ì:i î:i ï:i Í:I Ì:I Î:I Ï:I ó:o ò:o ô:o õ:o ö:o Ó:O Ò:O Ô:O Õ:O Ö:O
             ú:u ù:u û:u ü:u Ú:U Ù:U Û:U Ü:U ç:c Ç:C ñ:n Ñ:N)
  t="$s"
  for pair in "${map[@]}"; do t="${t//${pair%%:*}/${pair#*:}}"; done
  printf '%s' "$t" | tr -cs 'A-Za-z0-9._-' '-' | sed -e 's/^-*//' -e 's/-*$//'
}

prop_validate() {
  [[ -n "$APP_URL" ]] || fail "APP_URL está vazio"
  if [[ "$APP_URL" != https://* && "$APP_URL" != http://* ]]; then APP_URL="https://$APP_URL"; fi
  if [[ "$APP_URL" == http://* ]]; then APP_URL="https://${APP_URL#http://}"; fi
  printf '%s' "$APP_URL" | grep -Eq "^https://[^[:space:]<>\"']+$" || fail "APP_URL inválida: $APP_URL"
  [[ -n "$APP_ID" && "$APP_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$APP_ID" != . && "$APP_ID" != .. ]] \
    || fail "APP_ID deve ser um nome de .exe válido, sem a extensão"
  [[ -n "$INSTALL_DIR" && "$INSTALL_DIR" != .* ]] || fail "INSTALL_DIR inválido"
  case "$INSTALL_DIR" in *'<'*|*'>'*|*':'*|*'/'*|*\\*|*'|'*|*'?'*|*'*'*) fail "INSTALL_DIR contém caracteres inválidos";; esac
  [[ "${INSTALL_DIR: -1}" != "." && "${INSTALL_DIR: -1}" != " " ]] || fail "INSTALL_DIR não pode terminar com ponto ou espaço"
  [[ -f "$APP_LOGO" ]] || fail "APP_LOGO não existe: $APP_LOGO"
  [[ -f "$APP_ICON" ]] || fail "APP_ICON não existe: $APP_ICON"
  export APP_URL
}

# --------------------------------------------------------------- download ----
fetch() {
  local url="$1" out="$2" tmp="${2}.part"
  mkdir -p "$(dirname "$out")"; rm -f "$tmp"
  command -v curl >/dev/null || fail "curl é necessário para downloads (pkg install curl)"
  log "Baixando $url"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 --output "$tmp" "$url" \
    || fail "Falha no download: $url (verifique a internet e a versão em scripts/common.sh)"
  [[ -s "$tmp" ]] || fail "Download vazio: $url"
  mv -f "$tmp" "$out"
}

# --------------------------------------------------------------- toolchain ----
# Prefixo de triple por alvo.
triple_prefix() {
  case "$1" in
    x86) echo i686;; x64) echo x86_64;; arm64) echo aarch64;;
    *) fail "Alvo inválido: $1";;
  esac
}

# Termux: usa o LLVM-MinGW do próprio Termux (binários Bionic). Nunca baixa o tarball glibc.
prepare_termux_native_tools() {
  [[ -n "${PREFIX:-}" && -d "$PREFIX" ]] || fail "PREFIX do Termux não está disponível."
  local need=(x86_64-w64-mingw32-clang++ i686-w64-mingw32-clang++ aarch64-w64-mingw32-clang++ cmake curl unzip)
  local missing=() t
  for t in "${need[@]}"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  if ((${#missing[@]})); then
    warn "Ferramentas ausentes: ${missing[*]}"
    if command -v pkg >/dev/null 2>&1; then
      log "Tentando instalar via pkg..."
      pkg install -y llvm-mingw-w64 llvm-mingw-w64-ucrt llvm-mingw-w64-tools lld cmake curl unzip || true
    fi
    missing=()
    for t in "${need[@]}"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
    ((${#missing[@]} == 0)) || fail "Ainda faltam: ${missing[*]}. Instale com: pkg install llvm-mingw-w64 llvm-mingw-w64-ucrt llvm-mingw-w64-tools lld cmake curl unzip"
  fi
  TOOL_DIR="$(dirname "$(command -v x86_64-w64-mingw32-clang++)")"
  LLVM_ROOT="$(dirname "$TOOL_DIR")"
  export TOOL_DIR LLVM_ROOT
  ok "LLVM-MinGW nativo do Termux: $TOOL_DIR"
}

# Contêiner/Linux comum: baixa o LLVM-MinGW pré-compilado (glibc; NÃO funciona no Termux puro).
prepare_tools() {
  mkdir -p "$CACHE/llvm-mingw"
  local arch; arch="$(uname -m)"
  case "$arch" in x86_64) arch=x86_64;; aarch64|arm64) arch=aarch64;; *) fail "Host sem LLVM-MinGW pré-compilado: $arch";; esac
  local tar="$CACHE/llvm-mingw/llvm-mingw-${LLVM_VERSION}-${LLVM_CRT}-ubuntu-24.04-${arch}.tar.xz"
  local dir="$CACHE/llvm-mingw/${LLVM_VERSION}-${arch}"
  if [[ ! -x "$dir/bin/clang" ]]; then
    command -v xz >/dev/null || fail "xz é necessário (apt install xz-utils)"
    fetch "$LLVM_BASE/llvm-mingw-${LLVM_VERSION}-${LLVM_CRT}-ubuntu-24.04-${arch}.tar.xz" "$tar"
    rm -rf "$dir"; mkdir -p "$dir"
    tar -xJf "$tar" -C "$dir" --strip-components=1
  fi
  LLVM_ROOT="$dir"; TOOL_DIR="$dir/bin"; export LLVM_ROOT TOOL_DIR
  ok "LLVM-MinGW $LLVM_VERSION ($arch)"
}

prepare_webview() {
  local pkg="$CACHE/webview2/Microsoft.Web.WebView2-${WEBVIEW2_VERSION}.nupkg" dir="$CACHE/webview2/${WEBVIEW2_VERSION}"
  mkdir -p "$CACHE/webview2"
  if [[ ! -f "$dir/build/native/include/WebView2.h" ]]; then
    command -v unzip >/dev/null || fail "unzip é necessário"
    fetch "$WEBVIEW2_URL" "$pkg"
    unzip -tq "$pkg" >/dev/null || { rm -f "$pkg"; fail "Pacote WebView2 corrompido; tente novamente."; }
    rm -rf "$dir"; mkdir -p "$dir"
    unzip -q "$pkg" -d "$dir"
  fi
  WEBVIEW2_SDK="$dir"; export WEBVIEW2_SDK
  ok "WebView2 SDK $WEBVIEW2_VERSION"
}

# Define CC, CXX e RC para um alvo (x86|x64|arm64). Funciona igual nos dois modos
# porque ambos fornecem os wrappers <arch>-w64-mingw32-clang(++).
select_toolchain() {
  local target="$1" p; p="$(triple_prefix "$target")"
  CXX="$TOOL_DIR/${p}-w64-mingw32-clang++"; CC="$TOOL_DIR/${p}-w64-mingw32-clang"
  [[ -x "$CC" ]] || CC="$CXX"
  RC=""
  for c in "$TOOL_DIR/${p}-w64-mingw32-windres" "$TOOL_DIR/llvm-windres" "$TOOL_DIR/llvm-rc" "$(command -v "${p}-w64-mingw32-windres" || true)" "$(command -v llvm-windres || true)" "$(command -v llvm-rc || true)"; do
    if [[ -n "$c" && -x "$c" ]]; then RC="$c"; break; fi
  done
  [[ -x "$CXX" ]] || fail "Compilador ausente para $target: $CXX"
  [[ -n "$RC" ]]  || fail "Nenhum compilador de recursos (windres/llvm-rc) encontrado."
  export CC CXX RC
}

# Compila os utilitários de host (rodam no Termux/Linux, não no Windows).
build_host_tools() {
  mkdir -p "$TMP_DIR/host"
  local hcxx="${HOST_CXX:-}"
  [[ -n "$hcxx" ]] || hcxx="$(command -v c++ || command -v clang++ || true)"
  [[ -n "$hcxx" ]] || fail "Compilador C++ do host ausente (pkg install clang)."
  local t
  for t in app_generator archive_builder installer_generator; do
    "$hcxx" -std=c++20 -O2 "$ROOT/src/tools/$t.cpp" -o "$TMP_DIR/host/$t" || fail "Falha ao compilar utilitário de host: $t"
  done
  ok "Utilitários de host compilados"
}
