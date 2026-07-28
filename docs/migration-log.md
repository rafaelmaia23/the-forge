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

---

## 2026-06-11/12 — Fase 5: Nextcloud

### O que foi feito

- Stack completa subida com 8 containers: nextcloud, nextcloud-db, nextcloud-redis, nextcloud-collabora, nextcloud-elasticsearch, nextcloud-clamav, nextcloud-notify-push, nextcloud-imaginary
- Todos os volumes como bind mounts em `/mnt/data/nextcloud/` (block volume de 150 GB)
- Certificados SSL e proxy hosts criados no NPM para `cloud.maiahub.com.br` e `office.maiahub.com.br`
- DNS Rewrites no AdGuard para ambos os domínios → `{{OCI_PUBLIC_IP}}`
- Apps instalados via `occ app:install` (um por vez)
- notify_push configurado e funcionando (todos os checks do self-test passando)
- Parâmetros de kernel configurados: `vm.overcommit_memory=1` e `vm.max_map_count=262144`
- Janela de manutenção configurada para 6h UTC (3h horário de Brasília)

### Desvios do plano original

**1. Redis password deve ser hex puro**
O guia original usava `openssl rand -base64 32` para gerar a senha do Redis. Base64 inclui caracteres `+`, `/`, `=`, `&`, `#` que causam dois problemas:
- `#` no `.env` é interpretado como início de comentário — trunca o valor
- `&` e `#` em `tcp://host:6379?auth=PASSWORD` têm significado especial na URL — quebram o PHP session handler
Corrigido com `openssl rand -hex 32`. Guia atualizado.

**2. Elasticsearch tag `:9` não existe no Docker Hub**
O Docker Hub publica apenas tags de versão específicas para Elasticsearch 9 — não o alias de major version (`:9`). O registry oficial (`docker.elastic.co`) também requer versão específica. Corrigido com `elasticsearch:9.4.2`. Guia atualizado.

**3. ClamAV sem imagem ARM64 na variante Alpine**
`clamav/clamav:latest` é baseada em Alpine e não tem manifest ARM64. Corrigido com `clamav/clamav-debian:latest` (multi-arch). Guia atualizado.

**4. PostgreSQL 18 mudou o caminho do volume de dados**
PostgreSQL 17 esperava mount em `/var/lib/postgresql/data`. PostgreSQL 18 mudou para `/var/lib/postgresql` (um nível acima). Mount point corrigido no compose.yaml. Guia atualizado.

**5. `custom_apps` precisou de bind mount separado**
Apps instalados via `occ app:install` vão para `/var/www/html/custom_apps` (o `apps_path` writable do Nextcloud), não para `/var/www/html/apps`. O compose.yaml original não tinha bind mount para esse diretório. Consequência: ao fazer `docker compose up -d --force-recreate` para aplicar nova env var, todos os apps instalados via occ foram perdidos e precisaram ser reinstalados.
Corrigido: adicionado `custom_apps` como bind mount no compose.yaml; dono deve ser `33:33` (www-data). Guia atualizado.

**6. NPM Custom Locations causa falha silenciosa na geração do .conf**
Ao adicionar uma Custom Location (via aba "Custom Locations" da UI **ou** via bloco `location {}` no Advanced config), o NPM falha silenciosamente ao gerar o `.conf` do proxy host — o arquivo desaparece. O nginx test falha internamente mas o NPM exibe "salvo com sucesso". Investigação via `docker exec npm ls /data/nginx/proxy_host/`.
Workaround: usar `/data/nginx/custom/server_proxy.conf` que já é incluído (como include opcional) em todos os server blocks pelo template do NPM. Guia atualizado.

**7. `/push` precisa de rewrite para remover prefixo antes de encaminhar**
O binário `nextcloud-notify-push` serve rotas na raiz (ex: `/test/cookie`, `/ws`). O nginx estava encaminhando `/push/test/cookie` como `/push/test/cookie` ao binário, que retornava 404. Corrigido com `rewrite ^/push/?(.*)$ /$1 break;` no `server_proxy.conf`.

**8. Hairpin NAT para `notify_push:setup`**
`occ notify_push:setup` faz requisição HTTP ao próprio domínio público (`cloud.maiahub.com.br`) para testar o push server. O container `nextcloud` não consegue resolver/alcançar o próprio domínio público pela mesma limitação de hairpin NAT documentada em ADR-008.
Corrigido com `extra_hosts` no compose.yaml apontando `cloud.maiahub.com.br` para o IP interno do NPM na rede `proxy`. O IP do NPM pode mudar — verificar com `docker inspect npm --format '{{(index .NetworkSettings.Networks "proxy").IPAddress}}'`.

**9. `nextcloud` precisou ser adicionado aos trusted_domains**
O binário `nextcloud-notify-push` conecta ao Nextcloud via `NEXTCLOUD_URL=http://nextcloud`. O hostname `nextcloud` não estava nos `trusted_domains` do Nextcloud, causando rejeição da conexão.
Corrigido: `occ config:system:set trusted_domains 2 --value=nextcloud`.

### Problemas encontrados e soluções

**`docker compose restart` não recarrega variáveis do `.env`**
`docker compose restart` apenas para e reinicia o mesmo container — env vars ficam com os valores da criação original. Para aplicar novo valor de env var, é necessário `docker compose up -d --force-recreate <container>`. A distinção é crítica: ao trocar a senha do Redis no `.env`, o restart deixou o container rodando com a senha antiga na env var e no PHP session ini, enquanto o Redis já tinha a senha nova.

**PHP session handler armazena senha do Redis separado do `config.php`**
`occ config:system:set redis password` atualiza apenas o array `redis` em `config.php`. O PHP session handler usa `session.save_path` configurado em um arquivo `.ini` pelo entrypoint da imagem — armazenado separadamente. Apenas o `force-recreate` (que re-executa o entrypoint com a nova env var) atualiza o session ini.

**Elasticsearch — permissões no diretório de dados**
Diretório criado com `sudo mkdir` fica com dono `root:root`. O Elasticsearch roda como UID 1000 e falha ao criar o lock file.
Solução: `sudo chown -R 1000:1000 /mnt/data/nextcloud/elasticsearch`

**Segfaults do Apache durante instalação em massa de apps via UI**
Instalar múltiplos apps simultaneamente pelo browser causou crash em loop nos workers Apache (SIGSEGV). O container permanecia "Up" mas todos os workers travavam → 502.
Solução: instalar apps um a um via `occ app:install <app>`. Se ocorrer: `docker compose restart nextcloud` recupera o container.

**`custom_apps` perdido após force-recreate**
Ao adicionar o bind mount `custom_apps` sem primeiro copiar o conteúdo existente do container, todos os apps instalados foram perdidos. O processo correto:
1. `docker cp nextcloud:/var/www/html/custom_apps/. /mnt/data/nextcloud/custom_apps/` antes do force-recreate
2. `sudo chown -R 33:33 /mnt/data/nextcloud/custom_apps/` após criar o diretório
3. Se perdido: reinstalar todos via `occ app:install`

**`occ notify_push:setup` precisa da URL completa do push server**
O comando recebe a URL do push server (não a URL base do Nextcloud). Usar `https://cloud.maiahub.com.br` testa `cloud.maiahub.com.br/test/cookie` no próprio Nextcloud (404). O correto é `https://cloud.maiahub.com.br/push`.

### Configurações criadas fora do repositório

| Onde | O que | Por quê |
| --- | --- | --- |
| `/data/nginx/custom/server_proxy.conf` (container `npm`) | `location /push` com rewrite + proxy WebSocket para `nextcloud-notify-push:7867` | Bug NPM: custom locations causam falha silenciosa no .conf |
| `/mnt/data/nextcloud/elasticsearch` | `chown -R 1000:1000` | ES roda como UID 1000, diretório criado como root |
| `/etc/sysctl.conf` | `vm.overcommit_memory=1` e `vm.max_map_count=262144` | Redis e Elasticsearch requerem esses parâmetros |
| `~/.homelab/secrets.env` | Senhas do Nextcloud (postgres, redis, admin) | Segredos fora do repo |
| AdGuard DNS Rewrites | `cloud.maiahub.com.br` e `office.maiahub.com.br` → `{{OCI_PUBLIC_IP}}` | Serviços públicos |

---

## 2026-06-12 — Fase 5 (continuação): Configurações pós-stack e integrações

### O que foi feito

- **Background jobs:** modo trocado de Ajax para Cron. Cron job adicionado no host: `*/5 * * * * docker exec -u www-data nextcloud php -f /var/www/html/cron.php`
- **maintenance_window_start:** configurado via `occ config:system:set maintenance_window_start --value=6 --type=integer` (3h horário de Brasília)
- **Mimetype migrations:** executado `occ maintenance:repair --include-expensive`
- **ClamAV (Etapa 9.3):** configurado no modo daemon via occ (`av_mode=daemon`, `av_host=nextcloud-clamav`, `av_port=3310`)
- **Collabora (Etapa 9.1):** configurado via admin UI. Dois problemas encontrados e resolvidos (ver Desvios)
- **Elasticsearch FTS (Etapa 9.2):** configurado via admin UI + índice construído com `occ fulltextsearch:index`
- **Imaginary (Etapa 9.4/9.5):** configurado via occ (`enabledPreviewProviders` + `preview_imaginary_url`)
- **Importação de dados:** contatos importados. Calendários parcialmente importados (bloqueio por rate limit — ver Desvios)

### Desvios e problemas

**Collabora — hairpin NAT duplo**
O container `nextcloud` não conseguia resolver `office.maiahub.com.br` para validar o servidor Collabora (hairpin NAT). Solução: adicionar `office.maiahub.com.br:172.18.0.3` ao `extra_hosts` do serviço `nextcloud`. O container `nextcloud-collabora` também não conseguia alcançar `cloud.maiahub.com.br` para fazer requisições WOPI. Solução: adicionar `cloud.maiahub.com.br:172.18.0.3` ao `extra_hosts` do `nextcloud-collabora`.

**wopi_allowlist**
Sem o `wopi_allowlist` configurado, Collabora recebia "Unauthorized WOPI host" ao abrir documentos. Solução: `occ config:app:set richdocuments wopi_allowlist --value="172.16.0.0/12"`.

**Portainer quebrou o Redis**
Ao registrar a stack `cloud` no Portainer, ele reimplantou a stack sem ler o `.env` local, fazendo `REDIS_HOST_PASSWORD` ficar vazio. Redis entrou em crash loop com "wrong number of arguments for requirepass". Solução: `docker compose up -d --force-recreate nextcloud-redis` a partir do diretório com o `.env`. Portainer deve ser usado apenas no modo "external stack" (visibilidade sem controle de deploy).

**CalDAV rate limit na importação de calendários**
Ao importar múltiplos calendários/.ics, o app `dav` bloqueou com "Too many calendars created" após 10 criações. O rate limit é configurado via app config do app `dav` (não system config):
- Chave: `rateLimitCalendarCreation` (limite, padrão: 10)
- Período: `rateLimitPeriodCalendarCreation` (segundos, padrão: 3600)
- Backend: `MemoryCacheBackend` usando Redis como distributed cache
- Contadores ficam em chaves Redis com padrão `*RateLimiting*`

Tentativas de aumentar o limite via system config foram ineficazes (chave errada). A chave correta é app config do `dav`. Para migração futura: `occ config:app:set dav rateLimitCalendarCreation --value=100` antes de importar.

**NUNCA modificar `RateLimitingPlugin.php` diretamente**
Tentativas de patch do arquivo PHP (via sed e via str_replace) causaram parse errors que quebraram o DAV inteiro. O arquivo fica no bind mount `/mnt/data/nextcloud/apps/` e qualquer modificação persiste. Para restaurar: `docker exec nextcloud cp /var/www/html/apps/dav/lib/CalDAV/Security/RateLimitingPlugin.php.bak /var/www/html/apps/dav/lib/CalDAV/Security/RateLimitingPlugin.php` + `docker compose up -d --force-recreate nextcloud`.

### Pendente

- Importar 3 arquivos .ics restantes (2 task lists + 1 calendário) após expirar rate limit
- Migrar 7 GB de arquivos do PC local para a VM via rsync
- Configurar DAVx⁵ no Android + app Nextcloud mobile
- Adicionar monitores no Uptime Kuma (Nextcloud + Collabora)
- Registrar stack `cloud` no Portainer como external stack
- Commit e tag `v1.4-nextcloud`

---

## 2026-07-09/16 — Incidente: apagão de DNS/rede e corrida de boot Mullvad × Tailscale

### O que aconteceu (2026-07-09, não documentado na hora)

A internet parou de funcionar em todos os aparelhos que usam a VPS como exit node/DNS via Tailscale. Investigação na hora revelou:

1. Um processo de atualização automática (`apt-get`/`unattended-upgrade`) estava travado desde maio, segurando o lock do `dpkg`.
2. O container `adguard` tinha IP fixo (`172.18.0.2` via `ipv4_address`, ver ADR-008) e não conseguiu subir com `docker compose up` — outro container (`uptime-kuma`) havia ocupado esse IP dinamicamente enquanto o `adguard` estava fora do ar, e o Docker recusou recriar o `adguard` com um IP já em uso.
3. Correção emergencial: removida a linha `ipv4_address: 172.18.0.2` do `services/dns/compose.yaml` — o `adguard` subiu, DNS voltou.
4. O processo de `apt-get` preso foi morto manualmente pelo PID; outro ciclo de atualização automática rodou sozinho em seguida; foi feita atualização manual adicional e a VPS foi reiniciada.
5. Após o reboot, os containers Docker subiram sozinhos normalmente, mas a internet dos aparelhos Tailscale continuou fora do ar — o túnel Mullvad (`wg-mull-br`) não havia subido. Reativado manualmente (`sudo wg-quick up wg-mull-br`), internet voltou.

### O que aconteceu (2026-07-16, hoje)

Painéis `uptimekuma.maiahub.com.br`, `adguard.maiahub.com.br` e `npm.maiahub.com.br` pararam de abrir via Tailscale (Firefox: "endereço não pode ser alcançado"; Brave: "DNS não pode ser consultado"), mesmo com a rede Tailscale up e os containers saudáveis.

### Causa raiz

**1. Colisão de IP `172.18.0.2` (AdGuard ↔ Portainer)**
A remoção emergencial do `ipv4_address` do AdGuard (passo 3 acima) nunca foi revertida nem documentada. Na recriação seguinte dos containers, o Docker atribuiu IPs dinâmicos em ordem arbitrária: `adguard=172.18.0.5`, `npm=172.18.0.6`, `uptime-kuma=172.18.0.7`, e **`portainer` ficou com `172.18.0.2`** — o IP antigo do AdGuard, o mesmo hardcoded em `dns: [172.18.0.2]` no `services/monitoring/compose.yaml` (ADR-008). Isso quebrou o monitor de DNS interno do Uptime Kuma (apontando para o Portainer, não mais para o AdGuard). **Não foi a causa do apagão de painéis de hoje** — auditoria ao vivo confirmou o AdGuard respondendo corretamente a todos os DNS Rewrites e o DNAT do Docker já apontando para os IPs atuais.

**2. Corrida de boot entre `wg-quick@wg-mull-br.service` e `tailscaled.service`**
Confirmado via `journalctl -b`: no boot, o `wg-quick@wg-mull-br` tentava rodar antes da interface `tailscale0` existir (`Cannot find device "tailscale0"`), abortava e se autodestruía (`ip link delete dev wg-mull-br`), ficando em estado `failed` sem retry. A unidade só tinha `After=network-online.target nss-lookup.target` — nenhuma dependência de `tailscaled.service`. Essa é a causa raiz real do "Mullvad caiu depois do reboot" do incidente de 09/07, e ia se repetir em todo reboot futuro.

**3. Causa real do apagão de painéis de hoje: prioridade da `ip rule` do ADR-006 ficou obsoleta**
Auditoria inicial do lado da VPS não encontrou nada quebrado isoladamente (AdGuard saudável, rewrites corretos, DNAT do Docker correto, `DOCKER-USER -i tailscale0 ACCEPT` presente, UFW correto, túnel Mullvad up). A hipótese inicial (DNS-over-HTTPS no navegador) foi descartada quando o usuário confirmou que o problema ocorria em **todos** os dispositivos Tailscale (PC e celular), não só num navegador/máquina.

Captura de pacotes (`tcpdump -i any port 53`) revelou a causa real: pacotes de clientes Tailscale reais, destinados ao AdGuard (`172.18.0.2:53`), estavam saindo pela interface `wg-mull-br` — com IP de origem mascarado para `10.69.63.119` (endereço interno do túnel Mullvad) — em vez de irem direto para a bridge Docker. A regra interna do Tailscale (`iif tailscale0 lookup 51820`) está, nesta versão do `tailscaled` (1.98.8), na prioridade **5199** — não mais 5209 como documentado originalmente no ADR-006. Como isso é *menor* que a prioridade 5200 da nossa regra, a regra do Tailscale passou a ser avaliada primeiro, encontrava a rota `default dev wg-mull-br` (catch-all) na tabela 51820 e parava aí — nossa regra 5200 nunca era alcançada. Todo tráfego Tailscale→Docker (não só DNS) estava sendo desviado pelo túnel Mullvad, com todos os clientes aparecendo para o AdGuard como uma única origem mascarada — o que explica a falha ser intermitente, não 100% consistente. Ver detalhes completos na atualização do ADR-006.

### Correções aplicadas

1. **IP do AdGuard restaurado**: `ipv4_address: 172.18.0.2` de volta em `services/dns/compose.yaml`. Sequência: `docker compose down` no `dns` e no `management`, subiu `adguard` primeiro (reclamou `172.18.0.2`), depois `portainer` (recebeu outro IP dinâmico). Confirmado via `docker inspect adguard --format '{{(index .NetworkSettings.Networks "proxy").IPAddress}}'` → `172.18.0.2`. O `dns: [172.18.0.2]` do Uptime Kuma voltou a funcionar sem precisar recriar o container (o `/etc/resolv.conf` interno já apontava para esse IP, que agora é válido de novo).
2. **Boot order fix**: drop-in systemd em `/etc/systemd/system/wg-quick@wg-mull-br.service.d/override.conf` adicionando `After=tailscaled.service` + `Requires=tailscaled.service`, e um `ExecStartPre` que espera a interface `tailscale0` existir (timeout 30s) antes do `wg-quick` rodar. **Validado com reboot real** — no boot seguinte o `wg-quick@wg-mull-br` subiu limpo, sem a corrida. Ver ADR-010.
3. **Gotcha operacional descoberto durante a validação**: rodar `wg-quick up`/`wg-quick down` manualmente (fora do `systemctl`) enquanto o túnel já está ativo pode deixar rotas órfãs na tabela `51820` (a rota `100.64.0.0/10 dev tailscale0` não é removida automaticamente se a interface associada já tiver sido removida por outro caminho), bloqueando o próximo `up` com `RTNETLINK answers: File exists`. O RUNBOOK já tinha o procedimento de limpeza correto na seção "Trocar de servidor" — reforçado como passo obrigatório também para reinícios do mesmo servidor, não só troca.
4. **Prioridade da `ip rule` do ADR-006 corrigida**: de `5200` para **`100`** (bem abaixo de toda a faixa 5199–5270 usada pelo Tailscale), tanto ao vivo quanto no `ExecStart` persistido de `tailscale-docker-forward.service`. Validado com `tcpdump`: tráfego Tailscale→Docker passou a ir direto pela bridge, sem tocar `wg-mull-br`, e os painéis voltaram a abrir normalmente em todos os dispositivos. Ver atualização do ADR-006.

### Estado final (2026-07-16, pós-correção, tudo validado ao vivo)

| Item | Estado |
| --- | --- |
| `adguard` | `172.18.0.2` (fixo), respondendo corretamente a todos os DNS Rewrites |
| `services/dns/compose.yaml` | Idêntico ao HEAD do git — `ipv4_address: 172.18.0.2` restaurado |
| `ip rule` | `100: to 172.16.0.0/12 lookup main` (antes 5200) — abaixo de toda a faixa do Tailscale (5199–5270) |
| `ip route table 51820` | `default dev wg-mull-br` + `100.64.0.0/10 dev tailscale0` — sem duplicatas |
| `tailscale-docker-forward.service` | `active`, `ExecStart` usa `priority 100` |
| `wg-quick@wg-mull-br.service` | `active`, drop-in de boot-order aplicado (ADR-010), túnel com handshake recente |
| `DOCKER-USER` | `ACCEPT` para `tailscale0`, contadores de pacotes crescendo (tráfego real) |
| Painéis (`adguard`/`npm`/`portainer`/`uptimekuma`/`netdata`) | Confirmado funcionando via Tailscale em múltiplos dispositivos (PC e celular) |
| `querylog.json` do AdGuard | Parou de ser escrito em disco desde a última recriação do container (~20:25) — log em memória/tempo real continua funcionando (queries respondidas normalmente), mas a persistência em disco ficou travada; não investigado a fundo, não afeta a resolução de DNS em si |

---

## 2026-07-17 — Incidente: recorrência do apagão de painéis — causa raiz real corrigida

### O que aconteceu

Menos de 24h depois da correção documentada acima (2026-07-16, prioridade
`5200 → 100`), o mesmo sintoma voltou: NPM e os demais painéis internos
(`*.maiahub.com.br` tailscale-only) pararam de abrir via Tailscale, em todos
os dispositivos da rede — idêntico ao incidente anterior.

### Causa raiz (a de 07-16 estava mal diagnosticada)

`ip rule list` mostrou a regra `iif tailscale0 lookup 51820` agora em
**priority 99** (não 5199 como no dia anterior), de novo acima da nossa regra
(100), reabrindo o desvio do tráfego Tailscale→Docker pelo túnel `wg-mull-br`.

A causa atribuída em 07-16 — "prioridade interna do Tailscale muda entre
versões" — **estava errada**. Essa regra nunca foi gerenciada pelo Tailscale:
é criada pelo nosso próprio `PostUp` em `/etc/wireguard/wg-mull-br.conf`
(existente desde a Fase 1), sem `priority` explícita:

```
PostUp = ip rule add iif tailscale0 table 51820
```

Sem prioridade fixa, o `iproute2` atribui um valor arbitrário toda vez que o
`wg-quick` sobe o túnel — por isso a regra apareceu em 5209 (maio), 5199
(07-16) e 99 (07-17). O gatilho de hoje: o `tailscaled` fez auto-update em
background (1.98.8 → 1.98.9, sem reboot da VM) e reiniciou seu serviço. O
drop-in do ADR-010 (`Requires=tailscaled.service` em
`wg-quick@wg-mull-br.service`) propaga esse reinício para o `wg-quick`, que
roda o `PostUp` de novo e recria a regra em outra posição arbitrária — uma
correção pensada para o problema de boot (ADR-010) virou gatilho de
recorrência para o bug do ADR-006.

### Correções aplicadas

1. **Prioridade fixada na origem**: `wg-mull-br.conf` agora fixa
   `priority 20000` na regra `iif tailscale0`, tanto no `PostUp` quanto no
   `PostDown`.
2. **PostUp/PostDown tornados idempotentes**: as linhas de `ip rule` e `ip
   route` agora fazem `del ... 2>/dev/null || true` antes do `add` — o
   `|| true` é necessário porque `2>/dev/null` sozinho só silencia a
   mensagem, não zera o exit code, e o `wg-quick` roda com `set -e` (uma
   falha no `del` abortava o script inteiro antes de chegar no `add`,
   descoberto durante a validação de hoje).
3. **Self-healing em `tailscale-docker-forward.service`**: `ExecStart`
   trocado por `/usr/local/sbin/tailscale-docker-forward.sh`, que descobre a
   prioridade viva da regra `iif tailscale0` (via `ip rule list`, que sempre
   imprime `lookup`, nunca `table`) e instala a nossa regra uma posição
   abaixo, com fallback para 100. Serviço ganhou
   `PartOf=wg-quick@wg-mull-br.service` — reinicia automaticamente sempre
   que o túnel Mullvad reiniciar, reaplicando a prioridade correta sem
   intervenção manual.
4. Detalhes completos e justificativa em ADR-006 (atualização 2026-07-17) e
   ADR-010 (nota 2026-07-17).

### Estado final (2026-07-17, pós-correção, validado ao vivo)

| Item | Estado |
| --- | --- |
| `ip rule` — `iif tailscale0 lookup 51820` | `priority 20000`, fixa em `wg-mull-br.conf` |
| `ip rule` — `to 172.16.0.0/12 lookup main` | `priority 19999` (autocalculada, 1 abaixo da de cima) |
| `/etc/wireguard/wg-mull-br.conf` | `PostUp`/`PostDown` idempotentes, priority fixa |
| `tailscale-docker-forward.service` | `ExecStart` aponta pro script self-healing; `PartOf=wg-quick@wg-mull-br.service` |
| `/usr/local/sbin/tailscale-docker-forward.sh` | criado, `chmod 755` |
| Validação | `systemctl restart wg-quick@wg-mull-br.service` (simulando o auto-update de hoje) disparou o restart automático de `tailscale-docker-forward.service` via `PartOf`, que recalculou e reinstalou a regra corretamente — sem intervenção manual |
| DNS | `dig` contra `172.18.0.2` resolvendo todos os rewrites corretamente após o teste |
| `DOCKER-USER` | `ACCEPT` para `tailscale0` presente |
| Painéis | Confirmado funcionando novamente |

---

## 2026-07-28 — Incidente: três falhas simultâneas e reconstrução da resiliência

### Sintoma relatado

Internet fora no celular e no PC. Sair da rede Tailscale devolvia a internet nos
dois. Painéis privados inacessíveis. Tentativa de operar o servidor por SSH
falhou, "como se o servidor estivesse sem acesso à internet".

### As três falhas

**1. Túnel Mullvad sem peer — causa da internet fora nos dispositivos**

`wg show` mostrava a interface no ar, escutando, **sem nenhum peer** e sem
handshake. O `/etc/wireguard/wg-mull-br.conf` tinha zero blocos `[Peer]`. Como a
tabela 51820 mantém `default dev wg-mull-br`, todo tráfego de exit node caía num
buraco negro.

Origem: o backup `wg-mull-br.conf.bak-20260717` (17:32) tem o bloco; o arquivo
vivo (17:36) não. O `[Peer]` foi comido numa edição durante a sessão de correção
do ADR-006 em 17/07. Como o `wg-quick` só lê o `.conf` no `up`, a interface
seguiu **11 dias** rodando com o peer carregado no kernel. O reboot de hoje às
15:03 (kernel `6.17.0-1018` → `-1019`, `unattended-upgrade`) foi a primeira
releitura do arquivo quebrado.

**2. AdGuard não subiu após o reboot — causa do DNS morto**

No boot, o `portainer` pegou o `172.18.0.2` e o `pet-oasis-app` pegou o
`172.18.0.3`. O `adguard`, que exige o `.2`, ficou `Exited (255)`. Repetição
literal de 2026-07-09. E o `.3` sendo do `pet-oasis` significa que o
`extra_hosts` do `nextcloud` e do `nextcloud-collabora` apontava
`cloud.maiahub.com.br` e `office.maiahub.com.br` para o container errado —
Collabora quebrado silenciosamente.

Antes disso, às 00:45, os logs do AdGuard já mostravam todos os upstreams DoH em
timeout — o container estava `Up` e saudável para o Docker enquanto nenhuma
query resolvia.

**3. Dependência circular de DNS — causa do "servidor sem internet"**

O `/etc/resolv.conf` da VPS apontava para `100.100.100.100` (MagicDNS) → AdGuard
→ container na própria VPS. Com o AdGuard fora, o servidor perdia resolução de
nomes. Confirmado ao vivo: `curl https://1.1.1.1` respondia `301` na hora,
`getent hosts doh.mullvad.net` não resolvia nada. O servidor tinha internet; não
tinha DNS.

### Correções aplicadas

| # | Correção | Onde |
| --- | --- | --- |
| 1 | `[Peer]` restaurado por merge do `.bak` no arquivo vivo (preservando as correções de idempotência de 17/07) | `wg-mull-br.conf` |
| 2 | Rede `proxy` recriada com `--ip-range 172.18.128.0/17`; IPs fixos para `adguard` (.2), `npm` (.3) e `uptime-kuma` (.4) | ADR-011 |
| 3 | `resolv.conf` estático na VPS + `tailscale set --accept-dns=false` no servidor | ADR-012 |
| 4 | Fallback `9.9.9.9` no `dns:` do Uptime Kuma — o alerta não saía porque ele não resolvia o endpoint do Telegram | ADR-012 |
| 5 | Volume nomeado para `/var/www/html` do Nextcloud | ADR-013 |
| 6 | Watchdogs de DNS, túnel e reconciliação de boot + `Restart=on-failure` no `wg-quick` | ADR-014 |
| 7 | `ip route replace` e `iptables -C` antes de `-A` no `wg-mull-br.conf` | ADR-014 |
| 8 | `tailscale set --snat-subnet-routes=false` | ver abaixo |

### Desvios e descobertas durante a execução

**O `compose down` derrubou o Nextcloud (e não era culpa da rede)**
`/var/www/html` era volume anônimo; o container novo subiu vazio e o entrypoint
entrou em loop de `maintenance:install`. Dados intactos o tempo todo. Ver
ADR-013.

**Painéis com 403 depois de religar o `--accept-dns=true`**
O log do NPM mostrava `[Client 172.18.0.1]` — o gateway da bridge, não o IP
Tailscale. Causa: `ts-forward` marca com `0x40000` todo pacote que o Tailscale
forwarda, e `ts-postrouting` mascara por essa marca. O DNAT do Docker é o que
transforma a conexão em "forwardada", então o IP real do cliente se perdia e a
Access List (`allow 100.64.0.0/10`) barrava.

Corrigido com `tailscale set --snat-subnet-routes=false`. O Tailscale avisa que
isso pode quebrar o exit node — **não se aplica aqui**: o `PostUp` do
`wg-mull-br.conf` já instala `-s 100.64.0.0/10 -o wg-mull-br -j MASQUERADE`, e o
modo de failover instala o equivalente para a `enp0s6`. O `ts-postrouting` era
redundante para esse caminho. A rota de volta existe na tabela 52
(`100.92.109.14 dev tailscale0`, regra prio 5270). Validado: `Client
100.92.109.14`, HTTP 200.

**O failover impedia o túnel de voltar**
Encontrado em ensaio, não em produção. A rota de failover ocupa o mesmo
`default` da tabela 51820 que o `PostUp` do `wg-quick` instalava com `ip route
add` — o `wg-quick` abortava com `RTNETLINK answers: File exists` e apagava a
interface recém-criada. A rede de segurança prendia o sistema no estado
degradado que deveria ser temporário. Ver ADR-014.

**A interface WireGuard sobrevive no kernel sem o `.conf`**
Descoberto ao errar o roteiro do ensaio: mover o `.conf` antes do `stop` faz o
`wg-quick down` falhar (`does not exist`), e a interface e o peer continuam
vivos. É exatamente o mecanismo que manteve o bug do `[Peer]` latente por 11
dias.

### Validações finais

| Item | Resultado |
| --- | --- |
| Túnel Mullvad | handshake ativo, saída `br-sao-wg-201`, `mullvad_exit_ip: true` |
| Saída direta do host | Oracle, fora do túnel — correto conforme ADR-005 |
| IPs da rede `proxy` | `adguard` .2, `npm` .3, `uptime-kuma` .4; dinâmicos a partir de `.128.x` |
| Nextcloud | `installed: true`, `maintenance: false`, HTTP 200; `--force-recreate` sem loop |
| `notify_push:self-test` | 6/6 |
| Collabora | `office.maiahub.com.br` HTTP 200, `/etc/hosts` apontando para o NPM real |
| Painéis via Tailscale | HTTP 200, `Client 100.92.109.14` |
| Ensaio de failover | degradou no ciclo 2, recuperou sozinho no ciclo 5 |
| Entrega de alerta | com `adguard` parado, `uptime-kuma` resolveu `api.telegram.org` pelo fallback |

### Pendente

- Reboot real para validar o `homelab-stacks-boot.service` de ponta a ponta
- Versionar as customizações do `wg-mull-br.conf` (hoje fora do repositório)

---

- **Fase 2** ✅ — AdGuard Home: DNS privado com bloqueio de trackers
- **Fase 3** ✅ — Nginx Proxy Manager: proxy reverso com SSL e access lists
- **Fase 4** ✅ — Portainer + Uptime Kuma + Netdata: gerenciamento e monitoramento
- **Fase 5** ✅ — Nextcloud: cloud pessoal com stack completa
- **Fase 6** — Jellyfin + Arr Stack: servidor de mídia
- **Fase 7** — Dawarich: histórico de localização
- **Fase 8** — Backup: Restic + Rclone + Backblaze B2
- **Fase 9** — Corte final: cancelar Hostinger
