# Changelog

Mudanças relevantes na infraestrutura do homelab.
Formato: [Keep a Changelog](https://keepachangelog.com)

---

## [Unreleased]

### Added

- `infrastructure/watchdog/` — três unidades systemd que verificam **comportamento**, não estado: `homelab-dns-watchdog` (resolve query real contra o AdGuard), `homelab-vpn-watchdog` (handshake + saída real pelo túnel, com failover para o gateway direto) e `homelab-stacks-boot` (reconcilia todas as stacks após o boot). Heartbeat via push monitor do Uptime Kuma — silêncio é o alerta (ADR-014)
- `--ip-range 172.18.128.0/17` na rede `proxy`, reservando `172.18.0.0/17` para IPs fixos (ADR-011)
- `ipv4_address` para `npm` (`172.18.0.3`) e `uptime-kuma` (`172.18.0.4`) — o primeiro casa com o `extra_hosts` do Nextcloud/Collabora, o segundo é a push URL dos watchdogs (ADR-011)
- Volume nomeado `nextcloud_html` para `/var/www/html` (ADR-013)
- `Restart=on-failure` no drop-in do `wg-quick@wg-mull-br` (ADR-010, atualização)
- Seção "Primeiro socorro" no RUNBOOK: `tailscale set --accept-dns=false` devolve a internet em qualquer dispositivo sem depender do servidor

### Fixed

- **Túnel Mullvad sem peer** — o `wg-mull-br.conf` perdeu o bloco `[Peer]` numa edição em 2026-07-17; como o `wg-quick` só lê o arquivo no `up`, a interface rodou 11 dias com o peer no kernel e o reboot de 2026-07-28 releu o arquivo quebrado. Todo tráfego de exit node virou buraco negro, com a unit systemd `active`. Bloco restaurado por merge do backup
- **AdGuard não subia após reboot** — o Docker alocava IPs dinâmicos a partir do início da subnet, colidindo com o `172.18.0.2` fixo. Aconteceu em 2026-07-09 e 2026-07-28. Resolvido estruturalmente pelo `--ip-range` (ADR-011)
- **Dependência circular de DNS** — o `/etc/resolv.conf` da VPS apontava para o MagicDNS → AdGuard → container na própria VPS; com o AdGuard fora, o servidor perdia resolução de nomes e parecia offline. `resolv.conf` estático + `--accept-dns=false` na VPS (ADR-012)
- **Uptime Kuma não conseguia notificar** — tinha `dns: [172.18.0.2]` apenas; sem o AdGuard ele detectava a queda mas não resolvia `api.telegram.org` e a entrega falhava em silêncio. Fallback `9.9.9.9` adicionado (ADR-012)
- **Nextcloud entrava em loop de instalação após `compose down`** — `/var/www/html` era volume anônimo; o container novo subia vazio e o entrypoint tentava instalar por cima de uma instância existente (ADR-013)
- **Painéis retornando 403** — `ts-postrouting` mascarava o tráfego forwardado pelo Tailscale (o DNAT do Docker é o que o torna forwardado), então o NPM via `172.18.0.1` em vez do IP `100.x` e a Access List barrava. Corrigido com `tailscale set --snat-subnet-routes=false`; o aviso do Tailscale sobre exit node não se aplica porque o `PostUp` do Mullvad já provê o MASQUERADE
- **O failover impedia o túnel de voltar** — encontrado em ensaio: a rota de failover ocupa o mesmo `default` da tabela 51820 que o `PostUp` instalava com `ip route add`, e o `wg-quick` abortava com `RTNETLINK answers: File exists`. Corrigido com `ip route replace` no `.conf` e remoção da rota pelo watchdog antes do restart (ADR-014)
- `PostUp` do `wg-mull-br.conf` passou a usar `iptables -C` antes de `-A` no MASQUERADE e no TCPMSS — as regras duplicavam quando a interface era removida sem `PostDown`

- Restaurado `ipv4_address: 172.18.0.2` no container `adguard` (`services/dns/compose.yaml`) — havia sido removido emergencialmente durante um incidente e ficou com o IP ocupado pelo `portainer`, quebrando o `dns: [172.18.0.2]` hardcoded no Uptime Kuma (ADR-008)
- Drop-in systemd `wg-quick@wg-mull-br.service.d/override.conf` — corrige corrida de boot entre `wg-quick@wg-mull-br` e `tailscaled` que deixava o túnel Mullvad fora do ar após reboot, sem retry automático
- Prioridade da `ip rule to 172.16.0.0/12 lookup main` (ADR-006) alterada de `5200` para `100` — causa originalmente atribuída (errado) a mudança de versão do Tailscale; ver correção abaixo (2026-07-17) para a causa raiz real
- **Causa raiz real da recorrência (2026-07-17)**: a regra `iif tailscale0 lookup 51820` não é do Tailscale — é criada pelo `PostUp` do nosso próprio `wg-mull-br.conf`, sem `priority` fixa, então o `iproute2` reatribuía um valor arbitrário toda vez que o túnel subia (incluindo quando o `tailscaled` faz auto-update e, via `Requires=` do ADR-010, derruba e sobe o `wg-quick@wg-mull-br` de novo). Corrigido fixando `priority 20000` em `wg-mull-br.conf` (`PostUp`/`PostDown` agora idempotentes, com `del ... || true` antes do `add`) e tornando `tailscale-docker-forward.service` self-healing: novo script `/usr/local/sbin/tailscale-docker-forward.sh` descobre a prioridade viva da regra do Mullvad e instala a nossa uma posição abaixo, disparado automaticamente via `PartOf=wg-quick@wg-mull-br.service` sempre que o túnel reiniciar

### ADRs

- ADR-011: Reserva de faixa IPAM para IPs fixos na rede `proxy`
- ADR-012: O monitoramento não pode depender do que ele monitora
- ADR-013: Volume nomeado para o código do Nextcloud
- ADR-014: Watchdogs funcionais e failover de saída
- ADR-008: atualizado — o IP fixo agora é garantido pelo `ip_range`, e o `uptime-kuma` ganhou IP fixo e fallback de DNS
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
