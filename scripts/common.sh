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
  rm -f "$d/p.exe"
  if [[ -n "${WEB2EXE_QEMU_BIN:-}" && "$cxx" == "$TOOL_DIR/"* ]]; then
    PATH="$WEB2EXE_QEMU_BIN:$PATH" "$cxx" "$@" -std=c++20 -O1 -static -fuse-ld=lld -DUNICODE -D_UNICODE -municode -mwindows "$d/p.cpp" -o "$d/p.exe" >"$d/log.txt" 2>&1 || return 2
  else
    "$cxx" "$@" -std=c++20 -O1 -static -fuse-ld=lld -DUNICODE -D_UNICODE -municode -mwindows "$d/p.cpp" -o "$d/p.exe" >"$d/log.txt" 2>&1 || return 2
  fi
  [[ -f "$d/p.exe" ]] || return 2
  pe_uses_ucrt "$d/p.exe" && return 1
  return 0
}

# Instala o LLVM-MinGW msvcrt x86_64 para Termux ARM64 sem PRoot/rootfs completo.
# A cadeia fica: Termux ARM64 -> QEMU x86_64 -> glibc mínimo -> LLVM-MinGW x86_64.
prepare_termux_msvcrt_toolchain() {
  [[ -n "${PREFIX:-}" && -d "$PREFIX" ]] || fail "PREFIX do Termux não está disponível."
  local qemu="$(command -v qemu-x86_64 || true)"
  if [[ -z "$qemu" ]]; then
    command -v pkg >/dev/null 2>&1 || fail "pkg ausente; não foi possível instalar qemu-x86-64."
    log "Instalando suporte QEMU x86_64..."
    pkg install -y qemu-user-x86-64 dpkg file || fail "Falha ao instalar qemu-user-x86-64/dpkg/file."
    qemu="$(command -v qemu-x86_64 || true)"
  fi
  [[ -n "$qemu" ]] || fail "qemu-x86_64 não foi encontrado após a instalação."

  local base="$CACHE/llvm-mingw-msvcrt"
  local sysroot="$base/sysroot"
  local toolroot="$base/llvm-mingw-${LLVM_VERSION}-msvcrt-ubuntu-22.04-x86_64"
  local tar="$base/llvm-mingw-${LLVM_VERSION}-msvcrt-ubuntu-22.04-x86_64.tar.xz"
  local libc_deb="$base/libc6_2.35-0ubuntu3.15_amd64.deb"
  local libstdc_deb="$base/libstdc++6_12.3.0-1ubuntu1~22.04.3_amd64.deb"
  local libgcc_deb="$base/libgcc-s1_12.3.0-1ubuntu1~22.04.3_amd64.deb"
  local zlib_deb="$base/zlib1g_1.2.11.dfsg-2ubuntu9.2_amd64.deb"
  local tinfo_deb="$base/libtinfo5_6.3-2ubuntu0.3_amd64.deb"
  local qbin="$base/qemu-bin"
  mkdir -p "$base"

  if [[ ! -d "$toolroot/bin" ]]; then
    fetch "$LLVM_BASE/llvm-mingw-${LLVM_VERSION}-msvcrt-ubuntu-22.04-x86_64.tar.xz" "$tar"
    rm -rf "$toolroot"
    mkdir -p "$toolroot"
    tar -xJf "$tar" -C "$toolroot" --strip-components=1
  fi

  local url pkgfile
  declare -a pkgs=(
    "https://archive.ubuntu.com/ubuntu/pool/main/g/glibc/libc6_2.35-0ubuntu3.15_amd64.deb|$libc_deb"
    "https://archive.ubuntu.com/ubuntu/pool/main/g/gcc-12/libstdc++6_12.3.0-1ubuntu1~22.04.3_amd64.deb|$libstdc_deb"
    "https://archive.ubuntu.com/ubuntu/pool/main/g/gcc-12/libgcc-s1_12.3.0-1ubuntu1~22.04.3_amd64.deb|$libgcc_deb"
    "https://archive.ubuntu.com/ubuntu/pool/main/z/zlib/zlib1g_1.2.11.dfsg-2ubuntu9.2_amd64.deb|$zlib_deb"
    "https://archive.ubuntu.com/ubuntu/pool/main/n/ncurses/libtinfo5_6.3-2ubuntu0.3_amd64.deb|$tinfo_deb"
  )
  for pkgfile in "${pkgs[@]}"; do
    url="${pkgfile%%|*}"; pkgfile="${pkgfile#*|}"
    [[ -s "$pkgfile" ]] || fetch "$url" "$pkgfile"
  done

  if [[ ! -e "$sysroot/lib64/ld-linux-x86-64.so.2" ]]; then
    rm -rf "$sysroot"; mkdir -p "$sysroot"
    command -v dpkg-deb >/dev/null 2>&1 || fail "dpkg-deb ausente. Instale: pkg install dpkg."
    for pkgfile in "$libc_deb" "$libstdc_deb" "$libgcc_deb" "$zlib_deb" "$tinfo_deb"; do
      dpkg-deb -x "$pkgfile" "$sysroot" || fail "Falha ao extrair runtime mínimo: $pkgfile"
    done
    mkdir -p "$sysroot/etc"
    printf '%s\n' 'nameserver 1.1.1.1' 'nameserver 8.8.8.8' > "$sysroot/etc/resolv.conf"
    printf '%s\n' 'hosts: files dns' 'passwd: files' 'group: files' > "$sysroot/etc/nsswitch.conf"
    printf '%s\n' '127.0.0.1 localhost' > "$sysroot/etc/hosts"
  fi

  local clang_real=""
  while IFS= read -r -d '' f; do
    if file "$f" 2>/dev/null | grep -q 'ELF 64-bit.*x86-64'; then clang_real="$f"; break; fi
  done < <(find "$toolroot/bin" -maxdepth 1 -type f -name 'clang-*' -print0 | sort -z)
  [[ -n "$clang_real" ]] || fail "LLVM-MinGW msvcrt: executável clang x86_64 não encontrado."
  local clang_resource
  clang_resource="$(find "$toolroot/lib/clang" -mindepth 1 -maxdepth 1 -type d | sort | tail -n1)"
  [[ -d "$clang_resource" ]] || fail "LLVM-MinGW msvcrt: resource-dir não encontrado."

  rm -rf "$qbin"; mkdir -p "$qbin"
  local f n real
  while IFS= read -r -d '' f; do
    n="$(basename "$f")"
    real="$(readlink -f "$f" 2>/dev/null || true)"
    if [[ -n "$real" ]] && file "$real" 2>/dev/null | grep -q 'ELF 64-bit.*x86-64'; then
      cat > "$qbin/$n" <<EOF
#!/usr/bin/env bash
exec env -u LD_PRELOAD "$qemu" -U LD_PRELOAD -L "$sysroot" "$real" "\$@"
EOF
      chmod 755 "$qbin/$n"
    fi
  done < <(find "$toolroot/bin" -maxdepth 1 \( -type f -o -type l \) -print0)

  # Compiler ARM64-side: chama diretamente o clang x86_64 sob QEMU.
  local arch
  for arch in i686 x86_64; do
    for kind in clang clang++; do
      cat > "$qbin/${arch}-w64-mingw32-${kind}" <<EOF
#!/usr/bin/env bash
exec env -u LD_PRELOAD "$qemu" -U LD_PRELOAD -L "$sysroot" "$clang_real" --target=${arch}-w64-windows-gnu --resource-dir="$clang_resource" --sysroot="$toolroot" --config-system-dir="$toolroot/bin" "\$@"
EOF
      chmod 755 "$qbin/${arch}-w64-mingw32-${kind}"
    done
  done
  for kind in clang clang++; do
    cat > "$qbin/$kind" <<EOF
#!/usr/bin/env bash
exec env -u LD_PRELOAD "$qemu" -U LD_PRELOAD -L "$sysroot" "$clang_real" --resource-dir="$clang_resource" --sysroot="$toolroot" --config-system-dir="$toolroot/bin" "\$@"
EOF
    chmod 755 "$qbin/$kind"
  done

  export PATH="$qbin:$toolroot/bin:$PATH"
  export WEB2EXE_QEMU_SYSROOT="$sysroot" WEB2EXE_QEMU_BIN="$qbin"
  TOOL_DIR="$qbin"; LLVM_ROOT="$toolroot"
  export TOOL_DIR LLVM_ROOT
  ok "LLVM-MinGW msvcrt x86_64 + glibc mínimo pronto (sem Ubuntu Base/PRoot)"
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
    prepare_termux_msvcrt_toolchain || true
    cand_cxx="$TOOL_DIR/${p}-w64-mingw32-clang++"
    if [[ -x "$cand_cxx" ]] && probe_crt "$cand_cxx"; then
      WINE_TOOL_DIR="$TOOL_DIR"; CXX="${WEB2EXE_QEMU_BIN:-$TOOL_DIR}/${p}-w64-mingw32-clang++"; CC="${WEB2EXE_QEMU_BIN:-$TOOL_DIR}/${p}-w64-mingw32-clang"; export WINE_TOOL_DIR CXX CC
      if [[ -x "${WEB2EXE_QEMU_BIN:-}/llvm-windres" ]]; then RC="$WEB2EXE_QEMU_BIN/llvm-windres"; export RC; fi
      ok "[$target] msvcrt via LLVM-MinGW msvcrt + QEMU"
      return 0
    fi
    TOOL_DIR="$saved_tool"; LLVM_ROOT="$saved_root"; export TOOL_DIR LLVM_ROOT
  fi
  # Linux comum (não Termux): baixa o LLVM-MinGW msvcrt diretamente.
  if [[ "${PREFIX:-}" != *com.termux* && -z "${WEB2EXE_WINE_NO_DOWNLOAD:-}" ]]; then
    local saved_tool="$TOOL_DIR" saved_root="${LLVM_ROOT:-}"
    LLVM_CRT=msvcrt prepare_tools || true
    cand_cxx="$TOOL_DIR/${p}-w64-mingw32-clang++"
    if [[ "$TOOL_DIR" != "$saved_tool" && -x "$cand_cxx" ]] && probe_crt "$cand_cxx"; then
      WINE_TOOL_DIR="$TOOL_DIR"; CXX="$cand_cxx"; CC="$TOOL_DIR/${p}-w64-mingw32-clang"; export WINE_TOOL_DIR CXX CC
      ok "[$target] msvcrt via LLVM-MinGW msvcrt baixado"; return 0
    fi
    TOOL_DIR="$saved_tool"; LLVM_ROOT="$saved_root"; export TOOL_DIR LLVM_ROOT
  fi
  fail "Modo Wine: nenhum toolchain gerou binário sem UCRT para $target (probe rc=$rc; log: $TMP_DIR/crtprobe/log.txt).
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
