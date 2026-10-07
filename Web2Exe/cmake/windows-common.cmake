# Incluído pelos toolchains windows-<arch>.cmake. Define WEB2EXE_TRIPLE_PREFIX antes de incluir.
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_VERSION 10.0)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
# Os scripts passam os compiladores via -D (wrappers <arch>-w64-mingw32-clang++). Só definimos padrão se faltarem.
if(NOT CMAKE_C_COMPILER)
  set(CMAKE_C_COMPILER ${WEB2EXE_TRIPLE_PREFIX}-w64-mingw32-clang)
endif()
if(NOT CMAKE_CXX_COMPILER)
  set(CMAKE_CXX_COMPILER ${WEB2EXE_TRIPLE_PREFIX}-w64-mingw32-clang++)
endif()
if(NOT CMAKE_RC_COMPILER)
  set(CMAKE_RC_COMPILER ${WEB2EXE_TRIPLE_PREFIX}-w64-mingw32-windres)
endif()
# Linkagem estática: sem dependência de DLLs do MinGW (libc++/libunwind) no Windows.
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld -static -Wl,--gc-sections")
set(CMAKE_CXX_FLAGS_RELEASE_INIT "-O2 -DNDEBUG")
