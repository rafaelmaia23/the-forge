# Fase 4 — Gerenciamento e Monitoramento

## Guia de Execução Completo

**Projeto:** Homelab
**Fase:** 4 de 9
**Objetivo:** Visibilidade operacional completa — gerenciamento visual de stacks e containers, monitoramento de uptime com alertas, e métricas de sistema em tempo real
**Tempo estimado:** 1,5–2,5 horas
**Pré-requisito:** Fase 3 concluída — NPM no ar, Access List `tailscale-only` criada, padrão DNS/certificado/proxy host estabelecido

---

## O que esta fase entrega

Ao final desta fase:

- **Portainer CE** rodando em `portainer.maiahub.com.br` — gerencia todos os containers do host e todas as stacks registradas a partir do repositório Git
- **Uptime Kuma** rodando em `monitoring.maiahub.com.br` — monitora disponibilidade dos serviços ativos e envia alertas por email
- **Netdata** rodando em `netdata.maiahub.com.br` — métricas em tempo real de CPU, RAM, disco, rede e containers, com alertas de sistema configurados
- Stacks `dns` e `proxy` registradas no Portainer (visão unificada de todos os serviços)
- Porta 9000 removida do compose Portainer após proxy verificado

---

## Decisões arquiteturais desta fase

| Decisão | Escolha | Motivo |
| --- | --- | --- |
| Portainer porta interna | `9000` HTTP | Consistente com todos os outros serviços (:3000, :3001, :81) — NPM faz HTTPS na borda |
| Portainer acesso inicial | Porta 9000 temporária no compose | Mesmo padrão da porta 81 do NPM na Fase 3; removida após proxy verificado |
| Portainer stacks | Registradas a partir do repositório Git | Permite update das stacks pelo painel sem SSH; Git continua sendo a fonte da verdade |
| Netdata modo | Standalone (local) | Zero dependência externa; métricas não saem da VM; 1h de alta resolução cobre o caso de uso principal |
| Netdata alertas | Configurados via `health_alarm_notify.conf` | Complementa o Uptime Kuma: Kuma monitora disponibilidade HTTP/DNS, Netdata monitora recursos de sistema |
| Uptime Kuma + Netdata | Um único `compose.yaml` em `services/monitoring/` | Ambos são serviços de monitoramento sem interdependência que exija isolamento |
| Notificações Uptime Kuma | Email SMTP | Universal, sem dependência de serviços de terceiros para alertas |
| Certificados | Um por serviço via DNS Challenge | Padrão estabelecido na Fase 3 — consistência em todo o homelab |

---

## Por que o Portainer vê todos os containers

O Portainer acessa o Docker através do socket Unix (`/var/run/docker.sock`). Isso lhe dá visibilidade e controle total sobre todos os containers do host, independente de como foram iniciados — seja por `docker compose up`, por outros projetos, ou manualmente.

**O que você pode fazer em qualquer container (sem SSH):**
- Ver logs em tempo real
- Reiniciar, parar, pausar
- Abrir terminal (`exec`) diretamente no browser
- Ver uso de CPU e memória por container
- Inspecionar configuração e variáveis de ambiente

**Stacks vs. Containers individuais:**

Containers iniciados fora do Portainer aparecem na aba **Containers** com todas as operações disponíveis. Para ter a visão de **Stack** (agrupa os containers de um mesmo compose, permite "update from Git"), o Portainer precisa que a stack seja registrada nele — o que fazemos na Etapa 2.

---

## Por que Netdata complementa o Uptime Kuma

| O que monitora | Uptime Kuma | Netdata |
| --- | --- | --- |
| Serviço respondendo HTTP/HTTPS | ✅ | ❌ |
| Porta TCP aberta | ✅ | ❌ |
| Resolução DNS | ✅ | ❌ |
| CPU do servidor | ❌ | ✅ |
| RAM disponível | ❌ | ✅ |
| Espaço em disco | ❌ | ✅ |
| I/O de disco | ❌ | ✅ |
| Métricas por container Docker | ❌ | ✅ |

Uptime Kuma alerta quando um serviço fica fora do ar. Netdata alerta antes — quando os recursos estão chegando no limite e o problema está por vir.

---

## Etapa 1 — Preparar a estrutura na máquina local

> Faça esta etapa na sua **máquina local**.

### 1.1 — Criar o compose.yaml do Portainer

```bash
mkdir -p ~/projetos/the-forge/services/management

cat > ~/projetos/the-forge/services/management/compose.yaml << 'EOF'
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      - "9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    networks:
      - proxy

networks:
  proxy:
    external: true
EOF
```

**Por que a porta 9000 está aqui inicialmente:**

Necessária para o primeiro acesso ao painel antes de criar o proxy host — o mesmo padrão da porta 81 do NPM na Fase 3. Será removida na Etapa 5 após o proxy estar verificado.

**Por que montar o Docker socket:**

O Portainer precisa do socket para interagir com o Docker daemon do host — listar containers, ver logs, reiniciar serviços, fazer deploy de stacks. Sem ele, o Portainer funciona mas não vê nada.

### 1.2 — Criar o .gitignore do Portainer

```bash
cat > ~/projetos/the-forge/services/management/.gitignore << 'EOF'
# Dados de runtime do Portainer (banco de dados interno, configurações)
data/
EOF
```

### 1.3 — Criar o compose.yaml de monitoramento

```bash
mkdir -p ~/projetos/the-forge/services/monitoring

cat > ~/projetos/the-forge/services/monitoring/compose.yaml << 'EOF'
services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    volumes:
      - ./data:/app/data
    networks:
      - proxy

  netdata:
    image: netdata/netdata:stable
    container_name: netdata
    hostname: homelab
    restart: unless-stopped
    cap_add:
      - SYS_PTRACE
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    volumes:
      - ./netdata-data/config:/etc/netdata
      - ./netdata-data/lib:/var/lib/netdata
      - ./netdata-data/cache:/var/cache/netdata
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /etc/localtime:/etc/localtime:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - NETDATA_CLAIM_TOKEN=
      - DOCKER_HOST=unix:///var/run/docker.sock
    networks:
      - proxy

networks:
  proxy:
    external: true
EOF
```

**Por que o Netdata precisa de `cap_add` e `security_opt`:**

O Netdata coleta métricas do kernel do host (leitura de `/proc` e `/sys`) e monitora processos. Isso requer capacidades extras além do perfil de segurança padrão do Docker. `SYS_PTRACE` é necessário para métricas de processo; `SYS_ADMIN` para acesso a certas informações de namespace. `apparmor:unconfined` libera o perfil AppArmor que bloquearia essas leituras no Ubuntu.

**Por que `NETDATA_CLAIM_TOKEN=` vazio:**

Define explicitamente modo standalone — o Netdata não tenta se conectar ao Netdata Cloud. Sem essa variável, comportamento pode variar por versão.

### 1.4 — Criar o .gitignore de monitoramento

```bash
cat > ~/projetos/the-forge/services/monitoring/.gitignore << 'EOF'
# Dados do Uptime Kuma (configuração de monitores, histórico de uptime, banco SQLite)
data/

# Dados do Netdata (configurações, banco de métricas, cache)
netdata-data/
EOF
```

### 1.5 — Commitar

```bash
cd ~/projetos/the-forge

git add services/management/ services/monitoring/
git commit -m "feat(management): add Portainer and monitoring service structure"
git push
```

---

## Etapa 2 — Subir o Portainer

> A partir daqui, tudo na **VM via SSH**.

```bash
ssh homelab
cd /srv/the-forge && git pull
```

### 2.1 — Subir o container

```bash
cd /srv/the-forge/services/management
docker compose up -d

# Acompanhar inicialização
docker logs portainer --tail 20 -f
```

Aguardar aparecer mensagem de inicialização. O Portainer inicia rapidamente (~5s).

```bash
# Confirmar que está rodando
docker ps | grep portainer
```

---

## Etapa 3 — Configuração inicial do Portainer

> Acesse via **navegador na sua máquina local**.

Painel em: `http://{{OCI_TS_IP}}:9000`

> **Atenção:** O Portainer exige que você crie a conta admin em até **5 minutos** após o primeiro start. Se esse tempo esgotar, o container precisa ser reiniciado (`docker restart portainer`) para exibir a tela de setup novamente.

### 3.1 — Criar conta admin

Preencher:
- **Username:** `admin` (ou como preferir)
- **Password:** forte — `openssl rand -base64 24`

Anotar a senha:

```bash
echo "PORTAINER_ADMIN_PASSWORD=<senha>" >> ~/.homelab/secrets.env
```

### 3.2 — Configurar o ambiente local

Após criar a conta, o Portainer exibe a tela "Quick Setup":

1. Clicar em **Get Started**
2. O ambiente **local** é detectado automaticamente (Docker socket já montado)
3. Clicar em **local** para entrar no ambiente

O Portainer agora exibe todos os containers, imagens, volumes e redes do host.

---

## Etapa 4 — Criar proxy host do Portainer no NPM

### 4.1 — DNS Rewrite no AdGuard

`DNS rewrites → Add DNS rewrite`

| Campo | Valor |
| --- | --- |
| Domain | `portainer.maiahub.com.br` |
| Answer | `{{OCI_TS_IP}}` |

### 4.2 — Emitir certificado SSL

`SSL Certificates → Add SSL Certificate → Let's Encrypt`

| Campo | Valor |
| --- | --- |
| Domain Names | `portainer.maiahub.com.br` |
| Email Address | seu email |
| Use a DNS Challenge | ✅ |
| DNS Provider | Cloudflare |
| Credentials File Content | `dns_cloudflare_api_token = {{CF_API_TOKEN}}` |
| Propagation Seconds | `60` |
| I Agree to ToS | ✅ |

### 4.3 — Criar proxy host

`Proxy Hosts → Add Proxy Host`

**Aba Details:**

| Campo | Valor |
| --- | --- |
| Domain Names | `portainer.maiahub.com.br` |
| Scheme | `http` |
| Forward Hostname/IP | `portainer` |
| Forward Port | `9000` |
| Block Common Exploits | ✅ |

**Aba SSL:**

| Campo | Valor |
| --- | --- |
| SSL Certificate | `portainer.maiahub.com.br` |
| Force SSL | ✅ |
| HTTP/2 Support | ✅ |

**Aba Access List:**

| Campo | Valor |
| --- | --- |
| Access List | `tailscale-only` |

Salvar e testar: `https://portainer.maiahub.com.br` via Tailscale deve abrir com cadeado verde.

---

## Etapa 5 — Remover porta 9000 do compose

> Somente após verificar que `https://portainer.maiahub.com.br` está funcionando.

### 5.1 — Editar o compose.yaml localmente

Remover a linha `- "9000:9000"` da seção `ports`:

```yaml
# Antes:
ports:
  - "9000:9000"

# Depois: remover a seção ports inteira (o serviço não precisa de porta exposta no host)
```

O compose final fica:

```yaml
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    networks:
      - proxy

networks:
  proxy:
    external: true
```

### 5.2 — Commitar e aplicar

```bash
# Local
git add services/management/compose.yaml
git commit -m "feat(management): remove direct port 9000 after proxy host verified"
git push

# VM
cd /srv/the-forge/services/management
git pull
docker compose up -d
```

### 5.3 — Verificar

```bash
# Porta 9000 não deve aparecer mais
sudo ss -tulnp | grep ':9000'

# Proxy ainda funciona
curl -sk https://portainer.maiahub.com.br -o /dev/null -w "%{http_code}\n"
# Deve retornar 200
```

---

## Etapa 6 — Registrar stacks existentes no Portainer

Com o Portainer no ar, registre as stacks já em execução para ter visão e gerenciamento unificado.

No Portainer: `Stacks → Add Stack → Repository`

### 6.1 — Registrar stack dns

| Campo | Valor |
| --- | --- |
| Name | `dns` |
| Repository URL | `https://github.com/{{GITHUB_USER}}/the-forge` |
| Repository reference | `refs/heads/main` |
| Compose path | `services/dns/compose.yaml` |
| Automatic updates | desabilitado (opcional — habilitar se quiser pull automático) |

Clicar em **Deploy the stack**.

> Como o container `adguard` já existe com esse nome, o Portainer vai fazer redeploy para adotar a stack. O AdGuard fica fora por alguns segundos — normal.

### 6.2 — Registrar stack proxy

Repetir o processo com:

| Campo | Valor |
| --- | --- |
| Name | `proxy` |
| Compose path | `services/proxy/compose.yaml` |

### 6.3 — Nota sobre a stack management (Portainer)

A stack `management` pode ser registrada, mas com uma ressalva: fazer update ou redeploy dessa stack via Portainer causa breve downtime do próprio painel. Para evitar situações onde o Portainer fica inacessível durante a atualização de si mesmo, **recomendação: gerenciar a stack `management` via SSH**.

Se quiser registrar mesmo assim (para visibilidade), registre sem habilitar Automatic Updates.

---

## Etapa 7 — Subir Uptime Kuma e Netdata

```bash
cd /srv/the-forge/services/monitoring
docker compose up -d

# Acompanhar inicialização
docker logs uptime-kuma --tail 20 -f &
docker logs netdata --tail 20 -f
```

Aguardar ambos iniciarem. O Netdata leva ~30–60s para popular os primeiros dados.

```bash
# Confirmar que estão rodando
docker ps | grep -E 'uptime-kuma|netdata'
```

---

## Etapa 8 — Criar proxy hosts de monitoramento no NPM

### 8.1 — DNS Rewrites no AdGuard

Adicionar dois rewrites:

| Domain | Answer |
| --- | --- |
| `monitoring.maiahub.com.br` | `{{OCI_TS_IP}}` |
| `netdata.maiahub.com.br` | `{{OCI_TS_IP}}` |

### 8.2 — Emitir certificados SSL

Repetir o processo da Etapa 4.2 para cada domínio:

- `monitoring.maiahub.com.br`
- `netdata.maiahub.com.br`

Mesmas configurações (Cloudflare, token, propagation 60s).

### 8.3 — Criar proxy host: monitoring.maiahub.com.br

**Aba Details:**

| Campo | Valor |
| --- | --- |
| Domain Names | `monitoring.maiahub.com.br` |
| Scheme | `http` |
| Forward Hostname/IP | `uptime-kuma` |
| Forward Port | `3001` |
| Block Common Exploits | ✅ |

**Aba SSL:**

| Campo | Valor |
| --- | --- |
| SSL Certificate | `monitoring.maiahub.com.br` |
| Force SSL | ✅ |
| HTTP/2 Support | ✅ |

**Aba Access List:** `tailscale-only`

### 8.4 — Criar proxy host: netdata.maiahub.com.br

**Aba Details:**

| Campo | Valor |
| --- | --- |
| Domain Names | `netdata.maiahub.com.br` |
| Scheme | `http` |
| Forward Hostname/IP | `netdata` |
| Forward Port | `19999` |
| Block Common Exploits | ✅ |

**Aba SSL:**

| Campo | Valor |
| --- | --- |
| SSL Certificate | `netdata.maiahub.com.br` |
| Force SSL | ✅ |
| HTTP/2 Support | ✅ |

**Aba Access List:** `tailscale-only`

Testar ambos: devem abrir com cadeado verde via Tailscale.

### 8.5 — Registrar stack monitoring no Portainer

Repetir o processo da Etapa 6 com:

| Campo | Valor |
| --- | --- |
| Name | `monitoring` |
| Compose path | `services/monitoring/compose.yaml` |

---

## Etapa 9 — Configurar Uptime Kuma

> Acesse `https://monitoring.maiahub.com.br` via Tailscale.

### 9.1 — Criar conta admin

No primeiro acesso o Uptime Kuma exibe a tela de criação de conta. Definir usuário e senha forte.

Anotar a senha:

```bash
echo "UPTIME_KUMA_ADMIN_PASSWORD=<senha>" >> ~/.homelab/secrets.env
```

### 9.2 — Configurar notificação por email

`Settings → Notifications → Setup Notification`

| Campo | Valor |
| --- | --- |
| Notification Type | Email (SMTP) |
| Friendly Name | `Email Homelab` |
| Hostname | servidor SMTP (ex: `smtp.gmail.com`) |
| Port | `587` (TLS) ou `465` (SSL) |
| Security | TLS/STARTTLS conforme o servidor |
| Username | seu email |
| Password | senha ou app password do email |
| From Email | seu email |
| To Email | seu email |

Clicar em **Test** antes de salvar para confirmar o envio.

> Para Gmail: criar um App Password em `myaccount.google.com → Security → 2-Step Verification → App passwords`. Usar essa senha em vez da senha normal.

### 9.3 — Adicionar monitores

Para cada monitor: `Add New Monitor`

**NPM — Porta 80 (HTTP)**

| Campo | Valor |
| --- | --- |
| Monitor Type | TCP Port |
| Friendly Name | `NPM — HTTP :80` |
| Hostname | `{{OCI_PUBLIC_IP}}` |
| Port | `80` |
| Heartbeat Interval | `60` |
| Notification | `Email Homelab` ✅ |

**NPM — Porta 443 (HTTPS)**

| Campo | Valor |
| --- | --- |
| Monitor Type | TCP Port |
| Friendly Name | `NPM — HTTPS :443` |
| Hostname | `{{OCI_PUBLIC_IP}}` |
| Port | `443` |

**AdGuard — DNS**

| Campo | Valor |
| --- | --- |
| Monitor Type | DNS |
| Friendly Name | `AdGuard DNS` |
| Hostname | `{{OCI_TS_IP}}` |
| Resolver Server | `{{OCI_TS_IP}}` |
| Resolver Port | `53` |
| Record Type | `A` |
| Value | nome qualquer (ex: `npm.maiahub.com.br`) |

**AdGuard painel**

| Campo | Valor |
| --- | --- |
| Monitor Type | HTTP(s) |
| Friendly Name | `AdGuard — painel` |
| URL | `https://adguard.maiahub.com.br` |
| Accepted Status Codes | `200-299` |

**NPM painel**

| Campo | Valor |
| --- | --- |
| Monitor Type | HTTP(s) |
| Friendly Name | `NPM — painel` |
| URL | `https://npm.maiahub.com.br` |

**Portainer**

| Campo | Valor |
| --- | --- |
| Monitor Type | HTTP(s) |
| Friendly Name | `Portainer` |
| URL | `https://portainer.maiahub.com.br` |

**Netdata**

| Campo | Valor |
| --- | --- |
| Monitor Type | HTTP(s) |
| Friendly Name | `Netdata` |
| URL | `https://netdata.maiahub.com.br` |

**Uptime Kuma (self-monitor)**

| Campo | Valor |
| --- | --- |
| Monitor Type | HTTP(s) |
| Friendly Name | `Uptime Kuma` |
| URL | `https://monitoring.maiahub.com.br` |

---

## Etapa 10 — Configurar alertas do Netdata

O Netdata já vem com dezenas de alertas pré-configurados. Nesta etapa, habilitamos o envio por email.

### 10.1 — Localizar o arquivo de configuração

O arquivo `health_alarm_notify.conf` é gerado no primeiro start do Netdata em `./netdata-data/config/`:

```bash
# Na VM
ls /srv/the-forge/services/monitoring/netdata-data/config/
# Deve conter health_alarm_notify.conf (gerado pelo Netdata no primeiro start)

# Se não existir ainda, gerar a partir do padrão:
docker exec netdata bash -c \
  "cp /usr/lib/netdata/conf.d/health_alarm_notify.conf /etc/netdata/health_alarm_notify.conf"
```

### 10.2 — Configurar envio por email

```bash
# Editar o arquivo diretamente na VM
nano /srv/the-forge/services/monitoring/netdata-data/config/health_alarm_notify.conf
```

Localizar e editar as seções:

```bash
# Habilitar email
SEND_EMAIL="YES"

# Configurar SMTP (mesmo servidor do Uptime Kuma)
EMAIL_SENDER="seu@email.com"
DEFAULT_RECIPIENT_EMAIL="seu@email.com"

# Para Gmail com App Password:
SMTP_SERVER="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="seu@email.com"
SMTP_PASS="<app_password>"
```

### 10.3 — Reiniciar para aplicar

```bash
docker restart netdata
```

### 10.4 — Testar o envio

```bash
docker exec netdata /usr/libexec/netdata/plugins.d/alarm-notify.sh test
```

Deve chegar um email de teste com assunto `NETDATA TEST ALARM`. Se não chegar, verificar os logs:

```bash
docker logs netdata --tail 50 | grep -i alarm
```

### 10.5 — Alertas padrão relevantes para o homelab

O Netdata vem com estes alertas ativados por padrão (entre muitos outros):

| Alerta | Limiar | Relevância |
| --- | --- | --- |
| `disk_space_usage` | > 85% | Block volume `/mnt/data` — crítico |
| `disk_fill_rate` | extrapola para encher em < 48h | Crescimento de mídia |
| `ram_available` | < 100MB | 24GB de RAM — pouco provável mas vale |
| `cpu_usage` | > 75% por > 15min | Carga sustentada anormal |
| `net_ethX_backlog` | pacotes descartados | Problema de rede |

Para verificar os alertas ativos:

```bash
# Ver todos os alertas configurados
docker exec netdata netdatacli alarms
```

---

## Checklist final da Fase 4

### Portainer

- [ ] `docker ps` mostra `portainer` com status `Up`
- [ ] `https://portainer.maiahub.com.br` abre com cadeado verde via Tailscale
- [ ] `https://portainer.maiahub.com.br` retorna 403 de IP fora do Tailscale
- [ ] Ambiente local configurado — aba `local` mostra todos os containers do host
- [ ] `sudo ss -tulnp | grep ':9000'` não retorna nada (porta removida)
- [ ] Stacks registradas no Portainer: `dns`, `proxy`

### Uptime Kuma

- [ ] `docker ps` mostra `uptime-kuma` com status `Up`
- [ ] `https://monitoring.maiahub.com.br` abre com cadeado verde via Tailscale
- [ ] Notificação email configurada e testada (email de teste recebido)
- [ ] Monitores criados (8 monitors): NPM :80, NPM :443, AdGuard DNS, AdGuard painel, NPM painel, Portainer, Netdata, Uptime Kuma
- [ ] Todos os monitores com status verde

### Netdata

- [ ] `docker ps` mostra `netdata` com status `Up`
- [ ] `https://netdata.maiahub.com.br` abre com cadeado verde via Tailscale
- [ ] Dashboard exibe métricas em tempo real (CPU, RAM, rede, containers)
- [ ] `health_alarm_notify.conf` configurado com SMTP
- [ ] Teste de alarme enviado com sucesso (`alarm-notify.sh test`)

### Certificados

- [ ] `portainer.maiahub.com.br` listado em SSL Certificates com status válido
- [ ] `monitoring.maiahub.com.br` listado em SSL Certificates com status válido
- [ ] `netdata.maiahub.com.br` listado em SSL Certificates com status válido

### Repositório

- [ ] `services/management/compose.yaml` commitado (sem porta 9000)
- [ ] `services/management/.gitignore` commitado
- [ ] `services/management/data/` **não** commitado
- [ ] `services/monitoring/compose.yaml` commitado
- [ ] `services/monitoring/.gitignore` commitado
- [ ] `services/monitoring/data/` **não** commitado
- [ ] `services/monitoring/netdata-data/` **não** commitado

---

## Referência rápida — Operações do dia a dia

```bash
# === PORTAINER ===

# Status
docker ps | grep portainer
docker logs portainer --tail 50

# Reiniciar
docker restart portainer

# Atualizar imagem
cd /srv/the-forge/services/management
docker compose pull && docker compose up -d

# Acesso de emergência se proxy falhar
# Adicionar temporariamente "9000:9000" no compose.yaml e docker compose up -d


# === UPTIME KUMA ===

# Status e logs
docker ps | grep uptime-kuma
docker logs uptime-kuma --tail 50

# Reiniciar
docker restart uptime-kuma

# Atualizar imagem
cd /srv/the-forge/services/monitoring
docker compose pull && docker compose up -d


# === NETDATA ===

# Status e logs
docker ps | grep netdata
docker logs netdata --tail 50

# Ver alertas ativos
docker exec netdata netdatacli alarms

# Testar notificação de alerta
docker exec netdata /usr/libexec/netdata/plugins.d/alarm-notify.sh test

# Editar configuração de alertas
nano /srv/the-forge/services/monitoring/netdata-data/config/health_alarm_notify.conf
docker restart netdata


# === PORTAINER STACKS ===

# Registrar nova stack (para cada fase nova)
# Portainer UI → Stacks → Add Stack → Repository
# Name: <nome-da-stack>
# URL: https://github.com/{{GITHUB_USER}}/the-forge
# Path: services/<nome>/compose.yaml

# Update manual de uma stack registrada
# Portainer UI → Stacks → <nome-da-stack> → Pull and redeploy
```

---

## Próxima fase

### Fase 5 — Nextcloud

Migração dos dados da Hostinger e configuração da stack completa do Nextcloud:

- Nextcloud + PostgreSQL + Redis + Collabora + Elasticsearch + ClamAV + notify_push
- Certificado `cloud.maiahub.com.br` via DNS Challenge (domínio público — sem Access List)
- Transferência dos 7GB de arquivos via rsync
- Reimportação de contatos (`.vcf`), calendários (`.ics`), tarefas, feeds RSS

**Após subir a Fase 5, registrar a stack `cloud` no Portainer e adicionar monitores no Uptime Kuma:**
- `Nextcloud health`: `https://cloud.maiahub.com.br/status.php`

---

_Fase 4 de 9 — Projeto Homelab_
