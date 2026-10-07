# Changelog

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
