# Runbook — Operações do Homelab

Referência rápida para operações do dia a dia.
Atualizado a cada fase conforme novos serviços sobem.

---

## Acesso à VM

```bash
# SSH via Tailscale (preferencial)
ssh homelab

# SSH via IP público (emergência, se Tailscale não responder)
ssh -i ~/.ssh/oracle_homelab ubuntu@{{OCI_PUBLIC_IP}}

# Console serial (último recurso — requer senha do usuário ubuntu)
# OCI Console → Compute → Instances → homelab-oracle → Console Connection
```

---

## Status geral

```bash
# Visão geral rápida
tailscale status                        # dispositivos na rede Tailscale
sudo wg show                            # status do tunnel WireGuard Mullvad
curl -s https://api.ipify.org           # IP público da VM (deve ser IP Oracle)
sudo ufw status verbose                 # regras de firewall ativas
docker ps                               # containers rodando
df -h                                   # uso de disco
free -h                                 # uso de memória
```

---

## WireGuard / Mullvad VPN

### Verificar estado

```bash
sudo wg show                            # tunnel ativo e último handshake
ip rule | grep tailscale                # deve mostrar: iif tailscale0 lookup 51820
ip route show table 51820               # deve mostrar: default dev wg-mull-br + 100.64.0.0/10
ip route | grep default                 # default via 10.0.0.1 dev enp0s6 (intacto)
```

### Trocar de servidor

```bash
# 1. Derrubar o tunnel atual
sudo wg-quick down wg-mull-br

# 2. Limpar rotas órfãs (sempre fazer antes de subir outro)
sudo ip route del 100.64.0.0/10 table 51820 2>/dev/null
sudo ip rule del iif tailscale0 table 51820 2>/dev/null

# 3. Subir o servidor desejado
sudo wg-quick up wg-mull-us     # Estados Unidos
sudo wg-quick up wg-mull-uk     # Reino Unido
sudo wg-quick up wg-mull-jp     # Japão
sudo wg-quick up wg-mull-ch     # Suíça
sudo wg-quick up wg-mull-br     # Brasil (padrão)
```

### Servidores disponíveis

| Arquivo | País | Cidade | Provider | Uso |
|---|---|---|---|---|
| `wg-mull-br.conf` | Brasil | São Paulo | Datapacket | Padrão |
| `wg-mull-us.conf` | EUA | Nova York | — | Conteúdo americano |
| `wg-mull-uk.conf` | Reino Unido | Londres | — | Conteúdo britânico |
| `wg-mull-jp.conf` | Japão | Tóquio | — | Animes / conteúdo asiático |
| `wg-mull-ch.conf` | Suíça | Zurique | — | Privacidade máxima |

### Atualizar chaves WireGuard

As chaves do Mullvad não expiram automaticamente mas podem ser rotacionadas:

```bash
# 1. Gerar novo .conf em mullvad.net/en/account/wireguard-config
# 2. Substituir o arquivo na VM
sudo nano /etc/wireguard/wg-mull-br.conf

# 3. Reiniciar o tunnel
sudo wg-quick down wg-mull-br
sudo ip route del 100.64.0.0/10 table 51820 2>/dev/null
sudo ip rule del iif tailscale0 table 51820 2>/dev/null
sudo wg-quick up wg-mull-br
```

---

## Tailscale

```bash
tailscale status                        # todos os dispositivos
tailscale ip -4                         # IP Tailscale da VM
sudo tailscale up --advertise-exit-node # re-anunciar como exit node se necessário
```

### Recuperar acesso se o Tailscale travar

```bash
sudo systemctl restart tailscale
sudo tailscale up --advertise-exit-node
```

---

## Docker

### Operações básicas

```bash
docker ps                               # containers rodando
docker ps -a                            # todos os containers
docker stats                            # uso de CPU/memória em tempo real
docker system df                        # uso de disco por imagens/volumes
```

### Por serviço

```bash
# Ver logs (substituir <nome> pelo serviço)
docker compose -f /srv/the-forge/services/<nome>/compose.yaml logs -f --tail=100

# Reiniciar
cd /srv/the-forge/services/<nome> && docker compose restart

# Atualizar imagem e recriar container
cd /srv/the-forge/services/<nome> && docker compose pull && docker compose up -d

# Derrubar completamente
cd /srv/the-forge/services/<nome> && docker compose down
```

### Limpeza

```bash
# Remover imagens não usadas
docker image prune -a

# Remover tudo não usado (cuidado — remove volumes órfãos também)
docker system prune -a --volumes
```

---

## Disco e storage

```bash
df -h                                   # uso geral
df -h /mnt/data                         # block volume (150 GB)
du -sh /mnt/data/*                      # uso por diretório em /mnt/data
lsblk                                   # volumes montados

# Verificar se o block volume está montado
mountpoint /mnt/data && echo "montado" || echo "NÃO montado"

# Remontar manualmente se necessário
sudo mount -a
```

---

## Repositório

```bash
# Atualizar o repositório na VM
cd /srv/the-forge && git pull

# Ver status
git status
git log --oneline -10
```

---

## Firewall (UFW)

```bash
sudo ufw status verbose                 # regras ativas
sudo ufw allow <porta>/tcp              # adicionar regra
sudo ufw delete allow <porta>/tcp       # remover regra
```

Regras ativas na Fase 1:

| Porta | Protocolo | Serviço |
|---|---|---|
| 22 | TCP | SSH (remover após confirmar acesso só via Tailscale) |
| 80 | TCP | HTTP |
| 443 | TCP | HTTPS |
| 41641 | UDP | Tailscale WireGuard |

---

## Emergências

### VM inacessível via SSH e Tailscale

1. Acessar console serial: OCI Console → Compute → Instances → homelab-oracle → Console Connection
2. Login: `ubuntu` + senha definida via `sudo passwd ubuntu`
3. Verificar o que travou:

```bash
sudo systemctl status tailscale
sudo wg show
sudo systemctl status ssh
journalctl -xe --no-pager | tail -50
```

### WireGuard travou e cortou acesso

```bash
# Derrubar forçado
sudo ip link delete wg-mull-br 2>/dev/null

# Limpar regras residuais
sudo ip route del 100.64.0.0/10 table 51820 2>/dev/null
sudo ip rule del iif tailscale0 table 51820 2>/dev/null
sudo iptables -t nat -F POSTROUTING
sudo iptables -t mangle -F FORWARD

# Subir novamente
sudo wg-quick up wg-mull-br
```

### Disco cheio

```bash
# Identificar o culpado
du -sh /mnt/data/* | sort -rh | head -10
docker system df -v

# Limpar logs de containers
docker system prune --volumes

# Limpar logs antigos do sistema
sudo journalctl --vacuum-time=7d
```

---

## Nginx Proxy Manager (NPM)

```bash
# Status
docker ps | grep npm
docker logs npm --tail 50

# Reiniciar
docker restart npm

# Atualizar imagem
cd /srv/the-forge/services/proxy
docker compose pull && docker compose up -d

# Verificar certificados
docker exec npm ls /etc/letsencrypt/live/

# Testar proxy hosts
curl -sk https://npm.maiahub.com.br -o /dev/null -w "%{http_code}\n"
curl -sk https://adguard.maiahub.com.br -o /dev/null -w "%{http_code}\n"
```

### Acesso de emergência ao painel NPM

Se `https://npm.maiahub.com.br` parar de funcionar:

```bash
# Opção 1: acessar de dentro da VM
ssh homelab
curl http://localhost:81

# Opção 2: adicionar porta temporariamente
# Editar /srv/the-forge/services/proxy/compose.yaml na VM
# Adicionar "- "81:81"" em ports, então:
cd /srv/the-forge/services/proxy && docker compose up -d
# Diagnosticar, corrigir o proxy host, depois remover a porta e docker compose up -d
```

---

## Serviços ativos por fase

| Fase | Serviço | Container | Acesso |
|---|---|---|---|
| 1 | Docker | — | sistema |
| 1 | Tailscale | — | exit node |
| 1 | WireGuard/Mullvad | — | `wg-mull-br` |
| 1 | UFW | — | firewall |
| 1 | fail2ban | — | segurança |
| 2 | AdGuard Home | `adguard` | `https://adguard.maiahub.com.br` |
| 3 | Nginx Proxy Manager | `npm` | `https://npm.maiahub.com.br` |
