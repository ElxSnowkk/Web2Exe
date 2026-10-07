#!/usr/bin/env bash
# Diagnóstico completo do Web2Exe. Mostra stdout E stderr de cada etapa e salva em web2exe-diagnose.log.
# Uso (na pasta do projeto, onde está o build.prop):   bash diagnose.sh [--build]
set -uo pipefail
LOG="${PWD}/web2exe-diagnose.log"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
sect() { say ""; say "============================================================"; say " $*"; say "============================================================"; }
step() { # step <rótulo> <comando...>
  local label="$1"; shift
  say "[CMD] $*"
  local out rc t0=$SECONDS
  out="$("$@" 2>&1)"; rc=$?
  printf '%s\n' "$out" | tee -a "$LOG"
  say "[EXIT] $rc  [TIME] $((SECONDS - t0))s"
  if [[ $rc -eq 0 ]]; then say "[ OK ] $label"; PASS=$((PASS+1)); else say "[FAIL] $label"; FAIL=$((FAIL+1)); fi
}
PASS=0; FAIL=0

sect "AMBIENTE"
say "data:      $(date)"; say "projeto:   $PWD"; say "PREFIX:    ${PREFIX:-?}"; say "uname:     $(uname -a)"
say "BASH env:  ${BASH:-<vazio>}  ($( [[ -x "${BASH:-/nonexistent}" ]] && echo executável || echo INVÁLIDO ))"
say "web2exe:   $(command -v web2exe || echo AUSENTE)"
[[ -f build.prop ]] && { say "build.prop:"; sed 's/^/    /' build.prop | tee -a "$LOG"; } || say "build.prop AUSENTE em $PWD"

sect "TESTES"
step "versão"            web2exe --version
step "doctor"            web2exe doctor
step "validação do build.prop" web2exe --check --properties-file build.prop
if [[ "${1:-}" == "--build" ]]; then
  step "build nativo (Termux)" web2exe --termux --native --properties-file build.prop
  say ""; say "Artefatos:"; ls -lh dist 2>/dev/null | tee -a "$LOG" || say "(dist/ não existe)"
fi

sect "RESULTADO"
say "PASS: $PASS   FAIL: $FAIL"
say "Log completo: $LOG"
[[ $FAIL -eq 0 ]] && say "[ OK ] tudo certo" || say "[ERR ] há falhas — envie o log inteiro (web2exe-diagnose.log)."
exit $FAIL
