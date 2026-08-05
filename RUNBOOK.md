# Runbook — Operações do Homelab

Referência rápida para operações do dia a dia.
Atualizado a cada fase conforme novos serviços sobem.

---

## 🚑 Primeiro socorro — "fiquei sem internet"

Antes de qualquer diagnóstico, recupere o acesso. Em **qualquer dispositivo**:

```bash
tailscale set --accept-dns=false
```

Isso desliga só o DNS do tailnet — você volta a resolver pela operadora e a
internet volta na hora, mantendo o acesso ao servidor por IP (`ssh homelab`).
Perde bloqueio de anúncios e os domínios internos até religar. Para voltar ao
normal depois de resolver: `tailscale set --accept-dns=true`.

Se a internet **não** voltar com isso, o problema não é DNS — é o exit node
ligado no dispositivo. Desligue-o (`tailscale set --exit-node=`); sem VPN
Mullvad (ver ADR-015), a saída volta a ser direta pela própria rede do
dispositivo, sem depender de mais nada na VPS.

> O `homelab-dns-watchdog` (ADR-014) trata sozinho falhas do AdGuard em até
> ~2 minutos. Este procedimento é para quando você não quer esperar, ou
> quando ele falhou.

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
curl -s https://api.ipify.org           # IP público da VM (deve ser IP Oracle)
sudo ufw status verbose                 # regras de firewall ativas
docker ps                               # containers rodando
df -h                                   # uso de disco
free -h                                 # uso de memória
```

---

## Tailscale

```bash
tailscale status                        # todos os dispositivos
tailscale ip -4                         # IP Tailscale da VM
sudo tailscale up --advertise-exit-node # re-anunciar como exit node se necessário
```

### Usar a VPS como exit node (opt-in, por dispositivo)

Desde a ADR-015, não há mais VPN de saída — os dispositivos navegam direto
pela própria rede deles por padrão. Para mascarar o IP de um dispositivo
específico usando o IP público da VPS (sem o anonimato de uma VPN comercial):

```bash
# No dispositivo que você quer mascarar:
tailscale set --exit-node=<ip-tailscale-da-vps> --exit-node-allow-lan-in=true

# Conferir:
curl -s https://api.ipify.org           # deve mostrar o IP público Oracle

# Voltar ao padrão (saída direta pela própria rede):
tailscale set --exit-node=
```

Isso não é o padrão e não deve virar rotina — é para os casos pontuais em
que faz sentido aparecer com o IP da VPS.

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
sudo systemctl status ssh
journalctl -xe --no-pager | tail -50
```

### AdGuard não sobe após crash / DNS caiu para todo mundo

> **Este procedimento ficou obsoleto em 2026-07-28.** A rede `proxy` agora é
> criada com `--ip-range 172.18.128.0/17`, reservando `172.18.0.0/17` para IPs
> fixos — o Docker não tem mais como entregar o `172.18.0.2` a outro container
> (ADR-011). O `homelab-dns-watchdog` também recria a stack `dns` sozinho se o
> AdGuard parar de responder. Mantido aqui apenas como referência histórica dos
> incidentes de 2026-07-09 e 2026-07-28.

Diagnóstico atual:

```bash
# O AdGuard responde de verdade? (container "Up" nao basta — ver ADR-014)
dig +short @172.18.0.2 cloudflare.com

# Se nao responder, o watchdog ja deve estar agindo. Para acompanhar:
journalctl -t homelab-dns-watchdog -f

# Para forcar agora, sem esperar o timer:
sudo /usr/local/sbin/homelab-dns-watchdog.sh

# Conferir os IPs da rede
docker network inspect proxy --format '{{range .Containers}}{{.IPv4Address}}  {{.Name}}{{"\n"}}{{end}}' | sort -t. -k3 -k4 -n
```

Os IPs fixos são `adguard` `.2`, `npm` `.3` e `uptime-kuma` `.4`. Qualquer
container fora dessa lista deve aparecer em `172.18.128.x`. Se algum fixo
aparecer no pool dinâmico, a rede foi recriada sem o `--ip-range` — recrie
seguindo `infrastructure/provision.sh` (seção 9).

**Nunca remova um `ipv4_address`** dos composes como solução — foi o atalho
tomado em 2026-07-09 e ele causou diretamente o incidente de 2026-07-28.

---

### Watchdogs — operação

```bash
systemctl list-timers 'homelab-*'                  # proximos disparos
systemctl status homelab-dns-watchdog.timer
journalctl -t homelab-dns-watchdog --since today

# Config (tokens de push do Uptime Kuma — 0600, fora do repo)
sudo cat /etc/homelab-watchdog.env
```

O watchdog bate heartbeat no push monitor **apenas quando o AdGuard responde
de fato**. Silêncio é alerta: se o watchdog não roda, ou o host caiu, ou o
timer morreu — os dois merecem aviso. Ver ADR-014.

> O watchdog do túnel Mullvad existiu até 2026-08-05 — ver
> [ADR-015](docs/decisions/ADR-015-remocao-mullvad-saida-direta.md) e
> `infrastructure/watchdog/archive-mullvad/`.

### Painéis internos (`*.maiahub.com.br` tailscale-only) inacessíveis mesmo com Tailscale up

**Antes de tudo, distinga o sintoma — eles têm causas completamente diferentes:**

| Sintoma no navegador | Causa provável |
| --- | --- |
| Erro de DNS / "não foi possível encontrar o endereço" | `--accept-dns=false` no dispositivo, ou AdGuard fora |
| **HTTP 403** | Access List do NPM barrando — o IP real do cliente não está chegando |
| 502 / 504 | container de destino fora do ar |
| Timeout | roteamento (ver ADR-006) |

**403 — o IP do cliente está sendo mascarado**

```bash
# Qual IP chegou ao NPM?
docker exec npm sh -c "tail -n 5 -q /data/logs/proxy-host-*_access.log" | grep -o '\[Client [0-9.]*\]'
```

Se aparecer `[Client 172.18.0.1]` (o gateway da bridge) em vez do seu IP
`100.x`, o Tailscale está mascarando o tráfego forwardado: a chain `ts-forward`
marca com `0x40000` todo pacote vindo de `tailscale0`, e `ts-postrouting`
mascara por essa marca — e o DNAT do Docker é justamente o que transforma a
conexão em "forwardada". Correção:

```bash
sudo tailscale set --snat-subnet-routes=false
```

O Tailscale emite um aviso sobre exit node; **não se aplica ao tráfego para os
painéis** — isso é tráfego Tailscale→Docker, não exit node. O NAT do exit node
(quando ligado num dispositivo, ver ADR-015) é feito à parte pelo
`tailscale-exit-masquerade.service`, na interface física da VPS. Visto em
2026-07-28.

> **Histórico (obsoleto desde 2026-08-05, ver ADR-015):** até a remoção do
> Mullvad, havia uma segunda causa possível para 403/timeout em todos os
> dispositivos: a regra `to 172.16.0.0/12 lookup main`
> (`tailscale-docker-forward.service`) precisava ter prioridade **menor**
> (avaliada antes) que a regra `iif tailscale0 lookup 51820` do
> `wg-mull-br.conf`, que tinha uma rota `default` (catch-all) pro túnel
> Mullvad na tabela 51820 — se avaliada primeiro, todo tráfego Tailscale→Docker
> era desviado pelo Mullvad e mascarado sob um único IP interno (ADR-006,
> incidentes de 2026-07-16 e 2026-07-17). Sem o túnel Mullvad, não existe mais
> essa rota concorrente — `to 172.16.0.0/12 lookup main` é hoje redundante com
> a tabela `main` padrão, mantida apenas por simplicidade.

**Se acontece só em um dispositivo específico** — investigue o
lado do cliente antes de mexer na VPS:

```bash
# No PC/celular afetado (não na VPS):
dig uptimekuma.maiahub.com.br                    # resolver padrão do SO
dig @{{OCI_TS_IP}} uptimekuma.maiahub.com.br      # direto no AdGuard da VPS
# (Windows: nslookup <domínio> / nslookup <domínio> {{OCI_TS_IP}})
```

- Se a consulta direta ao AdGuard (`@{{OCI_TS_IP}}`) resolver mas a do
  resolver padrão do SO não → checar "Accept DNS"/"Use Tailscale DNS
  settings" no app do Tailscale nesse dispositivo.
- Se ambas resolverem certo mas só o **navegador** falhar → o navegador está
  usando DNS-over-HTTPS ("Secure DNS"), que ignora o resolver do Tailscale.
  Esses domínios só existem como DNS Rewrite local no AdGuard — nunca tiveram
  registro público — então qualquer resolver DoH público retorna NXDOMAIN.
  Desativar: Firefox → `about:preferences#privacy` → "DNS over HTTPS"; Brave →
  `brave://settings/security` → "Use secure DNS".

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
| 1 | Tailscale | — | rede privada + exit node opt-in (ADR-015) |
| 1 | UFW | — | firewall |
| 1 | fail2ban | — | segurança |
| 2 | AdGuard Home | `adguard` | `https://adguard.maiahub.com.br` |
| 3 | Nginx Proxy Manager | `npm` | `https://npm.maiahub.com.br` |
| 4 | Portainer | `portainer` | `https://portainer.maiahub.com.br` |
| 4 | Uptime Kuma | `uptime-kuma` | `https://monitoring.maiahub.com.br` |
| 4 | Netdata | `netdata` | `https://netdata.maiahub.com.br` |
