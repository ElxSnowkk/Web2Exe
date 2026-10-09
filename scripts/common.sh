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
  # auto (padrão) = o instalador inclui a variante Wine se o toolchain conseguir gerá-la; 1 = obrigatório; 0 = não incluir.
  WINE_COMPAT="${WEB2EXE_WINE:-${PROP[WINE_COMPAT]:-auto}}"
  case "${WINE_COMPAT,,}" in 1|true|yes|on|sim) WINE_COMPAT=1;; 0|false|no|off|nao|não) WINE_COMPAT=0;; *) WINE_COMPAT=auto;; esac
  # Emulador x86_64 do modo Wine no Termux: auto (Box64 se existir, senão QEMU) | box64 | qemu. A variável de ambiente vence o build.prop.
  WEB2EXE_EMU="${WEB2EXE_EMU:-${PROP[WINE_EMU]:-auto}}"
  case "${WEB2EXE_EMU,,}" in auto|box64|qemu) WEB2EXE_EMU="${WEB2EXE_EMU,,}";; *) fail "WINE_EMU deve ser auto, box64 ou qemu (recebi: $WEB2EXE_EMU)";; esac
  export WEB2EXE_EMU
  [[ "$APP_LOGO" == "~/"* ]] && APP_LOGO="$HOME/${APP_LOGO#\~/}"
  [[ "$APP_ICON" == "~/"* ]] && APP_ICON="$HOME/${APP_ICON#\~/}"
  if [[ -n "$APP_LOGO" && "$APP_LOGO" != /* ]]; then APP_LOGO="$PROJECT_ROOT/$APP_LOGO"; fi
  if [[ -n "$APP_ICON" && "$APP_ICON" != /* ]]; then APP_ICON="$PROJECT_ROOT/$APP_ICON"; fi
  APP_NAME_SAFE="$(ascii_slug "$APP_NAME")"; APP_ID_SAFE="$(ascii_slug "$APP_ID")"
  [[ -n "$APP_NAME_SAFE" ]] || APP_NAME_SAFE="$APP_ID_SAFE"
  export APP_NAME APP_ID APP_VERSION APP_URL APP_LOGO APP_ICON INSTALL_DIR APP_NAME_SAFE APP_ID_SAFE WINE_COMPAT
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
# try_fetch: devolve 1 em caso de falha (NÃO encerra o script; permite tentar outra URL/espelho).
# fetch:     encerra o script com mensagem de erro se falhar.
try_fetch() {
  local url="$1" out="$2" tmp="${2}.part"
  mkdir -p "$(dirname "$out")"; rm -f "$tmp"
  command -v curl >/dev/null || { warn "curl é necessário para downloads (pkg install curl)"; return 1; }
  log "Baixando $url"
  if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 --output "$tmp" "$url"; then
    rm -f "$tmp"; return 1
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; warn "Download vazio: $url"; return 1; }
  mv -f "$tmp" "$out"
}
fetch() {
  try_fetch "$1" "$2" || fail "Falha no download: $1 (verifique a internet e a versão em scripts/common.sh)"
}

# Baixa o tarball do LLVM-MinGW tentando várias versões de Ubuntu do release (o nome do asset varia).
# fetch_llvm_mingw <crt> <arch> <pasta> <os-tag>...   -> define LLVM_TAR
fetch_llvm_mingw() {
  local crt="$1" arch="$2" dir="$3" os name; shift 3
  LLVM_TAR=""
  for os in "$@"; do
    name="llvm-mingw-${LLVM_VERSION}-${crt}-ubuntu-${os}-${arch}.tar.xz"
    if [[ -s "$dir/$name" ]] || try_fetch "$LLVM_BASE/$name" "$dir/$name"; then LLVM_TAR="$dir/$name"; return 0; fi
  done
  return 1
}

# Baixa um .deb do Ubuntu SEM fixar versão: lê o índice Packages.gz (jammy, -updates, -security) e
# usa o arquivo mais novo que existir. Versões antigas somem do pool (foi o 404 do libtinfo5).
# ubuntu_deb <pacote> <pasta>   -> define DEB_FILE
UBUNTU_SUITE="${WEB2EXE_UBUNTU_SUITE:-jammy}"
UBUNTU_MIRRORS=(https://archive.ubuntu.com/ubuntu https://security.ubuntu.com/ubuntu)
ubuntu_deb() {
  local pkg="$1" dir="$2" idxdir="$2/index" suite mirror idx cands="" ver fn f
  mkdir -p "$idxdir"; DEB_FILE=""
  for f in "$dir/${pkg}_"*_amd64.deb; do   # já baixado antes?
    if [[ -s "$f" ]]; then DEB_FILE="$f"; return 0; fi
  done
  find "$idxdir" -name 'Packages-*.gz' -mmin +1440 -delete 2>/dev/null || true
  for suite in "$UBUNTU_SUITE" "$UBUNTU_SUITE-updates" "$UBUNTU_SUITE-security"; do
    idx="$idxdir/Packages-$suite.gz"
    if [[ ! -s "$idx" ]]; then
      for mirror in "${UBUNTU_MIRRORS[@]}"; do
        try_fetch "$mirror/dists/$suite/main/binary-amd64/Packages.gz" "$idx" && break
      done
    fi
    [[ -s "$idx" ]] || continue
    cands+="$(gzip -dc "$idx" 2>/dev/null | awk -v p="$pkg" 'BEGIN{RS="";FS="\n"}
      { n="";v="";fl="";
        for(i=1;i<=NF;i++){ if($i ~ /^Package: /) n=substr($i,10); else if($i ~ /^Version: /) v=substr($i,10); else if($i ~ /^Filename: /) fl=substr($i,11) }
        if(n==p && fl!="") print v "\t" fl }')"$'\n'
  done
  while IFS=$'\t' read -r ver fn; do   # do mais novo para o mais antigo
    [[ -n "$fn" ]] || continue
    for mirror in "${UBUNTU_MIRRORS[@]}"; do
      if try_fetch "$mirror/$fn" "$dir/$(basename "$fn")"; then DEB_FILE="$dir/$(basename "$fn")"; return 0; fi
    done
  done < <(printf '%s' "$cands" | sed '/^$/d' | sort -t$'\t' -k1,1Vr)
  return 1
}

# --------------------------------------------------------------- toolchain ----
# Prefixo de triple por alvo.
triple_prefix() {
  case "$1" in
    x86|wine|installer) echo i686;; x64) echo x86_64;; arm64) echo aarch64;;
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
# PREPARE_SOFT=1 -> devolve 1 em vez de encerrar o script quando falhar (usado nos fallbacks).
prepare_tools() {
  local arch; arch="$(uname -m)"
  case "$arch" in x86_64) arch=x86_64;; aarch64|arm64) arch=aarch64;; *) fail "Host sem LLVM-MinGW pré-compilado: $arch";; esac
  local sfx=""; [[ "$LLVM_CRT" == ucrt ]] || sfx="-$LLVM_CRT"   # msvcrt e ucrt NÃO podem dividir a mesma pasta
  local base="$CACHE/llvm-mingw" dir="$CACHE/llvm-mingw/${LLVM_VERSION}${sfx}-${arch}"
  mkdir -p "$base"
  if [[ ! -x "$dir/bin/clang" ]]; then
    if ! command -v xz >/dev/null; then
      [[ "${PREPARE_SOFT:-}" == 1 ]] && { warn "xz ausente (apt install xz-utils)"; return 1; }
      fail "xz é necessário (apt install xz-utils)"
    fi
    if ! fetch_llvm_mingw "$LLVM_CRT" "$arch" "$base" 24.04 22.04 20.04; then
      [[ "${PREPARE_SOFT:-}" == 1 ]] && { warn "LLVM-MinGW $LLVM_CRT $LLVM_VERSION indisponível em $LLVM_BASE"; return 1; }
      fail "Falha no download do LLVM-MinGW ($LLVM_CRT) em $LLVM_BASE (verifique a internet e WEB2EXE_LLVM_VERSION)"
    fi
    rm -rf "$dir"; mkdir -p "$dir"
    if ! tar -xJf "$LLVM_TAR" -C "$dir" --strip-components=1 || [[ ! -x "$dir/bin/clang" ]]; then
      rm -rf "$dir" "$LLVM_TAR"
      [[ "${PREPARE_SOFT:-}" == 1 ]] && { warn "Tarball do LLVM-MinGW inválido; removido"; return 1; }
      fail "Tarball do LLVM-MinGW inválido; removido do cache. Rode de novo."
    fi
  fi
  LLVM_ROOT="$dir"; TOOL_DIR="$dir/bin"; export LLVM_ROOT TOOL_DIR
  ok "LLVM-MinGW $LLVM_VERSION $LLVM_CRT ($arch)"
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
  WINE_FLAGS=()
  # Só a variante "wine" e o instalador (que também roda em Wine) usam msvcrt; x86/x64/arm64 seguem em UCRT.
  if [[ "${WINE_COMPAT:-0}" == 1 && ( "$target" == wine || "$target" == installer ) ]]; then select_wine_crt "$target"; fi
  export CC CXX RC
}


# ------------------------------------------------------- modo Wine (msvcrt) ----
# Wine antigo (ex.: Boxedwine/ExeBrowser, Wine 1.7) não tem a UCRT (api-ms-win-crt-*.dll).
# No modo Wine, o instalador e a variante "wine" do app (x86) são ligados à msvcrt.dll, que todo Wine possui;
# os apps x86/x64/arm64 para Windows de verdade continuam em UCRT.
UCRT_IMPORT_RE='(api-ms-win-crt-|ucrtbase\.dll)'

# Imprime as DLLs importadas por um PE.
pe_imports() {
  local od; od="$(tool_path llvm-objdump)"
  [[ -n "$od" ]] || fail "llvm-objdump ausente (pkg install llvm) — necessário para validar o modo Wine"
  "$od" -p "$1" 2>/dev/null | awk '/DLL Name:/{print $3}' | sort -u
}
tool_path() {
  local t="$1"
  if [[ -n "${TOOL_DIR:-}" && -x "$TOOL_DIR/$t" ]]; then echo "$TOOL_DIR/$t"; return; fi
  command -v "$t" || true
}

# O PE depende da UCRT? (0 = sim, 1 = não)
pe_uses_ucrt() { local imp; imp="$(pe_imports "$1")"; grep -Eiq "$UCRT_IMPORT_RE" <<<"$imp"; }
need_objdump() { [[ -n "$(tool_path llvm-objdump)" ]] || fail "llvm-objdump ausente (pkg install llvm) — necessário para validar o modo Wine"; }

# Compila um programa mínimo (wWinMain, std::wstring, <filesystem>) e vê se ele evita a UCRT.
# probe_crt <compilador> [flags...]
probe_crt() {
  local cxx="$1"; shift
  local d="$TMP_DIR/crtprobe"; mkdir -p "$d"
  cat > "$d/p.cpp" <<'CPPEOF'
#include <windows.h>
#include <filesystem>
#include <string>
int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR a, int) { std::wstring s = a ? a : L""; std::error_code e; return (int)(s.size() + std::filesystem::exists(L"C:\\", e)); }
CPPEOF
  rm -f "$d/p.exe" "$d/p.o"
  # Compila e liga em DOIS comandos. Compilar+ligar num só faz o clang abrir o cc1 como processo separado
  # (executável x86_64); sob QEMU isso falha com "unable to execute command: No such file or directory".
  # Só compilar (-c) roda o cc1 dentro do próprio processo.
  local pre=()
  if [[ -n "${WEB2EXE_QEMU_BIN:-}" && "$cxx" == "$TOOL_DIR/"* ]]; then pre=(env "PATH=$WEB2EXE_QEMU_BIN:$PATH"); fi
  if ! "${pre[@]+"${pre[@]}"}" "$cxx" "$@" -std=c++20 -O1 -DUNICODE -D_UNICODE -c "$d/p.cpp" -o "$d/p.o" >"$d/log.txt" 2>&1; then
    # Diagnóstico: o mesmo comando com -v mostra o caminho/linha do cc1 que o clang tentou executar.
    { printf '\n===== repetindo com -v =====\n'; "${pre[@]+"${pre[@]}"}" "$cxx" "$@" -v -std=c++20 -O1 -DUNICODE -D_UNICODE -c "$d/p.cpp" -o "$d/p.o" 2>&1 || true; } >>"$d/log.txt"
    return 2
  fi
  "${pre[@]+"${pre[@]}"}" "$cxx" "$@" -static -fuse-ld=lld -municode -mwindows "$d/p.o" -o "$d/p.exe" >>"$d/log.txt" 2>&1 || return 2
  [[ -f "$d/p.exe" ]] || return 2
  pe_uses_ucrt "$d/p.exe" && return 1
  return 0
}

# Torna relativos os symlinks absolutos do sysroot. Sem isso o QEMU (-L) não acha
# /lib64/ld-linux-x86-64.so.2, que no .deb aponta para /lib/x86_64-linux-gnu/... (caminho do host).
fix_sysroot_symlinks() {
  local root="$1" l t rel
  while IFS= read -r -d '' l; do
    t="$(readlink "$l")"; [[ "$t" == /* ]] || continue
    rel="$(realpath -m --relative-to="$(dirname "$l")" "$root$t")" || continue
    ln -sfn "$rel" "$l"
  done < <(find "$root" -type l -print0)
}

# Procura o Box64 no Termux. No Termux ele roda via glibc: pacote "box64-glibc" + "glibc-runner" (comando grun).
#   WEB2EXE_EMU=auto (padrão: Box64 se existir, senão QEMU) | box64 | qemu
# Define BOX_RUN (array com o comando que executa o box64). Devolve 1 se não houver Box64 utilizável.
BOX_RUN=()
detect_box64() {
  local b g=""
  BOX_RUN=()
  b="$(command -v box64 2>/dev/null || true)"
  [[ -n "$b" ]] || { [[ -n "${PREFIX:-}" && -x "$PREFIX/glibc/bin/box64" ]] && b="$PREFIX/glibc/bin/box64"; }
  [[ -n "$b" ]] || return 1
  if env -u LD_PRELOAD "$b" --version >/dev/null 2>&1; then BOX_RUN=("$b"); return 0; fi
  g="$(command -v grun 2>/dev/null || true)"
  if [[ -n "$g" ]] && env -u LD_PRELOAD "$g" "$b" --version >/dev/null 2>&1; then BOX_RUN=("$g" "$b"); return 0; fi
  return 1
}

# Instala o LLVM-MinGW msvcrt x86_64 para Termux ARM64 sem PRoot/rootfs completo.
# A cadeia fica: Termux ARM64 -> QEMU x86_64 -> glibc mínimo -> LLVM-MinGW x86_64.
# Em caso de falha devolve 1 (com aviso) para o chamador poder tentar outro caminho.
prepare_termux_msvcrt_toolchain() {
  [[ -n "${PREFIX:-}" && -d "$PREFIX" ]] || { warn "PREFIX do Termux não está disponível."; return 1; }
  local emu="${WEB2EXE_EMU:-auto}" qemu="" box_libpath=""
  if [[ "$emu" != qemu ]] && detect_box64; then
    emu=box64
  elif [[ "$emu" == box64 ]]; then
    warn "WEB2EXE_EMU=box64, mas o Box64 não está utilizável. Instale: pacman -S box64-glibc glibc-runner (veja o README)."; return 1
  else
    emu=qemu
  fi
  if [[ "$emu" == qemu ]]; then
    qemu="$(command -v qemu-x86_64 || true)"
    if [[ -z "$qemu" ]]; then
      command -v pkg >/dev/null 2>&1 || { warn "pkg ausente; não foi possível instalar qemu-user-x86-64."; return 1; }
      log "Instalando suporte QEMU x86_64..."
      pkg install -y qemu-user-x86-64 dpkg file || { warn "Falha ao instalar qemu-user-x86-64/dpkg/file."; return 1; }
      qemu="$(command -v qemu-x86_64 || true)"
    fi
    [[ -n "$qemu" ]] || { warn "qemu-x86_64 não foi encontrado após a instalação."; return 1; }
  fi
  log "Emulador x86_64: $emu"
  local t
  for t in dpkg-deb file xz gzip realpath; do
    command -v "$t" >/dev/null 2>&1 || { warn "'$t' ausente. Instale: pkg install dpkg file xz-utils gzip coreutils"; return 1; }
  done

  local base="$CACHE/llvm-mingw-msvcrt"
  local sysroot="$base/sysroot" debs="$base/debs" qbin="$base/qemu-bin" boxbin="$base/box-bin"
  box_libpath="$sysroot/lib/x86_64-linux-gnu:$sysroot/usr/lib/x86_64-linux-gnu"
  mkdir -p "$base" "$debs"

  # Toolchain: o tarball msvcrt é compilado em Ubuntu 22.04/20.04 (glibc 2.35/2.31 — compatível com o sysroot jammy).
  local toolroot="" d
  for d in "$base"/llvm-mingw-"${LLVM_VERSION}"-msvcrt-ubuntu-*-x86_64; do
    [[ -d "$d/bin" ]] && { toolroot="$d"; break; }
  done
  if [[ -z "$toolroot" ]]; then
    fetch_llvm_mingw msvcrt x86_64 "$base" 22.04 20.04 || { warn "Não achei o LLVM-MinGW msvcrt $LLVM_VERSION em $LLVM_BASE (veja WEB2EXE_LLVM_VERSION)"; return 1; }
    toolroot="${LLVM_TAR%.tar.xz}"
    rm -rf "$toolroot"; mkdir -p "$toolroot"
    tar -xJf "$LLVM_TAR" -C "$toolroot" --strip-components=1 || { rm -rf "$toolroot" "$LLVM_TAR"; warn "Tarball msvcrt inválido; removido do cache."; return 1; }
  fi

  # Runtime glibc mínimo, sempre na versão que existir hoje no Ubuntu (sem fixar número de versão).
  local p debfiles=()
  for p in libc6 libstdc++6 libgcc-s1 zlib1g libtinfo5; do
    if ubuntu_deb "$p" "$debs"; then
      debfiles+=("$DEB_FILE")
    elif [[ "$p" == libtinfo5 ]]; then
      warn "libtinfo5 indisponível; seguindo sem ele (só é preciso se o clang reclamar de libtinfo.so.5)."
    else
      warn "Não consegui baixar '$p' do Ubuntu $UBUNTU_SUITE (archive.ubuntu.com / security.ubuntu.com)."; return 1
    fi
  done

  if [[ ! -e "$sysroot/.w2e-ok" ]]; then
    rm -rf "$sysroot"; mkdir -p "$sysroot"
    local f
    for f in "${debfiles[@]}"; do
      dpkg-deb -x "$f" "$sysroot" || { warn "Falha ao extrair runtime mínimo: $f"; rm -f "$f"; return 1; }
    done
    fix_sysroot_symlinks "$sysroot"
    [[ -e "$sysroot/lib64/ld-linux-x86-64.so.2" ]] || { warn "Sysroot sem ld-linux-x86-64.so.2 (extração do libc6 falhou)."; return 1; }
    mkdir -p "$sysroot/etc"
    printf '%s\n' 'nameserver 1.1.1.1' 'nameserver 8.8.8.8' > "$sysroot/etc/resolv.conf"
    printf '%s\n' 'hosts: files dns' 'passwd: files' 'group: files' > "$sysroot/etc/nsswitch.conf"
    printf '%s\n' '127.0.0.1 localhost' > "$sysroot/etc/hosts"
    : > "$sysroot/.w2e-ok"
  fi

  # clang real (ELF x86_64). "clang" costuma ser symlink para clang-NN.
  local clang_real; clang_real="$(readlink -f "$toolroot/bin/clang" 2>/dev/null || true)"
  if [[ -z "$clang_real" ]] || ! file "$clang_real" 2>/dev/null | grep -q 'ELF 64-bit.*x86-64'; then
    clang_real=""
    local f
    while IFS= read -r -d '' f; do
      if [[ "$(basename "$f")" != clang-target-wrapper ]] && file "$f" 2>/dev/null | grep -q 'ELF 64-bit.*x86-64'; then clang_real="$f"; break; fi
    done < <(find "$toolroot/bin" -maxdepth 1 -type f -name 'clang-*' -print0 | sort -zV)
  fi
  [[ -n "$clang_real" ]] || { warn "LLVM-MinGW msvcrt: executável clang x86_64 não encontrado."; return 1; }
  local clang_resource
  clang_resource="$(find "$toolroot/lib/clang" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -n1)"
  [[ -d "$clang_resource" ]] || { warn "LLVM-MinGW msvcrt: resource-dir não encontrado."; return 1; }

  # write_wrapper <arquivo> <argv0|-> <exe> [args fixos...]: script que roda <exe> sob QEMU.
  # argv0 importa: llvm-ar/llvm-ranlib, ld.lld/lld, llvm-windres/llvm-rc são binários "multi-call".
  write_wrapper() {
    local out="$1" a0="$2" exe="$3" x target; shift 3
    {
      printf '#!%s/bin/bash\n' "$PREFIX"
      if [[ "$emu" == box64 ]]; then
        # Box64: argv[0] = caminho com que o programa é chamado, então usamos um symlink com o nome desejado.
        target="$exe"
        if [[ "$a0" != - ]]; then target="$boxbin/$(basename "$a0")"; ln -sfn "$exe" "$target"; fi
        printf 'export BOX64_LD_LIBRARY_PATH=%q BOX64_LOG=0 BOX64_NOBANNER=1\n' "$box_libpath"
        printf 'exec env -u LD_PRELOAD'
        for x in "${BOX_RUN[@]}"; do printf ' %q' "$x"; done
        printf ' %q' "$target"
      else
        printf 'exec env -u LD_PRELOAD %q -U LD_PRELOAD' "$qemu"
        [[ "$a0" == - ]] || printf ' -0 %q' "$a0"
        printf ' -L %q %q' "$sysroot" "$exe"
      fi
      for x in "$@"; do printf ' %q' "$x"; done
      printf ' "$@"\n'
    } > "$out"
    chmod 755 "$out"
  }

  rm -rf "$qbin" "$boxbin"; mkdir -p "$qbin" "$boxbin"
  local f n real
  while IFS= read -r -d '' f; do
    n="$(basename "$f")"
    real="$(readlink -f "$f" 2>/dev/null || true)"
    if [[ -n "$real" ]] && file "$real" 2>/dev/null | grep -q 'ELF 64-bit.*x86-64'; then
      write_wrapper "$qbin/$n" "$n" "$real"
    fi
  done < <(find "$toolroot/bin" -maxdepth 1 \( -type f -o -type l \) -print0)

  # O clang dispara o cc1 como PROCESSO SEPARADO, executando o caminho dele mesmo (/proc/self/exe = ELF x86_64).
  # Sob QEMU isso falha ("unable to execute command: No such file or directory"), porque o kernel do Android
  # não executa binário x86_64. Solução: o clang passa a se enxergar como um SCRIPT (argv[0] via QEMU -0 +
  # -no-canonical-prefixes) que reexecuta o clang real sob QEMU. O script fica em toolroot/bin para que o
  # diretório de instalação (headers da libc++, lib/clang, *.cfg) continue sendo o do toolchain.
  local spawn="-" nocanon=()
  if [[ "$emu" == qemu ]]; then
    spawn="$toolroot/bin/clang-qemu-spawn"; nocanon=("-no-canonical-prefixes")
    write_wrapper "$spawn" - "$clang_real"
  fi   # (no Box64 o próprio emulador intercepta o exec de binários x86_64, sem wrapper de spawn)

  # clang++ PRECISA de --driver-mode=g++ (senão não liga a libc++ e o link falha).
  local common_flags=(${nocanon[@]+"${nocanon[@]}"} "-resource-dir=$clang_resource" "--sysroot=$toolroot" "--config-system-dir=$toolroot/bin" "-B$qbin")
  local arch
  for arch in i686 x86_64; do
    write_wrapper "$qbin/${arch}-w64-mingw32-clang"   "$spawn" "$clang_real" "--target=${arch}-w64-windows-gnu" "${common_flags[@]}"
    write_wrapper "$qbin/${arch}-w64-mingw32-clang++" "$spawn" "$clang_real" --driver-mode=g++ "--target=${arch}-w64-windows-gnu" "${common_flags[@]}"
  done
  write_wrapper "$qbin/clang"   "$spawn" "$clang_real" "${common_flags[@]}"
  write_wrapper "$qbin/clang++" "$spawn" "$clang_real" --driver-mode=g++ "${common_flags[@]}"

  # llvm-windres/llvm-rc chama o preprocessador "<triple>-clang -E ..." procurando PRIMEIRO na pasta do próprio
  # llvm-rc (toolroot/bin), onde esse nome é um script que executa o clang x86_64 direto (sem QEMU) e falha com
  # "not executable: 64-bit ELF file". Trocamos esses nomes pelos nossos wrappers (que rodam via QEMU).
  local kind
  for arch in i686 x86_64; do
    for kind in clang clang++; do
      rm -f "$toolroot/bin/${arch}-w64-mingw32-${kind}"
      cp -f "$qbin/${arch}-w64-mingw32-${kind}" "$toolroot/bin/${arch}-w64-mingw32-${kind}"
    done
  done
  # windres com prefixo do alvo (o llvm-rc deduz alvo/preprocessador do argv[0]): sem isso o recurso sai x64 no exe x86.
  local rc_real; rc_real="$(readlink -f "$toolroot/bin/llvm-windres" 2>/dev/null || true)"
  if [[ -n "$rc_real" ]] && file "$rc_real" 2>/dev/null | grep -q 'ELF 64-bit.*x86-64'; then
    for arch in i686 x86_64; do
      write_wrapper "$qbin/${arch}-w64-mingw32-windres" "${arch}-w64-mingw32-windres" "$rc_real"
    done
  fi

  # Bibliotecas extras que o clang do release costuma pedir (clang-23: libzstd, libtinfo6...).
  # Instaladas individualmente no sysroot já existente (marcador por pacote).
  sysroot_add_pkg() {
    local pk="$1" f
    [[ -e "$sysroot/.w2e-pkg-$pk" ]] && return 0
    ubuntu_deb "$pk" "$debs" || return 1
    f="$DEB_FILE"
    dpkg-deb -x "$f" "$sysroot" || { rm -f "$f"; return 1; }
    fix_sysroot_symlinks "$sysroot"
    : > "$sysroot/.w2e-pkg-$pk"
  }
  for p in libzstd1 libtinfo6 liblzma5; do
    sysroot_add_pkg "$p" || warn "Não consegui instalar '$p' no sysroot (seguindo; o teste abaixo diz se faz falta)."
  done

  # Teste de sanidade: o clang x86_64 executa mesmo sob QEMU? Se faltar uma biblioteca (.so), descobre o
  # pacote Ubuntu correspondente, instala no sysroot e tenta de novo.
  local v tries=0 so pk
  while ! v="$("$qbin/x86_64-w64-mingw32-clang" --version 2>&1)"; do
    so="$(grep -o 'lib[A-Za-z0-9_+-]*\.so\.[0-9.]*' <<<"$v" | head -n1)"
    case "$so" in
      libzstd.so.1)  pk=libzstd1;;   libtinfo.so.6) pk=libtinfo6;;  libtinfo.so.5) pk=libtinfo5;;
      liblzma.so.5)  pk=liblzma5;;   libz.so.1)     pk=zlib1g;;     libxml2.so.2)  pk=libxml2;;
      libedit.so.2)  pk=libedit2;;   libffi.so.8)   pk=libffi8;;    libbsd.so.0)   pk=libbsd0;;
      libmd.so.0)    pk=libmd0;;     libicuuc.so.70) pk=libicu70;;  libncurses.so.6) pk=libncurses6;;
      libgcc_s.so.1) pk=libgcc-s1;;  libstdc++.so.6) pk=libstdc++6;; *) pk="";;
    esac
    if [[ -z "$pk" || $((++tries)) -gt 8 ]]; then
      warn "clang x86_64 não executa sob QEMU: $v"; return 1
    fi
    log "Biblioteca ausente no sysroot: $so -> pacote $pk"
    rm -f "$sysroot/.w2e-pkg-$pk"
    sysroot_add_pkg "$pk" || { warn "Não consegui instalar '$pk' ($so). Erro original: $v"; return 1; }
  done

  export PATH="$qbin:$toolroot/bin:$PATH"
  export WEB2EXE_QEMU_SYSROOT="$sysroot" WEB2EXE_QEMU_BIN="$qbin"
  TOOL_DIR="$qbin"; LLVM_ROOT="$toolroot"
  export TOOL_DIR LLVM_ROOT
  ok "LLVM-MinGW msvcrt x86_64 + glibc mínimo pronto (scripts r6: emulador=$emu)"
}

# Define WINE_CXX/WINE_CC/WINE_FLAGS para x86|x64 (chamada por select_toolchain).
# Ordem de tentativa: (1) o compilador atual já é msvcrt; (2) -mcrtdll=msvcrt;
# (3) toolchain msvcrt indicado em WEB2EXE_MSVCRT_TOOL_DIR; (4) baixa o LLVM-MinGW msvcrt (só Linux comum).
select_wine_crt() {
  local target="$1" p cand_dir cand_cxx rc=0; p="$(triple_prefix "$target")"
  need_objdump
  WINE_FLAGS=()
  probe_crt "$CXX" && { ok "[$target] toolchain atual já usa msvcrt"; return 0; } || rc=$?
  if probe_crt "$CXX" -mcrtdll=msvcrt; then
    WINE_FLAGS=(-mcrtdll=msvcrt); ok "[$target] msvcrt via -mcrtdll=msvcrt"; return 0
  fi
  for cand_dir in "${WEB2EXE_MSVCRT_TOOL_DIR:-}" "${WINE_TOOL_DIR:-}"; do
    [[ -n "$cand_dir" && -x "$cand_dir/${p}-w64-mingw32-clang++" ]] || continue
    cand_cxx="$cand_dir/${p}-w64-mingw32-clang++"
    if probe_crt "$cand_cxx"; then
      TOOL_DIR="$cand_dir"; CXX="$cand_cxx"; CC="$cand_dir/${p}-w64-mingw32-clang"; export TOOL_DIR CXX CC
      ok "[$target] msvcrt via toolchain $cand_dir"; return 0
    fi
  done
  # Termux ARM64: usa o LLVM-MinGW Linux x86_64 via QEMU user-mode,
  # com um sysroot glibc mínimo. Não extrai uma distro inteira.
  if [[ "${PREFIX:-}" == *com.termux* && -z "${WEB2EXE_WINE_NO_DOWNLOAD:-}" ]]; then
    local saved_tool="$TOOL_DIR" saved_root="${LLVM_ROOT:-}"
    prepare_termux_msvcrt_toolchain || warn "Não foi possível preparar o toolchain msvcrt via QEMU (veja os avisos acima)."
    cand_cxx="$TOOL_DIR/${p}-w64-mingw32-clang++"
    if [[ -x "$cand_cxx" ]] && probe_crt "$cand_cxx"; then
      WINE_TOOL_DIR="$TOOL_DIR"; CXX="${WEB2EXE_QEMU_BIN:-$TOOL_DIR}/${p}-w64-mingw32-clang++"; CC="${WEB2EXE_QEMU_BIN:-$TOOL_DIR}/${p}-w64-mingw32-clang"; export WINE_TOOL_DIR CXX CC
      if   [[ -x "${WEB2EXE_QEMU_BIN:-}/${p}-w64-mingw32-windres" ]]; then RC="$WEB2EXE_QEMU_BIN/${p}-w64-mingw32-windres"; export RC
      elif [[ -x "${WEB2EXE_QEMU_BIN:-}/llvm-windres" ]]; then RC="$WEB2EXE_QEMU_BIN/llvm-windres"; export RC; fi
      ok "[$target] msvcrt via LLVM-MinGW msvcrt + QEMU"
      return 0
    fi
    # Mostra POR QUE o teste falhou (antes só aparecia um código genérico).
    if [[ -x "$cand_cxx" ]]; then
      probe_crt "$cand_cxx" && rc=0 || rc=$?
      if [[ $rc == 1 ]]; then warn "[$target] o toolchain msvcrt gerou binário que ainda importa a UCRT."
      else warn "[$target] a compilação de teste sob QEMU falhou (rc=$rc). Últimas linhas do compilador:"; tail -n 40 "$TMP_DIR/crtprobe/log.txt" >&2 || true; fi
    fi
    TOOL_DIR="$saved_tool"; LLVM_ROOT="$saved_root"; export TOOL_DIR LLVM_ROOT
  fi
  # Linux comum (não Termux): baixa o LLVM-MinGW msvcrt diretamente.
  if [[ "${PREFIX:-}" != *com.termux* && -z "${WEB2EXE_WINE_NO_DOWNLOAD:-}" ]]; then
    local saved_tool="$TOOL_DIR" saved_root="${LLVM_ROOT:-}"
    PREPARE_SOFT=1 LLVM_CRT=msvcrt prepare_tools || warn "Não foi possível obter o LLVM-MinGW msvcrt."
    cand_cxx="$TOOL_DIR/${p}-w64-mingw32-clang++"
    if [[ "$TOOL_DIR" != "$saved_tool" && -x "$cand_cxx" ]] && probe_crt "$cand_cxx"; then
      WINE_TOOL_DIR="$TOOL_DIR"; CXX="$cand_cxx"; CC="$TOOL_DIR/${p}-w64-mingw32-clang"; export WINE_TOOL_DIR CXX CC
      ok "[$target] msvcrt via LLVM-MinGW msvcrt baixado"; return 0
    fi
    TOOL_DIR="$saved_tool"; LLVM_ROOT="$saved_root"; export TOOL_DIR LLVM_ROOT
  fi
  fail "Modo Wine: nenhum toolchain gerou binário sem UCRT para $target (probe rc=$rc; log: $TMP_DIR/crtprobe/log.txt; veja também os avisos [WARN] acima).
       Instale um LLVM-MinGW *msvcrt* e aponte WEB2EXE_MSVCRT_TOOL_DIR para a pasta bin/ dele
       (https://github.com/mstorsjo/llvm-mingw/releases → llvm-mingw-<data>-msvcrt-*)."
}

# Falha se um .exe/.dll do modo Wine ainda depende da UCRT.
verify_wine_pe() {
  local f="$1" label="${2:-$1}" bad imp
  need_objdump
  imp="$(pe_imports "$f")"
  [[ -n "$imp" ]] || fail "Modo Wine: não foi possível ler as importações de $label"
  bad="$(grep -Ei "$UCRT_IMPORT_RE" <<<"$imp" || true)"
  [[ -z "$bad" ]] || fail "Modo Wine: $label ainda importa a UCRT ($(echo $bad | tr '\n' ' ')). O Wine 1.7/Boxedwine não tem essas DLLs."
  ok "Modo Wine: $label sem dependência de UCRT"
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
