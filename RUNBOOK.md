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

## AdGuard Home

```bash
# Status e logs
docker ps | grep adguard
docker logs adguard --tail 50

# Reiniciar
docker restart adguard

# Verificar DNS respondendo
dig @127.0.0.1 npm.maiahub.com.br A

# Atualizar imagem
cd /srv/the-forge/services/dns
docker compose pull && docker compose up -d
```

### Acesso de emergência ao painel AdGuard

Se `https://adguard.maiahub.com.br` parar de funcionar:

```bash
# Verificar se o container está rodando
docker ps | grep adguard

# O painel está em :3000 internamente — adicionar temporariamente
# Editar /srv/the-forge/services/dns/compose.yaml na VM
# Adicionar "- "3000:3000"" em ports, então:
cd /srv/the-forge/services/dns && docker compose up -d
# Diagnosticar, corrigir, remover a porta e docker compose up -d
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

## Portainer

```bash
# Status e logs
docker ps | grep portainer
docker logs portainer --tail 50

# Reiniciar
docker restart portainer

# Atualizar imagem
cd /srv/the-forge/services/management
docker compose pull && docker compose up -d
```

### Acesso de emergência ao Portainer

Se `https://portainer.maiahub.com.br` parar de funcionar:

```bash
# Adicionar porta temporariamente no compose.yaml da VM
# Adicionar "- "9000:9000"" em ports:
cd /srv/the-forge/services/management && docker compose up -d
# Acessar via http://{{OCI_TS_IP}}:9000, diagnosticar, remover a porta
```

---

## Uptime Kuma

```bash
# Status e logs
docker ps | grep uptime-kuma
docker logs uptime-kuma --tail 50

# Reiniciar
docker restart uptime-kuma

# Atualizar imagem
cd /srv/the-forge/services/monitoring
docker compose pull && docker compose up -d
```

---

## Netdata

```bash
# Status e logs
docker ps | grep netdata
docker logs netdata --tail 50

# Ver alertas ativos (WARNING/CRITICAL)
docker exec netdata curl -s 'http://localhost:19999/api/v1/alarms' | python3 -m json.tool | grep -E '"status"|"name"|"chart"'

# Testar notificação Telegram
docker exec netdata /usr/libexec/netdata/plugins.d/alarm-notify.sh test telegram

# Ver/editar configuração de notificações (email desabilitado — Netdata usa sendmail, não SMTP direto)
# Para alertas de disponibilidade usar o Uptime Kuma

# Atualizar imagem
cd /srv/the-forge/services/monitoring
docker compose pull && docker compose up -d
```

---

## Monitoramento — Adicionar novo serviço ao Uptime Kuma

O Uptime Kuma acessa serviços **via endereço Docker interno**, não via domínio.
Isso é necessário por causa da restrição de hairpin NAT do Docker — ver [ADR-008](docs/decisions/ADR-008-uptime-kuma-hairpin-nat.md).

### Para serviços na rede `proxy`

Todos os serviços do homelab estão na rede `proxy`. O Uptime Kuma também está nessa rede,
então consegue atingir qualquer container diretamente pelo nome:

No Uptime Kuma: **Add New Monitor**

| Campo | Valor |
|---|---|
| Monitor Type | HTTP(s) |
| Friendly Name | nome do serviço |
| URL | `http://<container_name>:<porta_interna>` |
| Heartbeat Interval | `60` |
| Notification | Email Homelab ✅ + Telegram ✅ |

Exemplos de portas internas dos serviços atuais:

| Container | Porta interna | URL no Uptime Kuma |
|---|---|---|
| `npm` | `81` | `http://npm:81` |
| `adguard` | `3000` | `http://adguard:3000` |
| `portainer` | `9000` | `http://portainer:9000` |
| `netdata` | `19999` | `http://netdata:19999` |
| `uptime-kuma` | `3001` | `http://uptime-kuma:3001` |

Para um novo serviço (ex: Nextcloud com container `nextcloud` na porta `80`):

```
URL: http://nextcloud:80
```

### Para verificar disponibilidade pública (portas 80/443)

Separado do monitor interno, útil para detectar problemas no NPM ou na OCI:

| Campo | Valor |
|---|---|
| Monitor Type | TCP Port |
| Hostname | `{{OCI_PUBLIC_IP}}` |
| Port | `80` ou `443` |

### Para o monitor DNS do AdGuard

O monitor DNS usa o IP do container `adguard` como Resolver Server (não o IP Tailscale).
O IP está fixado em `172.18.0.2` via `ipv4_address` no compose — não muda ao recriar o container.

| Campo | Valor |
|---|---|
| Monitor Type | DNS |
| Hostname | `npm.maiahub.com.br` (domínio a resolver) |
| Resolver Server | `172.18.0.2` (IP fixo do container adguard) |
| Port | `53` |
| Record Type | `A` |

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
| 4 | Portainer | `portainer` | `https://portainer.maiahub.com.br` |
| 4 | Uptime Kuma | `uptime-kuma` | `https://monitoring.maiahub.com.br` |
| 4 | Netdata | `netdata` | `https://netdata.maiahub.com.br` |
