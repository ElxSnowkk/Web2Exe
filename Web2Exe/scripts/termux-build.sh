#!/usr/bin/env bash
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="${WEB2EXE_DATA_ROOT:-$(cd "$SELF/.." && pwd)}"
PROJECT="${WEB2EXE_PROJECT_ROOT:-$PWD}"
mode="${1:-native}"

run_container() {
  local tool="$1" help opts
  help="$("$tool" login --help 2>&1 || true)"
  [[ "$help" == *"--bind"* ]] || { printf '%s\n' "[ERR ] $tool não oferece --bind; o projeto precisa de um caminho compartilhado." >&2; exit 4; }
  mkdir -p "$HOME/.cache/web2exe"
  opts=(login)
  [[ "$help" == *"--shared-home"* ]] && opts+=(--shared-home)
  opts+=(--bind "$DATA:/mnt/web2exe" --bind "$PROJECT:/mnt/web2exe-project" --bind "$HOME/.cache/web2exe:/root/.cache/web2exe")
  # No container o toolchain glibc é baixado (prepare_tools); dentro do Debian isso funciona.
  opts+=(debian -- /bin/bash -lc 'export WEB2EXE_PROJECT_ROOT=/mnt/web2exe-project WEB2EXE_DATA_ROOT=/mnt/web2exe; cd /mnt/web2exe-project; apt-get install -y --no-install-recommends cmake curl xz-utils unzip clang >/dev/null 2>&1 || true; exec bash /mnt/web2exe/scripts/build.sh')
  exec "$tool" "${opts[@]}"
}

case "$mode" in
  native)
    export WEB2EXE_TOOLCHAIN_MODE=termux-native
    exec "${BASH:-bash}" "$SELF/build.sh"
    ;;
  chroot)
    command -v chroot-distro >/dev/null 2>&1 || { printf '%s\n' '[ERR ] chroot-distro não está instalado.' >&2; exit 2; }
    chroot-distro login debian -- /bin/true >/dev/null 2>&1 || { printf '%s\n' '[ERR ] Debian CHROOT não está funcional.' >&2; exit 3; }
    run_container chroot-distro
    ;;
  proot)
    command -v proot-distro >/dev/null 2>&1 || { printf '%s\n' '[ERR ] proot-distro não está instalado. No Termux: pkg install proot-distro' >&2; exit 2; }
    proot-distro login debian -- /bin/true >/dev/null 2>&1 || { printf '%s\n' '[ERR ] Debian PRoot não está funcional. Verifique: proot-distro list' >&2; exit 3; }
    run_container proot-distro
    ;;
  *) printf '%s\n' '[ERR ] Modo Termux inválido. Use native, chroot ou proot.' >&2; exit 2;;
esac
