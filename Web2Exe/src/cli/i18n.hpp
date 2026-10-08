#pragma once
#include <cstdlib>
#include <string>
#include <unordered_map>
inline std::string w2e_lang(){const char*l=std::getenv("LC_ALL");if(!l||!*l)l=std::getenv("LC_MESSAGES");if(!l||!*l)l=std::getenv("LANG");std::string s=l?l:"pt_BR";if(s.rfind("en",0)==0)return "en";if(s.rfind("es",0)==0)return "es";return "pt";}
inline std::string tr(const std::string&k){static const std::unordered_map<std::string,std::unordered_map<std::string,std::string>> m={
{"detected_termux",{{"pt","Ambiente Termux detectado."},{"en","Termux environment detected."},{"es","Entorno Termux detectado."}}},
{"choose_env",{{"pt","Escolha o ambiente de build:"},{"en","Choose the build environment:"},{"es","Elija el entorno de build:"}}},
{"chroot",{{"pt","CHROOT"},{"en","CHROOT"},{"es","CHROOT"}}},{"proot",{{"pt","PRoot"},{"en","PRoot"},{"es","PRoot"}}},
{"config_ok",{{"pt","build.prop validado."},{"en","build.prop validated."},{"es","build.prop validado."}}},
{"doctor",{{"pt","Diagnóstico"},{"en","Diagnostics"},{"es","Diagnóstico"}}},
{"clean_ok",{{"pt","Build, dist e temporários removidos; cache preservado."},{"en","Build, dist and temporary files removed; cache preserved."},{"es","Build, dist y temporales eliminados; caché preservada."}}},
{"system",{{"pt","Sistema"},{"en","System"},{"es","Sistema"}}},
{"host",{{"pt","Host"},{"en","Host"},{"es","Host"}}},
{"cache",{{"pt","Cache"},{"en","Cache"},{"es","Caché"}}},
{"space",{{"pt","Espaço livre"},{"en","Free space"},{"es","Espacio libre"}}}
};auto it=m.find(k);if(it==m.end())return k;auto l=it->second.find(w2e_lang());return l==it->second.end()?it->second.begin()->second:l->second;}
