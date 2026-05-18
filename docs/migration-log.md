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

### O que mudou

- Identificado que servidores Proton "BR-SP" estavam fisicamente em Miami via `curl https://ipinfo.io/`
- Testados servidores Mullvad BR (Zenlayer/Fortaleza, Datapacket/SP, Hostroyale/SP)
- Migração para Mullvad VPN via WireGuard — provider Datapacket, São Paulo
- Todos os arquivos `.conf` do Proton removidos de `/etc/wireguard/`
- `wg-quick@wg-br-57` (Proton) desabilitado do boot
- `wg-quick@wg-mull-br` (Mullvad) habilitado no boot

### Resultado

| Métrica | Proton BR-SP | Mullvad BR (Datapacket) |
| --- | --- | --- |
| Localização real | Miami 🇺🇸 | São Paulo 🇧🇷 |
| Latência | ~200ms | 0.5ms |
| Packet loss | 30% | 0% |
| Velocidade celular | ~40 Mbps | ~300 Mbps |

---

## 2026-05-06/07 — Fase 2: AdGuard Home

### O que foi feito

- `services/dns/compose.yaml` criado e commitado
- `services/dns/.gitignore` local criado (documenta o `data/` ignorado)
- Stub listener do systemd-resolved desativado (`/etc/systemd/resolved.conf.d/no-stub.conf`)
- `/etc/resolv.conf` confirmado como symlink para `/run/systemd/resolve/resolv.conf` (nameserver: `169.254.169.254`, OCI DHCP — correto)
- Container adguard subiu sem erros, porta 53 e 3000 respondendo localmente
- Upstream DNS configurado: Quad9 + Cloudflare + Mullvad DoH em modo paralelo
- Bootstrap DNS configurado: `9.9.9.10`, `149.112.112.10`, `1.1.1.1`
- Blocklists adicionadas: AdGuard DNS filter + OISD Full
- DNS Rewrites criados:
  - `cloud.maiahub.com.br` → OCI_PUBLIC_IP
  - `adguard.maiahub.com.br` → OCI_PUBLIC_IP
  - `npm.maiahub.com.br` → OCI_PUBLIC_IP (pré-criado para Fase 3)
- Override DNS ativado no painel Tailscale (`100.120.15.48`, override global)
- `services/dns/config/AdGuardHome.yaml` commitado

### Problemas e soluções

#### Painel AdGuard inacessível via Tailscale (porta 3000)

A causa raiz foi uma interação não-óbvia entre o policy routing do Mullvad VPN e o DNAT do Docker.

Sequência do diagnóstico (3h de debugging):

1. UFW não tinha regra FORWARD para `tailscale0` → adicionado `ufw route allow in on tailscale0`
2. `DOCKER-USER` chain vazia → adicionado `iptables -I DOCKER-USER -i tailscale0 -j ACCEPT`
3. Mesmo com FORWARD aceito, pacotes chegavam em `tailscale0` mas nunca apareciam na bridge Docker — `tcpdump -i br-3f53f4cdd713` não capturava nada
4. O sistema usa nftables nativo (101 chains) com `iptables-nft` como camada de compatibilidade
5. O DNAT padrão do Docker (`fib daddr type local → DOCKER chain`) disparava para tráfego local da VM, mas para clientes externos via Tailscale o pacote era DNATado e depois roteado para a tabela 51820 (por causa da regra `iif tailscale0 lookup 51820`)
6. A tabela 51820 só tinha `default dev wg-mull-br` — sem rota para `172.18.0.0/16` (rede Docker) — então os pacotes DNATados iam para o Mullvad e desapareciam

**Solução final:**

Adicionar ip rule com prioridade superior à regra `iif tailscale0 lookup 51820` (prioridade 5209):

```bash
ip rule add to 172.16.0.0/12 lookup main priority 5200
```

Isso faz com que pacotes com destino a qualquer rede Docker (`172.16.0.0/12`) usem a tabela `main` — que tem as rotas para as bridges Docker — antes de chegar à regra da tabela 51820. Cobre todas as redes Docker presentes e futuras sem precisar conhecer o nome da bridge.

Persistência via systemd service (`tailscale-docker-forward.service`) que também adiciona a regra `DOCKER-USER ACCEPT` para `tailscale0`.

Ver [ADR-006](decisions/ADR-006-tailscale-docker-routing.md) para análise completa.

#### Wildcard DNS Rewrite substituído por entradas individuais

A configuração inicial usava `*.maiahub.com.br → OCI_IP` como wildcard, com regras `@@||blog.maiahub.com.br^` e `@@||clone-tabnews.maiahub.com.br^` no campo "Custom filtering rules" para excluir serviços na Vercel.

O problema: regras `@@` no AdGuard só desativam o pipeline de bloqueio de anúncios/trackers — elas não afetam o mecanismo de DNS Rewrite, que opera em camada separada e tem precedência. Resultado: `blog.maiahub.com.br` retornava o IP Oracle em vez do IP da Vercel.

**Solução aplicada:** wildcard removido, entradas individuais criadas para cada serviço hospedado na Oracle:

| Domain | Answer |
| --- | --- |
| `cloud.maiahub.com.br` | OCI_PUBLIC_IP |
| `adguard.maiahub.com.br` | OCI_PUBLIC_IP |

Serviços na Vercel (`blog`, `clone-tabnews`) não têm entrada — resolvem normalmente pelo upstream DNS. As regras `@@` foram removidas.

### Configurações criadas fora do repositório

| Onde | O que | Por quê |
| --- | --- | --- |
| `/etc/systemd/system/tailscale-docker-forward.service` | DOCKER-USER ACCEPT + ip rule priority 5200 | Persistência após reboot |
| UFW | `ufw route allow in on tailscale0` | FORWARD de tráfego Tailscale para containers |
| UFW | `allow from 100.64.0.0/10 to any port 3000` | Acesso ao painel AdGuard via Tailscale |

> Nota: o `tailscale-docker-forward.service` deve ser adicionado ao `provision.sh` para reproducibilidade — ver checklist da fase.

### Observação — DNS no Tailscale no Linux

O `cat /etc/resolv.conf` continua mostrando `127.0.0.53` (stub do systemd-resolved) mesmo após o override ativado. Isso é comportamento esperado: o Tailscale configura o systemd-resolved via D-Bus, não substitui o resolv.conf. A cadeia real é `app → 100.100.100.100 (MagicDNS Tailscale) → AdGuard`. Validação via `resolvectl status` (ver interface `tailscale0`) ou pelo resultado do `dig` sem `@`.

---

---

## 2026-05-11 — Fase 3: Nginx Proxy Manager

### O que foi feito

- Container NPM subido (`jc21/nginx-proxy-manager:latest`), portas 80/443/81
- Configuração inicial: conta admin criada, senha salva em `~/.homelab/secrets.env`
- Access List `tailscale-only` criada: allow `100.64.0.0/10`, deny all
- Certificados individuais emitidos via DNS Challenge (Cloudflare API):
  - `npm.maiahub.com.br`
  - `adguard.maiahub.com.br`
- Proxy hosts criados com SSL + Access List tailscale-only para ambos os domínios
- Porta 81 removida do `compose.yaml` do NPM após verificar acesso via proxy
- Porta 3000 removida do `compose.yaml` do AdGuard (mesma lógica — NPM faz o proxy)
- Regra UFW `allow from 100.64.0.0/10 to any port 3000` removida
- DNS Rewrites no AdGuard atualizados para IP Tailscale da VPS:
  - `npm.maiahub.com.br` → `{{OCI_TS_IP}}`
  - `adguard.maiahub.com.br` → `{{OCI_TS_IP}}`

### Desvio do plano: DNS split por nível de acesso

O plano original previa um wildcard `*.maiahub.com.br → {{OCI_PUBLIC_IP}}` para todos
os serviços. Ao testar o acesso sem exit node ativo, `https://npm.maiahub.com.br`
retornava 403 Forbidden: o DNS resolvia para o IP público, a requisição saía pela
internet real com o IP do dispositivo, e a Access List bloqueava corretamente.

**Solução:** domínios tailscale-only resolvem para `{{OCI_TS_IP}}` no AdGuard. Com isso,
a conexão flui dentro do Tailscale e o NPM vê o IP Tailscale do cliente — passando na
Access List sem precisar do exit node ativo. Serviços públicos continuarão com DNS para
`{{OCI_PUBLIC_IP}}`.

Decisão formalizada em [ADR-007](decisions/ADR-007-dns-split-tailscale-public.md).

### Padrão estabelecido para fases seguintes

Cada novo serviço segue este padrão:

1. Subir o container com seu `compose.yaml`
2. Criar DNS Rewrite no AdGuard:
   - Tailscale-only → `{{OCI_TS_IP}}`
   - Público → `{{OCI_PUBLIC_IP}}`
3. Emitir certificado individual via DNS Challenge no NPM
4. Criar proxy host com SSL + Access List (tailscale-only) ou sem Access List (público)
5. Commitar

### Configurações criadas fora do repositório

| Onde | O que |
| --- | --- |
| `~/.homelab/secrets.env` | Senha admin NPM |
| AdGuard DNS Rewrites | `npm.maiahub.com.br` e `adguard.maiahub.com.br` → `{{OCI_TS_IP}}` |

---

---

## 2026-05-18 — Fase 4: Gerenciamento e Monitoramento

### O que foi feito

- Portainer CE subido em `services/management/compose.yaml`
- Conta admin criada, ambiente `local` configurado (Docker socket montado)
- Stacks `dns` e `proxy` registradas no Portainer (repositório Git, sem Automatic Updates)
- Certificados SSL emitidos via DNS Challenge para `portainer.maiahub.com.br`, `monitoring.maiahub.com.br`, `netdata.maiahub.com.br`
- Proxy hosts criados no NPM com Access List `tailscale-only` para os três domínios
- Porta `9000` removida do compose do Portainer após proxy verificado
- `services/dns/compose.yaml` atualizado: IP fixo `172.18.0.2` para o container `adguard` via `ipv4_address`
- `services/monitoring/compose.yaml` atualizado: `dns: [172.18.0.2]` no Uptime Kuma para resolução de domínios internos via AdGuard
- Uptime Kuma e Netdata subidos em `services/monitoring/compose.yaml`
- Stack `monitoring` registrada no Portainer
- 8 monitores configurados no Uptime Kuma com notificação email e Telegram
- Netdata configurado com alertas por Telegram via `health_alarm_notify.conf` (`SEND_EMAIL="NO"`, `SEND_TELEGRAM="YES"`)
- Descoberto que Netdata não suporta SMTP direto — depende de `sendmail`; Telegram via API HTTP funciona sem MTA
- DNS Rewrites adicionados no AdGuard para os três novos serviços → `{{OCI_TS_IP}}`

### Desvio: monitors do Uptime Kuma via endereçamento Docker interno

O guia previa monitors HTTP(s) usando os domínios públicos (`https://npm.maiahub.com.br`, `https://adguard.maiahub.com.br`). Durante a configuração, todos os monitors mostraram status "down" com erros `ENOTFOUND` e `ETIMEOUT`.

**Diagnóstico:**

O Uptime Kuma roda como container na rede Docker `proxy`. Para resolver `npm.maiahub.com.br` via DNS, o container precisaria consultar o AdGuard — que também está na mesma rede `proxy`, com porta 53 publicada no host. O bloqueio acontece no **hairpin NAT do Docker**:

As regras de DNAT geradas pelo Docker para portas publicadas incluem `! -i <bridge>` — ou seja, o DNAT **não dispara** para tráfego que sai pela mesma bridge de onde veio. Isso afeta qualquer container que tente atingir outro container via o IP externo do host (Tailscale, público ou gateway da bridge), mesmo que ambos estejam na mesma rede.

Consequências práticas:
1. **DNS**: container tenta consultar AdGuard via `{{OCI_TS_IP}}:53`. O DNAT não dispara (`! -i br-proxy`). A query vai para `tailscale0` e desaparece → `ETIMEOUT`
2. **HTTP**: sem resolver DNS, não consegue conectar aos domínios `maiahub.com.br` → `ENOTFOUND`

Tentativas que não funcionaram:
- Adicionar subnet Docker (`172.18.0.0/16`) ao Access List do NPM — DNS já falhava antes de chegar ao NPM
- Usar o gateway da bridge (`172.18.0.1`) como DNS — mesma restrição `! -i br-proxy`
- Usar `{{OCI_TS_IP}}` como Resolver Server no monitor DNS — mesmo problema

**Solução aplicada:**

Como todos os serviços estão na mesma rede Docker `proxy`, o Uptime Kuma acessa os containers diretamente pelo nome ou IP interno — sem DNS externo, sem passar pelo NPM, sem hairpin NAT:

| Monitor | Tipo | Endereço usado | Motivo |
| --- | --- | --- | --- |
| NPM — HTTP :80 | TCP Port | `{{OCI_PUBLIC_IP}}:80` | Porta pública — sem Access List no nível TCP |
| NPM — HTTPS :443 | TCP Port | `{{OCI_PUBLIC_IP}}:443` | Idem |
| AdGuard DNS | DNS | Resolver = IP container `adguard` | Mesmo bridge, sem DNAT |
| AdGuard — painel | HTTP(s) | `http://adguard:3000` | Container name, mesma rede |
| NPM — painel | HTTP(s) | `http://npm:81` | Idem |
| Portainer | HTTP(s) | `http://portainer:9000` | Idem |
| Netdata | HTTP(s) | `http://netdata:19999` | Idem |
| Uptime Kuma | HTTP(s) | `http://uptime-kuma:3001` | Idem |

Para o monitor DNS do AdGuard: o campo `Resolver Server` usa o IP do container `adguard` na rede `proxy` (obtido via `docker inspect adguard --format '{{.NetworkSettings.Networks.proxy.IPAddress}}'`), não o IP Tailscale. Dentro da mesma bridge, o pacote vai direto ao container sem DNAT.

Ver [ADR-008](decisions/ADR-008-uptime-kuma-hairpin-nat.md) para análise completa.

### Configurações criadas fora do repositório

| Onde | O que |
| --- | --- |
| `~/.homelab/secrets.env` | Senhas admin do Portainer e do Uptime Kuma |
| AdGuard DNS Rewrites | `portainer.maiahub.com.br`, `monitoring.maiahub.com.br`, `netdata.maiahub.com.br` → `{{OCI_TS_IP}}` |
| Uptime Kuma | 8 monitores configurados; notificações email e Telegram |
| Netdata | `health_alarm_notify.conf`: `SEND_EMAIL="NO"`, `SEND_TELEGRAM="YES"` com bot Telegram |

---

- **Fase 2** ✅ — AdGuard Home: DNS privado com bloqueio de trackers
- **Fase 3** ✅ — Nginx Proxy Manager: proxy reverso com SSL e access lists
- **Fase 4** ✅ — Portainer + Uptime Kuma + Netdata: gerenciamento e monitoramento
- **Fase 5** — Nextcloud: migração dos dados da Hostinger
- **Fase 6** — Jellyfin + Arr Stack: servidor de mídia
- **Fase 7** — Dawarich: histórico de localização
- **Fase 8** — Backup: Restic + Rclone + Backblaze B2
- **Fase 9** — Corte final: cancelar Hostinger
