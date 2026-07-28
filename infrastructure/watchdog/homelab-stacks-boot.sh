#!/bin/bash
# =============================================================================
# homelab-stacks-boot — rede de segurança de boot
#
# O `restart: unless-stopped` do Docker religa containers, mas desiste depois de
# algumas tentativas com backoff. Se um container falhar ao subir no boot por uma
# condição transitória (dependência ainda não pronta, IP em uso, volume lento),
# ele fica parado até alguém rodar `docker compose up` na mão — foi o que
# aconteceu com o adguard em 2026-07-09 e em 2026-07-28.
#
# Este oneshot roda uma vez após o docker.service e reconcilia todas as stacks
# do repositório com o estado declarado. É idempotente: se tudo já está no ar,
# não faz nada.
# =============================================================================
set -uo pipefail

HOMELAB_DIR="${HOMELAB_DIR:-/srv/the-forge}"
STACKS="${HOMELAB_STACKS:-dns proxy management monitoring cloud}"

log() { logger -t homelab-stacks-boot "$*"; }

# O Docker aceita conexões antes de estar pronto para criar redes/containers.
for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 2
done

for stack in ${STACKS}; do
    dir="${HOMELAB_DIR}/services/${stack}"
    [ -f "${dir}/compose.yaml" ] || { log "stack ${stack}: compose.yaml ausente, pulando"; continue; }

    if (cd "${dir}" && docker compose up -d 2>&1 | logger -t homelab-stacks-boot); then
        log "stack ${stack}: reconciliada"
    else
        log "ERRO: stack ${stack} falhou ao reconciliar"
    fi
done

log "reconciliacao de boot concluida"
