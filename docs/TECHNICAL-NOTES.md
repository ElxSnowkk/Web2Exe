# Web2Exe technical notes

## WebView2

The generated Win32 application loads `WebView2Loader.dll` explicitly and resolves the WebView2 creation/version exports at runtime. This avoids an MSVC import-library dependency and keeps the application compatible with LLVM-MinGW. COM is initialized as an STA before WebView2 creation.

The Evergreen WebView2 Runtime remains a Windows prerequisite; `WebView2Loader.dll` is shipped per target architecture.

## Cross compilation

LLVM-MinGW is used as the Linux-side cross compiler for i686, x86_64 and aarch64 Windows targets. UCRT is the default CRT. The generated application dynamically loads WebView2Loader and packages non-system MinGW runtime DLLs discovered from PE imports.

## Installer

The universal installer is an x86 PE. It embeds a W2EA archive (as an RCDATA resource `W2E_PAYLOAD`) containing x86/x64/ARM64 application payloads, detects native Windows architecture with `IsWow64Process2` and a `GetNativeSystemInfo` fallback, extracts only the matching payload, creates per-user Start Menu/Desktop shortcuts, registers HKCU uninstall metadata, and copies itself as `uninstall.exe`. The default installation therefore does not require administrative rights.

## Termux

PRoot-Distro/CHROOT integration validates the Debian container with a real `/bin/true` command and uses `--bind` to expose the Web2Exe project and cache. Options are checked against `login --help` before use instead of assuming a particular fork/version.

## Security

`build.prop` is parsed as key/value data and never sourced. Installer archive extraction rejects absolute paths and traversal components. Downloads use HTTPS, temporary files and atomic rename.

## Execução de scripts

O CLI nunca executa `*.sh` diretamente: resolve o `bash` (`$BASH` só se existir, depois `$PREFIX/bin/bash`, depois PATH) e executa `bash script.sh`. Falhas de `execv` são devolvidas ao pai por um pipe `CLOEXEC` e impressas com `strerror`, evitando códigos 127 sem mensagem.
