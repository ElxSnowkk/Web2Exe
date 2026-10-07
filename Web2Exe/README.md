# Web2Exe

Transforma uma URL em aplicativo Windows nativo (Win32 + Microsoft WebView2), sem Electron nem Chromium embutido.
Compila **no próprio Android (Termux)** ou em Linux, gerando x86, x64 e ARM64 e um instalador universal.

> Versão 1.1.0 — ver [CHANGELOG](CHANGELOG.md).

## Instalação (Termux)

```sh
pkg install cmake clang ninja curl unzip llvm lld llvm-mingw-w64 llvm-mingw-w64-ucrt llvm-mingw-w64-tools
./install.sh
web2exe doctor
```

## Uso

Crie um `build.prop` na pasta do projeto:

```ini
APP_NAME=Imobiliária Terra e Prata
APP_ID=imobiliaria-terraeprata
APP_VERSION=1.0.0
APP_URL=https://terraeprata.site.je
APP_LOGO=/sdcard/Download/emblema.png
APP_ICON=/sdcard/Download/emblema.ico
INSTALL_DIR=Imobiliária Terra e Prata
```

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

## Diagnóstico

```sh
bash scripts/diagnose.sh            # valida ambiente + build.prop, mostra stdout e stderr, salva web2exe-diagnose.log
bash scripts/diagnose.sh --build    # idem, e tenta compilar
```

Nenhuma etapa falha em silêncio: toda falha de execução imprime `[ERR ]` com o motivo.

## Arquitetura

Ver `docs/TECHNICAL-NOTES.md`.
