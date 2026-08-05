# Diagrama de Rede — Estado atual

**Atualizado em:** 2026-05-18
**Versão:** v1.4-management

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
│    (túnel Mullvad removido em 2026-08-05, ver ADR-015)        │
│                                                              │
│  Roteamento:                                                 │
│    tráfego da própria VM     → enp0s6 (rota padrão intacta)  │
│    exit node opt-in (quando ligado) → enp0s6, MASQUERADE via │
│    tailscale-exit-masquerade.service (ADR-015)                │
│                                                              │
│  Docker (rede proxy — bridge 172.18.0.0/16):                  │
│    adguard       [:53 pub, :3000 interno]  DNS + bloqueio   │
│    npm           [:80 pub, :443 pub, :81 interno]  proxy    │
│    portainer     [:9000 interno]           gerenciamento     │
│    uptime-kuma   [:3001 interno]           monitoramento     │
│    netdata       [:19999 interno]          métricas          │
│                                                              │
│  Storage:                                                    │
│    /dev/sda → boot volume 50 GB  → /                        │
│    /dev/sdb → block volume 150 GB → /mnt/data               │
│                                                              │
│  Tailscale: exit node anunciado, uso opt-in por dispositivo   │
└──────────────────────────────────────────────────────────────┘
│
▼
Internet pública
(IP visível = do próprio dispositivo; ou IP Oracle, se o exit
 node estiver ligado manualmente — ADR-015)
```

---

## Fluxo de tráfego

```
── Acesso a serviços da VM ──────────────────────────────────────
Dispositivo → [Tailscale] → VM (INPUT) → resposta direta

── Acesso à internet pelos dispositivos (padrão) ────────────────
Dispositivo → Internet direto, sem passar pela VM

── Acesso à internet com exit node ligado (opt-in, ver ADR-015) ─
Dispositivo → [Tailscale] → VM (FORWARD, iif tailscale0)
           → MASQUERADE (tailscale-exit-masquerade) → enp0s6 → Internet

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

| Rede | Subnet | Driver | Containers |
|------|--------|--------|------------|
| proxy | `172.18.0.0/16` | bridge | adguard, npm, portainer, uptime-kuma, netdata |

> Redes internas de cada stack (nextcloud_internal, media_internal etc.)
> serão criadas nas fases seguintes, quando os serviços subirem.

## Serviços e acesso

| Serviço | Container | Acesso externo | Acesso interno |
|---------|-----------|----------------|----------------|
| AdGuard Home | `adguard` | `https://adguard.maiahub.com.br` (tailscale-only) | `http://adguard:3000` |
| Nginx Proxy Manager | `npm` | `https://npm.maiahub.com.br` (tailscale-only) | `http://npm:81` |
| Portainer | `portainer` | `https://portainer.maiahub.com.br` (tailscale-only) | `http://portainer:9000` |
| Uptime Kuma | `uptime-kuma` | `https://monitoring.maiahub.com.br` (tailscale-only) | `http://uptime-kuma:3001` |
| Netdata | `netdata` | `https://netdata.maiahub.com.br` (tailscale-only) | `http://netdata:19999` |

> **Nota de monitoramento:** O Uptime Kuma acessa todos os serviços via endereço interno Docker (container name ou IP), não via domínio. Ver [ADR-008](decisions/ADR-008-uptime-kuma-hairpin-nat.md).

---

## Storage

| Device | Tamanho | Mountpoint | Filesystem | Observação |
|--------|---------|------------|------------|------------|
| /dev/sda | 50 GB | / | ext4 | Boot volume OCI |
| /dev/sdb | 150 GB | /mnt/data | ext4 | Block volume OCI, fstab com `_netdev,nofail` |

---

## O que ainda não está ativo nesta fase

- Nextcloud — Fase 5
- Jellyfin + Arr Stack — Fase 6
- Dawarich — Fase 7
- Backup Restic + Rclone — Fase 8
