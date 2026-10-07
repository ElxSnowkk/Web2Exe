Web2Exe

Web2Exe is a universal Windows application builder that converts websites into native C++ WebView2 applications.

It automatically detects the build environment, supports Termux and Linux, generates Windows x86, x64 and ARM64 builds, includes the required runtime DLLs, and creates a universal Windows installer.

Features

- Native C++ and WebView2 applications
- build.prop based configuration
- PNG logo and ICO support
- Automatic Termux detection
- CHROOT and PRoot build modes
- Native Linux build mode
- Automatic host architecture detection
- Windows x86, x64 and ARM64 builds
- Automatic runtime DLL collection
- Universal Windows installer
- Multilingual terminal interface
- --help and --version commands

Quick Start

Termux

web2exe --termux --proot

or:

web2exe --termux --chroot

Linux

web2exe --linux

Help

web2exe --help

Version

web2exe --version

Configuration

Project settings are stored in build.prop, including:

APP_NAME
APP_ID
APP_URL
APP_LOGO
APP_ICON
INSTALL_DIR

Output

Web2Exe generates:

Windows x86
Windows x64
Windows ARM64

All required files are packaged into a single universal Windows installer. The installer automatically detects the target Windows architecture and installs the appropriate build.

License

MIT License.