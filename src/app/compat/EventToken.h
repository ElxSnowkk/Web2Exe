// Redireciona "EventToken.h" (nome do Windows SDK) para o "eventtoken.h" do mingw-w64.
// O Termux/Linux é case-sensitive, então WebView2.h não encontra o arquivo em minúsculo.
#pragma once
#if defined(__has_include)
#  if __has_include(<eventtoken.h>)
#    include <eventtoken.h>
#    define W2E_HAVE_EVENTTOKEN 1
#  elif __has_include(<winrt/eventtoken.h>)
#    include <winrt/eventtoken.h>
#    define W2E_HAVE_EVENTTOKEN 1
#  endif
#endif
#ifndef W2E_HAVE_EVENTTOKEN
// Último recurso: o mingw-w64 instalado não tem o header.
typedef struct EventRegistrationToken { __int64 value; } EventRegistrationToken;
#endif
