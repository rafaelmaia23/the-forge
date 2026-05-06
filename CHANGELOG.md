# Changelog

Mudanças relevantes na infraestrutura do homelab.
Formato: [Keep a Changelog](https://keepachangelog.com)

---

## [Unreleased]

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
