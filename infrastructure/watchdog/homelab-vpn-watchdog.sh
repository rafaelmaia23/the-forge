#!/bin/bash
# =============================================================================
# homelab-vpn-watchdog — mantém a saída dos dispositivos funcionando
#
# A tabela 51820 tem `default dev wg-mull-br`. Se o túnel morre mas a interface
# continua existindo, TODO o tráfego de exit node cai num buraco negro: os
# dispositivos ficam sem internet e o servidor continua perfeitamente saudável,
# então nada acusa. Foi exatamente o que aconteceu em 2026-07-28, quando o
# wg-mull-br.conf perdeu o bloco [Peer] e o reboot releu o arquivo quebrado.
#
# Estratégia em dois estágios:
#   1. túnel morto        -> tenta reiniciar o wg-quick
#   2. continuou morto    -> FAILOVER: aponta o default da 51820 para o gateway
#                            direto. Perde a privacidade do Mullvad, mas os
#                            dispositivos voltam a navegar. Melhor degradado e
#                            avisado do que silenciosamente offline.
#   3. túnel voltou       -> desfaz o failover sozinho.
#
# Config em /etc/homelab-watchdog.env (fora do repo — contém a push URL).
# =============================================================================
set -uo pipefail

# shellcheck disable=SC1091
[ -r /etc/homelab-watchdog.env ] && . /etc/homelab-watchdog.env

WG_IF="${WG_IF:-wg-mull-br}"
WG_UNIT="wg-quick@${WG_IF}.service"
TABLE="${WG_TABLE:-51820}"
TS_SUBNET="${TS_SUBNET:-100.64.0.0/10}"
HANDSHAKE_MAX_AGE="${WG_HANDSHAKE_MAX_AGE:-300}"
FAIL_THRESHOLD="${WG_FAIL_THRESHOLD:-2}"
STATE_FILE=/run/homelab-vpn-watchdog.state
DEGRADED_FLAG=/run/homelab-vpn-watchdog.degraded

log() { logger -t homelab-vpn-watchdog "$*"; }

push() {
    [ -n "${VPN_PUSH_URL:-}" ] || return 0
    curl -fsS -m 10 -o /dev/null "${VPN_PUSH_URL}?status=${1}&msg=${2}" || true
}

# Saúde do túnel: handshake recente E tráfego real passando. O handshake sozinho
# não basta — a interface pode existir sem peer nenhum (o caso de 2026-07-28).
tunnel_healthy() {
    ip link show "${WG_IF}" >/dev/null 2>&1 || return 1

    local hs age
    hs=$(wg show "${WG_IF}" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
    [ -n "${hs:-}" ] && [ "${hs}" -gt 0 ] 2>/dev/null || return 1

    age=$(( $(date +%s) - hs ))
    [ "${age}" -le "${HANDSHAKE_MAX_AGE}" ] || return 1

    curl -fsS -m 8 -o /dev/null --interface "${WG_IF}" https://am.i.mullvad.net/ 2>/dev/null
}

direct_gateway() { ip route show default | awk '/^default/ {print $3; exit}'; }
direct_iface()   { ip route show default | awk '/^default/ {print $5; exit}'; }

enter_failover() {
    local gw dev
    gw=$(direct_gateway); dev=$(direct_iface)
    if [ -z "${gw}" ] || [ -z "${dev}" ]; then
        log "ERRO: nao consegui descobrir o gateway direto — failover abortado"
        return 1
    fi
    ip route replace default via "${gw}" dev "${dev}" table "${TABLE}"
    # O ts-postrouting do Tailscale mascara por mark, mas nao dependemos disso:
    # este e o caminho que nao pode falhar.
    iptables -t nat -C POSTROUTING -s "${TS_SUBNET}" -o "${dev}" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s "${TS_SUBNET}" -o "${dev}" -j MASQUERADE
    touch "${DEGRADED_FLAG}"
    log "FAILOVER ATIVO — saida dos dispositivos via ${dev} (${gw}), SEM Mullvad"
    push down failover-sem-vpn
}

leave_failover() {
    local dev
    dev=$(direct_iface)
    ip route replace default dev "${WG_IF}" table "${TABLE}"
    [ -n "${dev}" ] && iptables -t nat -D POSTROUTING -s "${TS_SUBNET}" -o "${dev}" -j MASQUERADE 2>/dev/null
    rm -f "${DEGRADED_FLAG}"
    log "tunel recuperado — failover desfeito, saida de volta pelo Mullvad"
}

fails=$(cat "${STATE_FILE}" 2>/dev/null || echo 0)

if tunnel_healthy; then
    [ -f "${DEGRADED_FLAG}" ] && leave_failover
    [ "${fails}" -gt 0 ] && log "tunel voltou apos ${fails} falha(s)"
    echo 0 > "${STATE_FILE}"
    push up OK
    exit 0
fi

fails=$((fails + 1))
echo "${fails}" > "${STATE_FILE}"
log "tunel ${WG_IF} sem saude (falha ${fails}/${FAIL_THRESHOLD})"

# Tenta reerguer o túnel SEMPRE — inclusive já em modo degradado, senão o
# failover viraria um estado permanente esperando intervenção manual. Enquanto
# degradado, espaça as tentativas para não reiniciar a unidade a cada minuto.
if [ ! -f "${DEGRADED_FLAG}" ] || [ $(( fails % ${WG_RETRY_EVERY:-5} )) -eq 0 ]; then
    log "tentando reiniciar ${WG_UNIT}"

    # A rota de failover ocupa o mesmo `default` da tabela 51820 que o PostUp do
    # wg-quick instala. Se ela ficar no lugar, o wg-quick aborta com "RTNETLINK
    # answers: File exists" e apaga a interface que acabou de criar — ou seja, o
    # próprio failover impediria o túnel de voltar. O .conf já usa `ip route
    # replace`, mas tirar a rota antes protege também o caso de um .conf novo
    # colado do painel do Mullvad, que vem sem as nossas customizações.
    if [ -f "${DEGRADED_FLAG}" ]; then
        ip route del default table "${TABLE}" 2>/dev/null || true
    fi

    systemctl reset-failed "${WG_UNIT}" 2>/dev/null || true
    systemctl restart "${WG_UNIT}" 2>&1 | logger -t homelab-vpn-watchdog
    sleep 12

    if tunnel_healthy; then
        log "tunel recuperado pelo restart"
        [ -f "${DEGRADED_FLAG}" ] && leave_failover
        echo 0 > "${STATE_FILE}"
        push up recuperado-por-restart
        exit 0
    fi

    # Restart falhou e nós tínhamos acabado de remover a rota de failover —
    # reinstala, senão os dispositivos ficariam sem saída nenhuma até o próximo
    # ciclo do timer.
    if [ -f "${DEGRADED_FLAG}" ]; then
        log "restart falhou — reinstalando a rota de failover"
        enter_failover
    fi
fi

# Restart não resolveu — degrada para saída direta em vez de deixar no vácuo.
if [ "${fails}" -ge "${FAIL_THRESHOLD}" ] && [ ! -f "${DEGRADED_FLAG}" ]; then
    enter_failover
fi
exit 1
