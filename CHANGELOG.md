# Changelog

Mudanças relevantes na infraestrutura do homelab.
Formato: [Keep a Changelog](https://keepachangelog.com)

---

## [Unreleased]

### Fixed

- Restaurado `ipv4_address: 172.18.0.2` no container `adguard` (`services/dns/compose.yaml`) — havia sido removido emergencialmente durante um incidente e ficou com o IP ocupado pelo `portainer`, quebrando o `dns: [172.18.0.2]` hardcoded no Uptime Kuma (ADR-008)
- Drop-in systemd `wg-quick@wg-mull-br.service.d/override.conf` — corrige corrida de boot entre `wg-quick@wg-mull-br` e `tailscaled` que deixava o túnel Mullvad fora do ar após reboot, sem retry automático
- Prioridade da `ip rule to 172.16.0.0/12 lookup main` (ADR-006) alterada de `5200` para `100` — causa originalmente atribuída (errado) a mudança de versão do Tailscale; ver correção abaixo (2026-07-17) para a causa raiz real
- **Causa raiz real da recorrência (2026-07-17)**: a regra `iif tailscale0 lookup 51820` não é do Tailscale — é criada pelo `PostUp` do nosso próprio `wg-mull-br.conf`, sem `priority` fixa, então o `iproute2` reatribuía um valor arbitrário toda vez que o túnel subia (incluindo quando o `tailscaled` faz auto-update e, via `Requires=` do ADR-010, derruba e sobe o `wg-quick@wg-mull-br` de novo). Corrigido fixando `priority 20000` em `wg-mull-br.conf` (`PostUp`/`PostDown` agora idempotentes, com `del ... || true` antes do `add`) e tornando `tailscale-docker-forward.service` self-healing: novo script `/usr/local/sbin/tailscale-docker-forward.sh` descobre a prioridade viva da regra do Mullvad e instala a nossa uma posição abaixo, disparado automaticamente via `PartOf=wg-quick@wg-mull-br.service` sempre que o túnel reiniciar

### ADRs

- ADR-010: Ordem de boot — `wg-quick@wg-mull-br` depende de `tailscaled.service`; nota (2026-07-17) sobre o efeito colateral do `Requires=` que dispara a recorrência do bug do ADR-006
- ADR-006: atualizado com o incidente de prioridade de `ip rule` obsoleta e a correção (5200 → 100); atualizado de novo (2026-07-17) corrigindo o diagnóstico — causa raiz real é a regra própria sem prioridade fixa, não o Tailscale

## [v1.4-nextcloud] — 2026-06-12

### Added

- Nextcloud 33 em `cloud.maiahub.com.br` — cloud pessoal público (acessível sem Tailscale)
- Collabora CODE em `office.maiahub.com.br` — edição de documentos online
- PostgreSQL 18 como banco de dados principal
- Redis 7 para cache de sessão e file locking com autenticação
- Elasticsearch 9.4.2 para busca full-text dentro de arquivos
- ClamAV (`clamav-debian`) para antivírus de uploads via TCP
- Notify Push (sidecar aarch64) para notificações em tempo real nos apps mobile
- Imaginary para geração de thumbnails de imagem
- Apps: `contacts`, `calendar`, `deck`, `tasks`, `notes`, `news`, `whiteboard`, `richdocuments`, `fulltextsearch` + connectors, `files_antivirus`, `notify_push`, `dav_push`, `suspicious_login`, `admin_audit`
- `/data/nginx/custom/server_proxy.conf` no NPM — roteamento `/push` com WebSocket e rewrite de prefixo
- Certificados SSL para `cloud.maiahub.com.br` e `office.maiahub.com.br` via DNS Challenge (Cloudflare)
- DNS Rewrites no AdGuard para ambos os domínios → `{{OCI_PUBLIC_IP}}`
- Parâmetros de kernel: `vm.overcommit_memory=1` e `vm.max_map_count=262144` em `/etc/sysctl.conf`
- `docs/nextcloud-config-reference.md` — referência de configuração atual da stack

### Changed

- `services/cloud/compose.yaml` — `custom_apps` adicionado como bind mount separado (apps instalados via occ)
- `services/cloud/compose.yaml` — `extra_hosts` para `cloud.maiahub.com.br` → IP interno do NPM (fix hairpin NAT para notify_push)
- `services/cloud/compose.yaml` — notify_push entrypoint e volume atualizados de `apps/` para `custom_apps/`
- `trusted_domains` do Nextcloud inclui `nextcloud` (container name) para notify_push conectar internamente

### ADRs

- ADR-009: Nextcloud manual (containers separados) vs AIO

---

## [v1.3-management] — 2026-05-18

### Added

- Portainer CE em `portainer.maiahub.com.br` — gerenciamento visual de containers e stacks
- Uptime Kuma em `monitoring.maiahub.com.br` — 8 monitores de uptime configurados
- Netdata em `netdata.maiahub.com.br` — métricas de sistema em tempo real (CPU, RAM, disco, rede, containers)
- Certificados SSL individuais via DNS Challenge para `portainer.maiahub.com.br`, `monitoring.maiahub.com.br`, `netdata.maiahub.com.br`
- Proxy hosts no NPM com Access List `tailscale-only` para os três serviços
- IP fixo `172.18.0.2` para o container `adguard` via `ipv4_address` no compose — evita IP dinâmico que quebraria o monitor DNS
- `dns: [172.18.0.2]` no compose do Uptime Kuma — permite resolver domínios internos via AdGuard sem hairpin NAT
- Notificações Telegram no Uptime Kuma e no Netdata; Uptime Kuma também com email
- Stacks `dns`, `proxy` e `monitoring` registradas no Portainer

### Changed

- `services/dns/compose.yaml` — adicionado `ipv4_address: 172.18.0.2` para IP fixo do AdGuard
- `services/monitoring/compose.yaml` — adicionado `dns: [172.18.0.2]` ao Uptime Kuma
- Porta `9000` removida do compose do Portainer após proxy verificado

### ADRs

- ADR-008: Uptime Kuma usa endereçamento Docker interno (container names/IPs) por causa do hairpin NAT do Docker (`! -i <bridge>` bloqueia DNAT de containers para IPs externos do host)

---

## [v1.2-proxy] — 2026-05-11

### Added

- Nginx Proxy Manager como ponto de entrada único para tráfego HTTP/HTTPS
- Certificados SSL individuais via DNS Challenge (Cloudflare API) para `npm.maiahub.com.br` e `adguard.maiahub.com.br`
- Access List `tailscale-only` (allow `100.64.0.0/10`, deny all) para painéis de controle
- Proxy host `npm.maiahub.com.br` → `npm:81` com SSL Force + HTTP/2 + Access List
- Proxy host `adguard.maiahub.com.br` → `adguardhome:3000` com SSL Force + HTTP/2 + Access List
- `.gitignore` em `services/proxy/` cobrindo `data/` e `letsencrypt/`

### Changed

- Porta `81` removida do `compose.yaml` do NPM após proxy host verificado
- Porta `3000` removida do `compose.yaml` do AdGuard (acessível via proxy)
- DNS Rewrites dos serviços tailscale-only atualizados de `{{OCI_PUBLIC_IP}}` → `{{OCI_TS_IP}}`
- Regra UFW `allow from 100.64.0.0/10 to any port 3000` removida

### ADRs

- ADR-007: DNS split por nível de acesso (tailscale-only resolve para `{{OCI_TS_IP}}`, público para `{{OCI_PUBLIC_IP}}`)

---

## [v1.1-dns] — 2026-05-06

### Added

- AdGuard Home como servidor DNS privado para todos os dispositivos da rede Tailscale
- Upstream DNS: Quad9 DoH (`dns10.quad9.net`) + Cloudflare DoH em modo paralelo
- Bootstrap DNS: `9.9.9.10`, `149.112.112.10`, `1.1.1.1`
- Blocklists: AdGuard DNS filter + OISD Full (`big.oisd.nl`)
- DNS Rewrites individuais por serviço (sem wildcards) — ver ADR-007
- Override DNS global ativado no painel Tailscale Admin (nameserver = IP Tailscale da VPS)
- Systemd service `tailscale-docker-forward`: `ip rule to 172.16.0.0/12 priority 5200` + `DOCKER-USER ACCEPT` para roteamento Tailscale→containers Docker
- Stub listener do systemd-resolved desativado (`/etc/systemd/resolved.conf.d/no-stub.conf`)
- `.gitignore` em `services/dns/` e `AdGuardHome.yaml` versionado em `services/dns/config/`

### ADRs

- ADR-006: Tailscale Docker routing — `ip rule to 172.16.0.0/12 priority 5200` para evitar pacotes DNATados serem roteados pelo Mullvad VPN
- ADR-007: DNS split por nível de acesso (contexto inicial — wildcard substituído por rewrites individuais)

---

## [v1.0-foundation] — 2026-05-05

### Added

- Estrutura inicial do repositório Git (`the-forge`)
- Infraestrutura Oracle Cloud: VCN, Security List, VM A1 (4 OCPU / 24 GB / Ubuntu 24.04 ARM)
- Block volume de 150 GB criado e montado em `/mnt/data` desde a Fase 1
- Docker CE instalado com log rotation, rede Docker `proxy` criada
- UFW configurado, fail2ban ativo, swapfile de 2 GB
- Atualizações automáticas de segurança habilitadas (sem reboot automático)
- Tailscale instalado como exit node, aprovado no painel admin
- WireGuard + Mullvad VPN com policy routing (`iif tailscale0 → tabela 51820`)
- Servidores Mullvad configurados: BR (São Paulo), US (Nova York), UK (Londres), JP (Tóquio), CH (Zurique)
- `provision.sh` reescrito com auto-detecção de `HOMELAB_DIR` e idempotência
- Regra SSH por IP removida da Security List — acesso exclusivamente via Tailscale
- Snapshots OCI criados: boot volume + block volume (`homelab-v1-foundation-20260505`)
- Documentação: `network-diagram.md`, `migration-log.md`, 5 ADRs, `RUNBOOK.md`

### Desvios do plano original

- **Ubuntu 24.04 em vez de 22.04** — imagem disponível na OCI na data de provisionamento
- **Block volume desde a Fase 1** — evita migração de dados futura; custo zero no free tier
- **WireGuard direto em vez de Proton VPN CLI** — CLI não funciona em ambiente headless (sem `gnome-keyring`)
- **Mullvad em vez de Proton VPN** — servidores Proton "BR-SP" estavam fisicamente em Miami (~200ms, 30% packet loss); Mullvad BR (Datapacket SP) apresentou 0.5ms e ~300 Mbps
- **Repositório clonado em `/srv/the-forge`** — `provision.sh` detecta `HOMELAB_DIR` automaticamente, sem clone duplo
- **Policy routing com `iif tailscale0`** — abordagem `from 100.64.0.0/10` quebrava SSH porque a VM tem IP Tailscale nesse range

---

## [v0.1-premigration] — 2026-04-27

### Added

- Exportação de dados do Nextcloud atual (Hostinger): contatos `.vcf`, calendários `.ics`, tarefas `.ics`, feeds RSS `.opml`
- Download local dos 7 GB de arquivos do Nextcloud
- Backup de referência da Hostinger (AdGuard conf + NPM data)
- Credenciais do `.env` atual documentadas
