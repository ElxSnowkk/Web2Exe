# Web2Exe

Transforma uma URL em aplicativo Windows nativo (Win32 + Microsoft WebView2), sem Electron nem Chromium embutido.
Compila **no próprio Android (Termux)** ou em Linux, gerando x86, x64 e ARM64 e um instalador universal.

> Versão 1.2.1 — ver [CHANGELOG](CHANGELOG.md).

## Instalação (Termux ou Linux)

Baixe o projeto com o Git e instale:

```sh
pkg install git cmake clang ninja curl unzip llvm lld llvm-mingw-w64 llvm-mingw-w64-ucrt llvm-mingw-w64-tools
git clone https://github.com/ElxSnowkk/Web2Exe.git
cd Web2Exe
bash install.sh
web2exe doctor
```

Para atualizar depois: `cd Web2Exe && git pull && bash install.sh`.
(Em Linux comum, instale `git cmake clang ninja-build curl xz-utils unzip llvm` e use `./linux-build.sh`.)

## Uso

Dentro da pasta do projeto há um `build.prop` genérico. Edite os valores (nome, id, URL, logo e ícone):

```ini
APP_NAME=Meu Aplicativo
APP_ID=meu-aplicativo
APP_VERSION=1.0.0
APP_URL=https://example.com
APP_LOGO=/sdcard/Download/logo.png
APP_ICON=/sdcard/Download/icone.ico
INSTALL_DIR=Meu Aplicativo
WINE_COMPAT=auto
```

Depois execute:

```sh
web2exe --check --properties-file build.prop   # só valida
web2exe build                                  # compila usando ./build.prop (Termux nativo por padrão)
web2exe --termux --native --properties-file build.prop
web2exe --termux --proot  --properties-file build.prop   # dentro de um Debian (proot-distro)
web2exe clean
```

Resultado em `dist/`: `<Nome>-Setup.exe` (instalador universal) e `dist/{x86,x64,arm64}/`.

Observações:
- `APP_ICON` precisa ser um `.ico` de verdade (um PNG renomeado é rejeitado).
- Nomes de arquivo gerados são ASCII (`Imobiliária` → `Imobiliaria`); o nome exibido ao usuário mantém os acentos.
- O instalador instala por usuário em `%LOCALAPPDATA%\<INSTALL_DIR>` (sem administrador), cria atalhos e registra a desinstalação.
- O app exige o *WebView2 Runtime* (já vem no Windows 10/11 atualizado); se faltar, oferece abrir a página de download.

## Modo Wine (instalador único)

O mesmo `<Nome>-Setup.exe` roda em Windows e em Wine antigo (ExeBrowser/Boxedwine), que não tem a UCRT:

- O instalador é ligado à `msvcrt.dll` e carrega uma variante `wine` do app. Ao detectar Wine ele instala só essa variante; no Windows instala x86/x64/arm64 como antes.
- `WINE_COMPAT` no build.prop: `auto` (padrão: inclui a variante se o toolchain permitir, senão avisa e segue sem ela), `1` (obrigatório) ou `0`. `web2exe --wine build` equivale a `1`.
- Precisa de `llvm-objdump` (`pkg install llvm`). Se o seu toolchain for só UCRT, aponte `WEB2EXE_MSVCRT_TOOL_DIR` para o `bin/` de um LLVM-MinGW **msvcrt** (em Linux comum ele é baixado sozinho).
- O build confere o `.exe` final e falha se sobrar dependência de `api-ms-win-crt-*`.
- O app da variante Wine não usa WebView2: abre o site no navegador do host ou mostra o endereço.
- A linha `wine: cannot find ... wineboot.exe` do ExeBrowser vem do overlay mínimo do Wine e é inofensiva.

## Instalador

Assistente com três telas (boas-vindas, progresso, conclusão com "Abrir o aplicativo agora"). `Setup.exe /S` instala em silêncio.

## Diagnóstico

```sh
bash scripts/diagnose.sh            # valida ambiente + build.prop, mostra stdout e stderr, salva web2exe-diagnose.log
bash scripts/diagnose.sh --build    # idem, e tenta compilar
```

Nenhuma etapa falha em silêncio: toda falha de execução imprime `[ERR ]` com o motivo.

## Arquitetura

Ver `docs/TECHNICAL-NOTES.md`.

## Emulador x86_64 no Termux (modo Wine): Box64 ou QEMU

O toolchain msvcrt do modo Wine é x86_64 e precisa de um emulador no Termux ARM64.
`WEB2EXE_EMU=auto` (padrão) usa o **Box64** se estiver instalado e cai para o **QEMU** se não estiver.

Instalar o Box64 (roda via glibc no Termux):

    pkg install glibc-repo        # repositório de pacotes glibc
    pkg install glibc-runner      # comando grun
    pkg install box64-glibc       # se o pkg não achar: pacman -S box64-glibc glibc-runner
    pkg search box64              # confira o nome real do pacote no seu repositório

Forçar um emulador: `WEB2EXE_EMU=box64 web2exe build` ou `WEB2EXE_EMU=qemu web2exe build`.
Sem a variante Wine (`WINE_COMPAT=0`) nenhum emulador é necessário.
