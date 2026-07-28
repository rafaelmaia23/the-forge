#!/bin/bash
# =============================================================================
# homelab-dns-watchdog — garante que o AdGuard esteja RESPONDENDO, não só "up"
#
# Por que testar query real e não `docker ps`:
# em 2026-07-28 00:45 o container adguard estava "running" e saudável para o
# Docker, enquanto todos os upstreams DoH davam timeout — os dispositivos
# ficaram sem internet e nenhum monitor acusou. Container vivo não é DNS vivo.
#
# Config em /etc/homelab-watchdog.env (fora do repo — contém a push URL).
# =============================================================================
set -uo pipefail

# shellcheck disable=SC1091
[ -r /etc/homelab-watchdog.env ] && . /etc/homelab-watchdog.env

ADGUARD_IP="${ADGUARD_IP:-172.18.0.2}"
PROBE_DOMAIN="${DNS_PROBE_DOMAIN:-cloudflare.com}"
STACK_DIR="${DNS_STACK_DIR:-/srv/the-forge/services/dns}"
FAIL_THRESHOLD="${DNS_FAIL_THRESHOLD:-2}"
STATE_FILE=/run/homelab-dns-watchdog.state

log() { logger -t homelab-dns-watchdog "$*"; }

# Heartbeat para o Uptime Kuma (push monitor). Só é enviado quando o DNS
# responde — se o watchdog morrer junto com o host, o Kuma acusa a ausência.
push() {
    [ -n "${DNS_PUSH_URL:-}" ] || return 0
    curl -fsS -m 10 -o /dev/null "${DNS_PUSH_URL}?status=${1}&msg=${2}" || true
}

dns_answers() {
    dig +short +time=3 +tries=1 "@${ADGUARD_IP}" "${PROBE_DOMAIN}" A 2>/dev/null \
        | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

fails=$(cat "${STATE_FILE}" 2>/dev/null || echo 0)

if dns_answers; then
    [ "${fails}" -gt 0 ] && log "DNS voltou a responder apos ${fails} falha(s)"
    echo 0 > "${STATE_FILE}"
    push up OK
    exit 0
fi

fails=$((fails + 1))
echo "${fails}" > "${STATE_FILE}"
log "AdGuard nao respondeu em ${ADGUARD_IP} (falha ${fails}/${FAIL_THRESHOLD})"
push down "sem-resposta-${fails}"

# Uma falha isolada pode ser timeout de rede. Só age no limiar.
[ "${fails}" -lt "${FAIL_THRESHOLD}" ] && exit 1

log "limiar atingido — recriando a stack dns"
if cd "${STACK_DIR}" 2>/dev/null && docker compose up -d 2>&1 | logger -t homelab-dns-watchdog; then
    sleep 10
    if dns_answers; then
        log "stack dns recuperada com sucesso"
        echo 0 > "${STATE_FILE}"
        push up recuperado
        exit 0
    fi
fi

log "ERRO: stack dns nao respondeu apos a tentativa de recuperacao"
exit 1
