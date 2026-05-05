# Diagrama de Rede — Estado atual

**Atualizado em:** 2026-05-04
**Versão:** v1.0-foundation

---

## Topologia

```
Dispositivos pessoais (celular / PC / notebook)
│
│ WireGuard (Tailscale)
▼
┌──────────────────────────────────────────────────────────────┐
│  VM Oracle Cloud — ARM A1                                    │
│                                                              │
│  IP público : {{OCI_PUBLIC_IP}}                              │
│  IP Tailscale: {{OCI_TS_IP}}                                 │
│                                                              │
│  Interfaces de rede:                                         │
│    enp0s6     → Internet (IP público Oracle)                 │
│    tailscale0 → Rede privada Tailscale (100.64.0.0/10)       │
│    wg-mull-br → Túnel WireGuard Mullvad VPN (Table=off)       │
│                                                              │
│  Roteamento (policy routing):                                │
│    tráfego iif tailscale0 → tabela 51820 → wg-mull-br         │
│    tráfego da própria VM  → enp0s6 (rota padrão intacta)     │
│    range 100.64.0.0/10   → tailscale0 (local, não sai VPN)   │
│                                                              │
│  Docker:                                                     │
│    rede proxy (bridge)                                       │
│                                                              │
│  Storage:                                                    │
│    /dev/sda → boot volume 50 GB  → /                        │
│    /dev/sdb → block volume 150 GB → /mnt/data               │
│                                                              │
│  Tailscale: exit node ativo                                  │
│  WireGuard: policy routing, apenas tráfego forwardado        │
└──────────────────────────────────────────────────────────────┘
│
│ WireGuard (Mullvad VPN) — apenas tráfego dos dispositivos
▼
Internet pública
(IP visível = servidor Mullvad VPN, não Oracle)
```

---

## Fluxo de tráfego

```
── Acesso a serviços da VM ──────────────────────────────────────
Dispositivo → [Tailscale] → VM (INPUT) → resposta direta

── Acesso à internet pelos dispositivos ─────────────────────────
Dispositivo → [Tailscale] → VM (FORWARD, iif tailscale0)
           → tabela 51820 → [WireGuard/Mullvad VPN] → Internet

── Tráfego da própria VM (SSH, atualizações) ────────────────────
VM → enp0s6 → Internet (IP Oracle, rota padrão)
```

> O DNS privado (AdGuard) será adicionado na Fase 2. Quando ativo,
> os dispositivos passarão a resolver nomes via IP Tailscale da VM.

---

## Configuração OCI

| Parâmetro | Valor |
|-----------|-------|
| Provider | Oracle Cloud Infrastructure |
| Região | {{OCI_REGION}} |
| Availability Domain | {{OCI_AD}} |
| Shape | VM.Standard.A1.Flex |
| OCPUs | 4 |
| RAM | 24 GB |
| OS | Ubuntu 24.04 LTS (ARM) |
| Boot volume | 50 GB |
| Block volume | 150 GB → /mnt/data |
| IP público | {{OCI_PUBLIC_IP}} |

---

## Security List — Regras de entrada ativas

| Porta | Protocolo | Origem | Serviço |
|-------|-----------|--------|---------|
| 22 | TCP | {{MEU_IP}}/32 | SSH (remover após Tailscale estável) |
| 80 | TCP | 0.0.0.0/0 | HTTP |
| 443 | TCP | 0.0.0.0/0 | HTTPS |
| 41641 | UDP | 0.0.0.0/0 | Tailscale WireGuard |

---

## Redes Docker ativas

| Rede | Driver | Escopo | Propósito |
|------|--------|--------|-----------|
| proxy | bridge | local | Compartilhada por todos os serviços acessados pelo NPM |

> Redes internas de cada stack (nextcloud_internal, media_internal etc.)
> serão criadas nas fases seguintes, quando os serviços subirem.

---

## Storage

| Device | Tamanho | Mountpoint | Filesystem | Observação |
|--------|---------|------------|------------|------------|
| /dev/sda | 50 GB | / | ext4 | Boot volume OCI |
| /dev/sdb | 150 GB | /mnt/data | ext4 | Block volume OCI, fstab com `_netdev,nofail` |

---

## O que ainda não está ativo nesta fase

- AdGuard Home (DNS privado) — Fase 2
- Nginx Proxy Manager — Fase 3
- Portainer / Uptime Kuma / Netdata — Fase 4
- Nextcloud — Fase 5
- Jellyfin + Arr Stack — Fase 6
- Dawarich — Fase 7
- Backup Restic + Rclone — Fase 8
