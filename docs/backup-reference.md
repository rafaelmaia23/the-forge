# Backup Reference

Inventário do que precisa ser protegido por backup, construído fase a fase.
Serve de insumo para os scripts e a automação da **Fase 8** (Restic + Rclone + Backblaze B2).

---

## Categorias

| Categoria | Descrição |
| --- | --- |
| **Git** | Em repositório — não precisa de backup extra |
| **Crítico** | Perda causa indisponibilidade real; difícil ou impossível de recriar |
| **Importante** | Perda causa trabalho extra para recriar; vale manter |
| **Dispensável** | Regenerável automaticamente ou sem valor após a perda |

---

## Fase 1 — Fundação Oracle Cloud

| O que | Onde na VM | Categoria | Observação |
| --- | --- | --- | --- |
| Compose files, scripts, docs | `/srv/the-forge/` | Git ✓ | Versionado no repositório |
| Configs Mullvad WireGuard | `/etc/wireguard/*.conf` | Crítico | Fora do repo; perda = sem VPN até redownload no painel Mullvad |
| Systemd service de routing | `/etc/systemd/system/tailscale-docker-forward.service` | Crítico | Fora do repo; sem ele o Docker fica inacessível via Tailscale. Deve ser adicionado ao `provision.sh` |
| Config stub DNS | `/etc/systemd/resolved.conf.d/no-stub.conf` | Crítico | Fora do repo; sem ele a porta 53 fica bloqueada pelo systemd-resolved |
| Segredos da instalação | `~/.homelab/secrets.env` | Crítico | IPs, senhas, tokens — perda = recriar do zero |
| Entrada do block volume | `/etc/fstab` | Crítico | Perda = block volume não monta no boot; documentar o comando de montagem no RUNBOOK |
| Regras UFW | Sistema | Importante | Recriáveis a partir dos guias de fase; mas trabalhoso |
| Imagens Docker | Sistema | Dispensável | Re-baixadas com `docker compose pull` |
| Swapfile | `/swapfile` | Dispensável | Recriável com `fallocate + mkswap + swapon` |

---

## Fase 2 — AdGuard Home

| O que | Onde na VM | Categoria | Observação |
| --- | --- | --- | --- |
| Compose + config AdGuard | `/srv/the-forge/services/dns/` | Git ✓ | `AdGuardHome.yaml` versionado |
| Query log + estatísticas | `/srv/the-forge/services/dns/data/` | Dispensável | Histórico de queries — regenerado pelo uso normal |
| Regra UFW Tailscale→Docker | Aplicada via systemd service | Git indiretamente | Coberto pelo `tailscale-docker-forward.service` (ver Fase 1) |

---

## Fase 3 — Nginx Proxy Manager

| O que | Onde na VM | Categoria | Observação |
| --- | --- | --- | --- |
| Compose + gitignore NPM | `/srv/the-forge/services/proxy/` | Git ✓ | Versionado no repositório |
| SQLite DB do NPM | `/srv/the-forge/services/proxy/data/` | Crítico | Contém toda a configuração: proxy hosts, access lists, usuários, referências a certs. Perda = reconfigurar tudo manualmente no painel. Não precisa de dump — bind mount coberto diretamente pelo Restic |
| Certificados SSL | `/srv/the-forge/services/proxy/letsencrypt/` | Importante | Auto-renováveis via Let's Encrypt, mas backup evita downtime durante reconfiguração. Perda = reemitir certs e reiniciar NPM |
| Senha admin NPM | `~/.homelab/secrets.env` | Crítico | Já coberto pelo item de segredos da Fase 1 |

---

## Fases futuras (preencher conforme avançam)

### Fase 4 — Portainer + Uptime Kuma + Netdata

| O que | Onde na VM | Categoria | Observação |
| --- | --- | --- | --- |
| Compose files | `/srv/the-forge/services/management/` e `monitoring/` | Git ✓ | |
| Dados do Portainer | `services/management/data/` | Dispensável | Estado reconstruível do zero em minutos sem perda real |
| Dados do Uptime Kuma | `services/monitoring/data/` | Importante | Configuração de monitores e histórico de uptime |
| Dados do Netdata | `services/monitoring/netdata-data/` | Dispensável | Métricas históricas — regeneradas pelo uso |

### Fase 5 — Nextcloud

| O que | Onde na VM | Categoria | Observação |
| --- | --- | --- | --- |
| Compose + config | `/srv/the-forge/services/cloud/` | Git ✓ | |
| Arquivos dos usuários | `/mnt/data/nextcloud/userdata/` | **Crítico** | Fotos, documentos, dados pessoais — backup diário obrigatório via Restic |
| Banco PostgreSQL | dump via `pg_dump` | **Crítico** | Contatos, calendários, metadados — dump diário |
| Apps instalados | volume `nextcloud_apps` | Importante | Reinstalação manual pelo painel é possível mas trabalhosa |

### Fase 6 — Jellyfin + Arr Stack

| O que | Onde na VM | Categoria | Observação |
| --- | --- | --- | --- |
| Arquivos de mídia | `/mnt/data/media/` | Importante | Re-baixável pela Arr Stack; backup semanal via Rclone |
| Config Sonarr/Radarr/Prowlarr | volumes respectivos | Importante | Configuração de indexadores e bibliotecas — trabalhosa de recriar |

### Fase 7 — Dawarich

| O que | Onde na VM | Categoria | Observação |
| --- | --- | --- | --- |
| Banco PostgreSQL Dawarich | dump via `pg_dump` | Crítico | Histórico de localização — insubstituível |

---

## Resumo para o script de backup (Fase 8)

### O que o Restic deve cobrir (backup diário)

```
/mnt/data/nextcloud/userdata/          ← arquivos Nextcloud
/srv/the-forge/services/proxy/data/    ← SQLite NPM
/srv/the-forge/services/proxy/letsencrypt/  ← certs SSL
~/.homelab/secrets.env                 ← segredos
/etc/wireguard/                        ← configs Mullvad
/etc/systemd/system/tailscale-docker-forward.service
/etc/systemd/resolved.conf.d/
dumps de banco (nextcloud pg_dump, dawarich pg_dump)
```

### O que o Rclone deve cobrir (sync semanal)

```
/mnt/data/media/    ← arquivos de mídia (excluir downloads/incomplete/)
```

### O que o Git já cobre (não precisa de backup extra)

```
Todos os compose.yaml, scripts, docs, configs versionados em /srv/the-forge/
```

### O que os Snapshots OCI cobrem

Boot volume + block volume — disaster recovery rápido antes de operações de risco.
Não substituem o backup automatizado.

---

_Atualizar este documento ao final de cada fase com o inventário correspondente._
