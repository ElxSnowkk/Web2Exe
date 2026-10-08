# Changelog

## 1.2.1
**Corrige o build do modo Wine (msvcrt) no Termux/Linux**
- `404` em `libtinfo5_6.3-2ubuntu0.3_amd64.deb`: versões antigas somem do pool do Ubuntu, então as URLs fixas quebravam. Novo `ubuntu_deb` lê o `Packages.gz` (jammy, `-updates`, `-security`), escolhe a versão mais nova existente e tenta os espelhos `archive`/`security`. `libtinfo5` ficou opcional (aviso, não erro).
- Falhas dentro de `prepare_termux_msvcrt_toolchain`/`prepare_tools` usavam `fail` (= `exit`) mesmo chamadas com `|| true`; agora devolvem 1 com aviso, e os fallbacks realmente rodam.
- `build.sh` testa o toolchain msvcrt **antes** de compilar; com `WINE_COMPAT=1` e sem toolchain, aborta na hora (antes só falhava no fim, depois de x86/x64/arm64).
- Wrappers QEMU: `clang++` agora usa `--driver-mode=g++` (sem isso o link com libc++ falhava); `argv[0]` preservado para binários multi-call (`ld.lld`, `llvm-ar`, `llvm-windres`); `-B` para o clang achar o `ld.lld` embrulhado; `clang` real resolvido por `readlink -f`.
- Symlinks absolutos do sysroot (`/lib64/ld-linux-x86-64.so.2`) viram relativos; sem isso o QEMU `-L` não achava o loader.
- Cache do LLVM-MinGW msvcrt não reaproveita mais a pasta do UCRT (Linux comum); tarball tenta várias tags de Ubuntu (24.04/22.04/20.04) e tarball corrompido é removido do cache.

## 1.2.0
**Instalador único com modo Wine e assistente gráfico**
- Corrige o erro `api-ms-win-crt-runtime-l1-1-0.dll._initialize_wide_environment ... unimplemented` em Wine antigo (Boxedwine/ExeBrowser, Wine 1.7): o instalador (x86) passa a ser ligado à `msvcrt.dll`, que existe no Windows e em qualquer Wine.
- O mesmo instalador carrega uma variante `wine/` do app (x86, msvcrt). Ao detectar Wine (`ntdll!wine_get_version`, ou `--wine`), ele instala **somente** essa variante; no Windows instala x86/x64/arm64 como antes.
- A variante Wine não usa WebView2: abre a URL no navegador do host ou mostra o endereço.
- `WINE_COMPAT=auto|1|0` no build.prop (padrão `auto`: inclui a variante se houver toolchain msvcrt; `1` exige; `0` desativa). `web2exe --wine` = `1`.
- `select_wine_crt` valida o toolchain por teste (compila e confere as importações do PE) e tenta, em ordem: toolchain atual, `-mcrtdll=msvcrt`, `WEB2EXE_MSVCRT_TOOL_DIR`, e (só Linux comum) o LLVM-MinGW msvcrt baixado. Instalador e variante Wine são verificados no final: o build falha se sobrar `api-ms-win-crt-*`/`ucrtbase.dll`.
- **Instalador com telas**: boas-vindas (nome, versão, pasta de destino, aviso de Wine), progresso com barra e arquivo atual, e conclusão com opção "Abrir o aplicativo agora". `/S` continua silencioso.

## 1.1.1
- `src/app/compat/EventToken.h` redireciona para o `eventtoken.h` (minúsculo) do mingw-w64; WebView2.h pede o nome do Windows SDK.

## 1.1.0
**CLI**
- Corrigido o `EXIT 127` mudo: `run()` agora resolve o `bash` de forma segura (ignora `$BASH` inválido, usa `$PREFIX/bin/bash`), verifica se o script existe e reporta qualquer falha de `exec` com `strerror`.
- Launcher instalado faz `unset BASH BASH_ENV ENV` antes de executar.
- `web2exe build` no Termux agora usa o modo nativo (antes caía no toolchain glibc, que não roda no Bionic).
- Parser de propriedades unificado (havia duas cópias), BOM UTF‑8 aceito, `~` expandido, `build.prop` só é reescrito se mudou (escrita atômica).
- Novos: `--check`, `doctor` completo (ferramentas, recursos, build.prop), erro para opções desconhecidas, validação de `APP_VERSION`.

**Scripts**
- `make-installer.sh` usava a pasta de dados (`$ROOT`) em vez do projeto para `dist/` e temporários.
- Instalador no Termux usava o clang do host com `--target` Windows; agora usa os wrappers `*-w64-mingw32-clang++`.
- Detecção do toolchain por binários no PATH (não por nomes de pacote); nomes de arquivo ASCII corretos (`Imobiliária` → `Imobiliaria`).
- Utilitários de host compilados uma vez; `-static` elimina DLLs do MinGW; DLLs de sistema desconhecidas viram aviso, não erro.
- Novo `scripts/diagnose.sh` (captura stderr e salva log).

**Windows**
- `installer_generator` trocava ID/versão/pasta e nunca substituía `__WEB2EXE_EXE_NAME__`; `payload_begin()/payload_size()` não eram definidos (não linkava). Payload agora é recurso RCDATA (antes: array C++ de dezenas de MB).
- Desinstalador funcional (cópia em %TEMP%, remoção de arquivos/atalhos/registro/dados do WebView2).
- App: ícone da janela, instância única, pasta de dados em `%LOCALAPPDATA%`, aviso com link se faltar o Runtime, foco correto.
- Manifesto: GUIDs `supportedOS` corrigidos, UTF‑8 e long paths. `.rc` com `code_page(65001)` (acentos) e versão numérica real.
- Toolchains CMake não sobrescrevem mais o compilador passado via `-D`; `enable_language(RC)`; `-luuid`.
