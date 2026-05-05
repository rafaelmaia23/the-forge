# Migration Log

Diário de execução da migração Hostinger → Oracle Cloud.
Atualizado durante a execução de cada fase.

---

## 2026-05-04 — Fase 1: Fundação Oracle Cloud

### O que foi feito

- Repositório `the-forge` criado no GitHub (público)
- Conta OCI com Pay As You Go ativado
- VCN-Homelab criada com Internet Gateway e Public Subnet
- Security List configurada (portas 22/TCP, 80/TCP, 443/TCP, 41641/UDP)
- VM A1 provisionada: 4 OCPU / 24 GB RAM / Ubuntu 24.04 LTS ARM
- Block volume de 150 GB criado e montado em `/mnt/data` (fstab com `_netdev,nofail,noatime`)
- `provision.sh` executado a partir de `/srv/the-forge/infrastructure/`
  - Docker CE instalado com log rotation
  - UFW configurado
  - IP forwarding habilitado (IPv4 + IPv6)
  - Swapfile de 2 GB criado
  - fail2ban configurado
  - Atualizações automáticas de segurança habilitadas
  - Estrutura `/mnt/data` criada
  - Rede Docker `proxy` criada
- Tailscale instalado e configurado como exit node (aprovado no painel admin)
- WireGuard instalado com configurações Proton VPN (BR, US, UK)
- Policy routing configurado: tráfego forwardado pelo Tailscale sai pelo Proton VPN
- `wg-quick@wg-mull-br` habilitado no boot via systemctl

### Configurações anotadas

- IP público Oracle: {{OCI_PUBLIC_IP}}
- IP Tailscale da VM: {{OCI_TS_IP}}
- Região OCI: {{OCI_REGION}}
- Availability Domain: {{OCI_AD}}
- Interface de rede da VM: `enp0s6`
- Gateway padrão: `10.0.0.1`

### Desvios do plano original

**WireGuard com Mullvad em vez de Proton VPN CLI**
A CLI oficial do Proton VPN não funciona em ambientes headless (sem `gnome-keyring` e `NetworkManager`). Além disso, os servidores listados como "BR-SP" pelo Proton estavam fisicamente em Miami (~200ms, 30% packet loss). Migração para Mullvad com WireGuard direto resolveu ambos os problemas — servidores Mullvad BR via Datapacket estão fisicamente em São Paulo (0.5ms, ~300 Mbps).

**Ubuntu 24.04 em vez de 22.04**
A VM foi provisionada com Ubuntu 24.04 LTS. O `provision.sh` foi atualizado para suportar 22.04 e 24.04.

**Block volume montado em `/mnt/data` em vez de `/mnt`**
Montagem direta em `/mnt` impossibilita adicionar outros volumes no futuro. Cada volume fica em sua própria subpasta (`/mnt/data`, `/mnt/backup`, etc.).

**Repositório clonado em `/srv/the-forge` em vez de `/srv`**
O `provision.sh` foi reescrito para detectar automaticamente o `HOMELAB_DIR` com base em onde o script está — sem clone duplo.

**Policy routing com `iif tailscale0` em vez de `from 100.64.0.0/10`**
A abordagem por origem de IP (`from 100.64.0.0/10`) quebra o acesso SSH porque a própria VM tem IP Tailscale nesse range. A abordagem correta é por interface de entrada (`iif tailscale0`), que afeta apenas tráfego sendo forwardado — nunca respostas que a VM gera localmente.

### Problemas encontrados e soluções

**`systemctl reload sshd` retorna "Unit not found"**
No Ubuntu 22.04+, o serviço SSH se chama `ssh`, não `sshd`.
Solução: `sudo systemctl reload ssh`

**WireGuard travava o acesso SSH ao subir**
`wg-quick` com `AllowedIPs = 0.0.0.0/0` sequestra o gateway padrão da VM inteira — inclusive o tráfego Tailscale usado para SSH. Três tentativas de contorno falharam antes de chegar na solução correta com `Table = off` + policy routing por interface.

**Console serial da Oracle não aceita login sem senha**
O usuário `ubuntu` não tem senha por padrão (acesso só via chave SSH). O console serial exige senha.
Solução: definir senha para emergências com `sudo passwd ubuntu` e armazenar em `~/.homelab/secrets.env`.

---

## 2026-05-05 — Troca Proton VPN → Mullvad VPN

### O que foi feito

- Identificado que servidores Proton "BR-SP" estavam fisicamente em Miami via `curl https://ipinfo.io/`
- Testados servidores Mullvad BR (Zenlayer/Fortaleza, Datapacket/SP, Hostroyale/SP)
- Migração para Mullvad VPN via WireGuard — provider Datapacket, São Paulo
- Todos os arquivos `.conf` do Proton removidos de `/etc/wireguard/`
- `wg-quick@wg-br-57` (Proton) desabilitado do boot
- `wg-quick@wg-mull-br` (Mullvad) habilitado no boot

### Resultado

| Métrica | Proton BR-SP | Mullvad BR (Datapacket) |
|---|---|---|
| Localização real | Miami 🇺🇸 | São Paulo 🇧🇷 |
| Latência | ~200ms | 0.5ms |
| Packet loss | 30% | 0% |
| Velocidade celular | ~40 Mbps | ~300 Mbps |

---

- **Fase 2** — AdGuard Home: DNS privado com bloqueio de trackers
- **Fase 3** — Nginx Proxy Manager: proxy reverso com SSL wildcard
- **Fase 4** — Portainer + Uptime Kuma + Netdata: gerenciamento e monitoramento
- **Fase 5** — Nextcloud: migração dos dados da Hostinger
- **Fase 6** — Jellyfin + Arr Stack: servidor de mídia
- **Fase 7** — Dawarich: histórico de localização
- **Fase 8** — Backup: Restic + Rclone + Backblaze B2
- **Fase 9** — Corte final: cancelar Hostinger
