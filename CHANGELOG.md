# Changelog

Mudanças relevantes na infraestrutura do homelab.
Formato: [Keep a Changelog](https://keepachangelog.com)

---

## [Unreleased]

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
