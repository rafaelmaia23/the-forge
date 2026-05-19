# Fase 5 — Nextcloud

## Guia de Execução Completo

**Projeto:** Homelab  
**Fase:** 5 de 9  
**Objetivo:** Migrar e configurar o Nextcloud completo com stack integrada — cloud pessoal, compartilhamento, contatos, calendários, documentos colaborativos, busca full-text e antivírus  
**Tempo estimado:** 4–7 horas (stack complexa + migração de dados)  
**Pré-requisito:** Fase 4 concluída — NPM, AdGuard, Portainer e Uptime Kuma no ar

---

## O que esta fase entrega

Ao final desta fase:

- **Nextcloud 31** rodando em `cloud.maiahub.com.br` (público — acessível sem Tailscale)
- **Collabora** rodando em `office.maiahub.com.br` (público — edição de documentos online)
- **PostgreSQL 17** como banco de dados principal
- **Redis** para cache de sessão e file locking com autenticação
- **Elasticsearch 8** para busca full-text dentro de arquivos
- **ClamAV** para antivírus de uploads via TCP
- **Notify Push** para notificações em tempo real nos apps mobile
- **Imaginary** para geração de thumbnails de imagem em alta performance (ARM64 nativo)
- 7 GB de arquivos migrados do Nextcloud anterior (Hostinger) via rsync
- Contatos (`.vcf`), calendários (`.ics`), tarefas (`.ics`) e feeds RSS (`.opml`) reimportados
- DAVx⁵ configurado no Android apontando para o novo servidor
- Monitor do Nextcloud adicionado no Uptime Kuma
- Stack `cloud` registrada no Portainer

> **Nota:** Contatos, Calendários, Tasks, Notes, Deck, News são **apps do Nextcloud** — rodam dentro do container principal e são instalados via App Store. Não requerem containers extras.

---

## Decisões arquiteturais desta fase

| Decisão | Escolha | Motivo |
| --- | --- | --- |
| Stack | Manual (containers separados) | Controle de versão, debugging granular, compatibilidade com backup Fase 8. Ver ADR-009 |
| Nextcloud version | `nextcloud:31-apache` | Versão major atual — suporte mais longo; fixar para controlar upgrades |
| PostgreSQL version | `postgres:17` | Versão mais nova — upgrades de major version são manuais, melhor escolher o mais novo agora |
| Redis | Com senha (`REDIS_HOST_PASSWORD`) | Boa prática mesmo em rede interna Docker |
| Collabora | `office.maiahub.com.br` — público | Namorada pode editar documentos sem Tailscale |
| Elasticsearch heap | `1g/1g` | 24 GB disponíveis — 1 GB para ES é equilibrado com os demais serviços |
| ClamAV conexão | TCP `:3310` | Socket Unix não é compartilhável entre containers Docker |
| Imaginary | `nextcloud/aio-imaginary` | ARM64 nativo; `h2non/imaginary` não tem build ARM64 e falha silenciosamente |
| Notify Push | Sidecar ARM64 | Binário extraído da imagem Nextcloud; reinicia até o app ser instalado (esperado) |
| Coturn | Não incluído | Videochamadas via Talk não fazem parte do plano atual |
| Dados de usuário | Bind mount em `/mnt/data/nextcloud/userdata` | Arquivo no block volume Oracle — separado do sistema e incluso nos backups |
| Redes Docker | `proxy` (externa) + `nextcloud_internal` (interna) | Isola serviços internos; apenas nextcloud, collabora e notify_push ficam expostos ao NPM |

---

## Papel de cada componente da stack

| Container | Porta interna | Função |
| --- | --- | --- |
| `nextcloud` | `80` | Aplicação principal (Apache + PHP) |
| `nextcloud-db` | `5432` | PostgreSQL — banco de dados |
| `nextcloud-redis` | `6379` | Cache de sessão e file locking |
| `nextcloud-collabora` | `9980` | Nextcloud Office — edição de documentos |
| `nextcloud-elasticsearch` | `9200` | Full Text Search dentro de arquivos |
| `nextcloud-clamav` | `3310` | Antivírus para uploads |
| `nextcloud-notify-push` | `7867` | Notificações em tempo real (WebSocket) |
| `nextcloud-imaginary` | `9000` | Previews e thumbnails de imagem |

### Diagrama da stack

```
       Internet                                Tailscale
           │                                      │
    ┌──────▼─────────────────────────────────────▼──────┐
    │                   NPM (porta 80/443)               │
    └──────┬────────────────────────────┬────────────────┘
           │ cloud.maiahub.com.br       │ office.maiahub.com.br
           │ + /push (WebSocket)        │ (WebSocket)
    ╔══════▼═══════════════════════════▼════════════════╗
    ║              rede: proxy (bridge Docker)           ║
    ║   nextcloud:80   nextcloud-collabora:9980          ║
    ║                  nextcloud-notify-push:7867         ║
    ╚══════╦═══════════════════════════════════════════════╝
           ║ rede: nextcloud_internal
    ╔══════▼═══════════════════════════════════════════════╗
    ║            rede: nextcloud_internal (interna)         ║
    ║   nextcloud-db:5432    nextcloud-redis:6379           ║
    ║   nextcloud-elasticsearch:9200                        ║
    ║   nextcloud-clamav:3310  nextcloud-imaginary:9000     ║
    ╚═══════════════════════════════════════════════════════╝
```

---

## Por que o notify_push reinicia inicialmente (comportamento esperado)

O `nextcloud-notify-push` é um sidecar: roda como container separado usando o mesmo binário que vem dentro da imagem `nextcloud:31-apache`. O binário fica em `/var/www/html/apps/notify_push/bin/aarch64/notify_push` — mas esse arquivo só existe **depois** que a app `Client Push (notify_push)` é instalada no Nextcloud.

No `docker compose up -d` inicial, o container tenta executar o binário, não encontra, e reinicia. Isso é esperado e está documentado aqui. O ciclo correto é:

```
1. docker compose up -d → notify_push reinicia (esperado)
2. Instalar apps no Nextcloud (Etapa 8) → binário aparece no volume nextcloud_apps
3. docker compose restart nextcloud-notify-push → inicia normalmente
4. occ notify_push:setup → configura a integração
```

Não é necessário interromper o `docker compose up -d` por causa disso.

---

## Etapa 1 — Preparar a estrutura local

> Faça esta etapa na sua **máquina local**.

Os arquivos abaixo já estão criados no repositório. Revise e commite.

### 1.1 — Conferir o compose.yaml

O arquivo `services/cloud/compose.yaml` já está no repositório. Conteúdo de referência:

```yaml
services:
  nextcloud:
    image: nextcloud:31-apache
    container_name: nextcloud
    restart: unless-stopped
    depends_on:
      nextcloud-db:
        condition: service_healthy
      nextcloud-redis:
        condition: service_started
    environment:
      - POSTGRES_HOST=nextcloud-db
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - REDIS_HOST=nextcloud-redis
      - REDIS_HOST_PASSWORD=${REDIS_HOST_PASSWORD}
      - NEXTCLOUD_ADMIN_USER=${NEXTCLOUD_ADMIN_USER}
      - NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASSWORD}
      - NEXTCLOUD_TRUSTED_DOMAINS=${NEXTCLOUD_TRUSTED_DOMAINS}
      - TRUSTED_PROXIES=${TRUSTED_PROXIES}
      - OVERWRITEPROTOCOL=https
      - OVERWRITECLIURL=https://cloud.maiahub.com.br
      - NC_default_phone_region=BR
    volumes:
      - nextcloud_config:/var/www/html/config
      - nextcloud_apps:/var/www/html/apps
      - /mnt/data/nextcloud/userdata:/var/www/html/data
    networks:
      - proxy
      - nextcloud_internal

  nextcloud-db:
    image: postgres:17
    container_name: nextcloud-db
    restart: unless-stopped
    environment:
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - nextcloud_db:/var/lib/postgresql/data
    networks:
      - nextcloud_internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  nextcloud-redis:
    image: redis:7-alpine
    container_name: nextcloud-redis
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_HOST_PASSWORD}
    volumes:
      - nextcloud_redis:/data
    networks:
      - nextcloud_internal

  nextcloud-collabora:
    image: collabora/code:latest
    container_name: nextcloud-collabora
    restart: unless-stopped
    environment:
      - server_name=office.maiahub.com.br
      - aliasgroup1=https://cloud.maiahub.com.br:443
      - DONT_GEN_SSL_CERT=YES
      - extra_params=--o:ssl.enable=false --o:ssl.termination=true
    networks:
      - proxy
      - nextcloud_internal

  nextcloud-elasticsearch:
    image: elasticsearch:8
    container_name: nextcloud-elasticsearch
    restart: unless-stopped
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
    volumes:
      - nextcloud_elasticsearch:/usr/share/elasticsearch/data
    networks:
      - nextcloud_internal

  nextcloud-clamav:
    image: clamav/clamav:latest
    container_name: nextcloud-clamav
    restart: unless-stopped
    networks:
      - nextcloud_internal

  # Sidecar do notify_push — reinicia até o app ser instalado no Nextcloud (comportamento esperado)
  nextcloud-notify-push:
    image: nextcloud:31-apache
    container_name: nextcloud-notify-push
    restart: unless-stopped
    entrypoint: /var/www/html/apps/notify_push/bin/aarch64/notify_push
    command: /var/www/html/config/config.php
    environment:
      - PORT=7867
      - NEXTCLOUD_URL=http://nextcloud
    volumes:
      - nextcloud_config:/var/www/html/config:ro
      - nextcloud_apps:/var/www/html/apps:ro
    depends_on:
      - nextcloud
    networks:
      - proxy
      - nextcloud_internal

  nextcloud-imaginary:
    image: nextcloud/aio-imaginary:latest
    container_name: nextcloud-imaginary
    restart: unless-stopped
    networks:
      - nextcloud_internal

volumes:
  nextcloud_config:
  nextcloud_apps:
  nextcloud_db:
  nextcloud_redis:
  nextcloud_elasticsearch:

networks:
  proxy:
    external: true
  nextcloud_internal:
    internal: true
```

**Por que `OVERWRITEPROTOCOL=https` e `OVERWRITECLIURL`:**

O Nextcloud detecta automaticamente o protocolo da requisição. Atrás do NPM fazendo SSL termination, as requisições chegam ao container por HTTP — sem essas variáveis, o Nextcloud pensa que está em HTTP e gera URLs erradas, links quebrados e warnings de segurança no painel admin.

**Por que `TRUSTED_PROXIES=172.16.0.0/12`:**

Diz ao Nextcloud para confiar nos headers `X-Forwarded-For` enviados pelo NPM. Sem isso, o Nextcloud não sabe o IP real do cliente e exibe avisos de "acesso via proxy não confiável". O range `172.16.0.0/12` cobre todas as redes Docker (bridge padrão `172.17.0.0/16`, rede `proxy`, etc.) sem precisar fixar o IP do NPM.

**Por que `healthcheck` no banco:**

O `nextcloud` usa `depends_on: nextcloud-db: condition: service_healthy` — só inicia quando o PostgreSQL estiver aceitando conexões. Sem o healthcheck, o Nextcloud pode tentar conectar antes do banco estar pronto e falhar na inicialização.

### 1.2 — Conferir o .env.example

```bash
# PostgreSQL
POSTGRES_DB=nextcloud
POSTGRES_USER=nextcloud
POSTGRES_PASSWORD=<gerado com: openssl rand -base64 32>

# Redis
REDIS_HOST_PASSWORD=<gerado com: openssl rand -base64 32>

# Nextcloud — admin inicial (usado apenas na primeira inicialização)
NEXTCLOUD_ADMIN_USER=rmf
NEXTCLOUD_ADMIN_PASSWORD=<senha forte>

# Nextcloud — domínio e proxy
NEXTCLOUD_TRUSTED_DOMAINS=cloud.maiahub.com.br
TRUSTED_PROXIES=172.16.0.0/12
```

### 1.3 — Verificar o .gitignore

```bash
.env
data/
```

### 1.4 — Commitar

```bash
cd ~/projetos/the-forge

git add services/cloud/
git commit -m "feat(cloud): add nextcloud stack structure — compose, env example, gitignore"
git push
```

---

## Etapa 2 — Preparar a VPS

> A partir daqui, tudo na **VM via SSH** (via Tailscale).

```bash
ssh homelab
cd /srv/the-forge && git pull
```

### 2.1 — Criar diretório de dados no block volume

```bash
mkdir -p /mnt/data/nextcloud/userdata

# Verificar que o diretório está no block volume (não no boot volume)
df -h /mnt/data/nextcloud/
# Deve mostrar o device do block volume (ex: /dev/sdb ou /dev/vdb) com 150GB
```

### 2.2 — Criar o .env real

```bash
cd /srv/the-forge/services/cloud

# Gerar senhas seguras
POSTGRES_PASSWORD=$(openssl rand -base64 32)
REDIS_HOST_PASSWORD=$(openssl rand -base64 32)

cat > .env << EOF
# PostgreSQL
POSTGRES_DB=nextcloud
POSTGRES_USER=nextcloud
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

# Redis
REDIS_HOST_PASSWORD=${REDIS_HOST_PASSWORD}

# Nextcloud — admin inicial
NEXTCLOUD_ADMIN_USER=rmf
NEXTCLOUD_ADMIN_PASSWORD=<defina uma senha forte>

# Nextcloud — domínio e proxy
NEXTCLOUD_TRUSTED_DOMAINS=cloud.maiahub.com.br
TRUSTED_PROXIES=172.16.0.0/12
EOF
```

Salvar as senhas no arquivo de segredos local:

```bash
cat >> ~/.homelab/secrets.env << EOF

# Nextcloud (Fase 5)
NEXTCLOUD_POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
NEXTCLOUD_REDIS_PASSWORD=${REDIS_HOST_PASSWORD}
NEXTCLOUD_ADMIN_PASSWORD=<a senha que você definiu>
EOF
```

---

## Etapa 3 — Verificar compatibilidade do Elasticsearch

> Antes de subir a stack, verificar a versão do Elasticsearch compatível com o Nextcloud 31.

Acessar: `https://apps.nextcloud.com/apps/fulltextsearch_elasticsearch`

Verificar a seção de versões compatíveis do app `Full Text Search - Elasticsearch Platform`:
- Se a versão 8.x estiver listada como compatível → o tag `elasticsearch:8` do compose está correto
- Se apenas versões específicas estiverem listadas (ex: `8.11`) → atualizar o tag no compose.yaml

```bash
# Se precisar atualizar o tag:
# Local: editar services/cloud/compose.yaml, alterar elasticsearch:8 para elasticsearch:8.11 (ou a versão indicada)
# git commit -m "fix(cloud): pin elasticsearch to version compatible with nc31 fulltextsearch"
# git push && na VPS: git pull
```

---

## Etapa 4 — Subir a stack

```bash
cd /srv/the-forge/services/cloud
docker compose up -d
```

### 4.1 — Acompanhar inicialização

A stack tem tempos de inicialização muito diferentes por componente:

| Container | Tempo estimado | O que aguardar |
| --- | --- | --- |
| `nextcloud-redis` | ~2s | Imediato |
| `nextcloud-db` | ~5–10s | Health check passar |
| `nextcloud-elasticsearch` | ~20–60s | Aparece como `Up` |
| `nextcloud-collabora` | ~10–20s | Aparece como `Up` |
| `nextcloud-imaginary` | ~5s | Imediato |
| `nextcloud` | ~60–120s | Inicialização e migrations do banco |
| `nextcloud-clamav` | **5–15 min** | Download das definições de vírus |
| `nextcloud-notify-push` | N/A | Reinicia até app ser instalada (esperado) |

```bash
# Acompanhar status geral
watch -n5 docker ps --format "table {{.Names}}\t{{.Status}}"

# Logs do Nextcloud (inicialização e migrations)
docker logs nextcloud -f --tail=50

# Logs do ClamAV — aguardar "Signatures loaded" antes de testar antivírus
docker logs nextcloud-clamav -f
```

Aguardar o ClamAV mostrar:
```
Signatures loaded
clamd daemon: started
```

> O antivírus não precisa estar pronto para continuar a configuração — apenas para testar uploads com scan. Continue com as próximas etapas enquanto o ClamAV inicializa.

### 4.2 — Verificar containers rodando

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | grep nextcloud
```

O `nextcloud-notify-push` vai aparecer em status `Restarting` — isso é esperado até a Etapa 9.

---

## Etapa 5 — DNS Rewrites no AdGuard

Adicionar dois novos rewrites em: `https://adguard.maiahub.com.br → DNS Rewrites → Add DNS rewrite`

| Domain | Answer |
| --- | --- |
| `cloud.maiahub.com.br` | `{{OCI_PUBLIC_IP}}` |
| `office.maiahub.com.br` | `{{OCI_PUBLIC_IP}}` |

> **Por que o IP público e não o IP Tailscale:**
> `cloud.maiahub.com.br` é um serviço público — acessado pela namorada e por qualquer browser sem Tailscale. Diferente dos painéis de controle (que resolvem para `{{OCI_TS_IP}}`), os serviços públicos resolvem para o IP público Oracle. Ver [ADR-007](../decisions/ADR-007-dns-split-tailscale-public.md).

Testar a resolução (no seu dispositivo Tailscale):

```bash
dig cloud.maiahub.com.br
# Deve retornar {{OCI_PUBLIC_IP}}
```

---

## Etapa 6 — Certificados e proxy hosts no NPM

Esta etapa cria dois certificados e dois proxy hosts públicos (sem Access List).

### 6.1 — Emitir certificado: cloud.maiahub.com.br

`SSL Certificates → Add SSL Certificate → Let's Encrypt`

| Campo | Valor |
| --- | --- |
| Domain Names | `cloud.maiahub.com.br` |
| Email Address | seu email |
| Use a DNS Challenge | ✅ |
| DNS Provider | Cloudflare |
| Credentials File Content | `dns_cloudflare_api_token = {{CF_API_TOKEN}}` |
| Propagation Seconds | `60` |
| I Agree to ToS | ✅ |

### 6.2 — Emitir certificado: office.maiahub.com.br

Repetir o processo para `office.maiahub.com.br`.

### 6.3 — Proxy host: cloud.maiahub.com.br

`Proxy Hosts → Add Proxy Host`

**Aba Details:**

| Campo | Valor |
| --- | --- |
| Domain Names | `cloud.maiahub.com.br` |
| Scheme | `http` |
| Forward Hostname/IP | `nextcloud` |
| Forward Port | `80` |
| Block Common Exploits | ✅ |

**Aba SSL:**

| Campo | Valor |
| --- | --- |
| SSL Certificate | `cloud.maiahub.com.br` |
| Force SSL | ✅ |
| HTTP/2 Support | ✅ |

> **Não adicionar Access List** — Nextcloud deve ser público.

**Aba Advanced — Custom Nginx Config:**

```nginx
client_max_body_size 0;

proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

`client_max_body_size 0` remove qualquer limite de tamanho de upload — necessário para o Nextcloud aceitar arquivos grandes.

#### 6.3.1 — Custom Location: /push (Notify Push)

Ainda no proxy host do Nextcloud, aba **Custom locations**:

Clicar em **Add location** e preencher:

| Campo | Valor |
| --- | --- |
| location | `/push` |
| Scheme | `http` |
| Forward Hostname/IP | `nextcloud-notify-push` |
| Forward Port | `7867` |
| WebSocket Support | ✅ |

Isso faz com que `https://cloud.maiahub.com.br/push` seja roteado para o container `nextcloud-notify-push` com suporte a WebSocket, sem expor o container diretamente.

### 6.4 — Proxy host: office.maiahub.com.br

**Aba Details:**

| Campo | Valor |
| --- | --- |
| Domain Names | `office.maiahub.com.br` |
| Scheme | `http` |
| Forward Hostname/IP | `nextcloud-collabora` |
| Forward Port | `9980` |
| Websocket Support | ✅ |
| Block Common Exploits | ✅ |

**Aba SSL:**

| Campo | Valor |
| --- | --- |
| SSL Certificate | `office.maiahub.com.br` |
| Force SSL | ✅ |
| HTTP/2 Support | ✅ |

> **Não adicionar Access List** — Collabora deve ser público (namorada usa sem Tailscale).

**Aba Advanced — Custom Nginx Config:**

```nginx
proxy_set_header X-Forwarded-Proto $scheme;
proxy_read_timeout 36000s;
```

`proxy_read_timeout 36000s` evita que o NPM feche conexões longas durante sessões de edição de documentos.

### 6.5 — Testar acesso inicial

```bash
# Deve retornar HTTP 302 (redirect para HTTPS) ou 200
curl -sk https://cloud.maiahub.com.br -o /dev/null -w "%{http_code}\n"
# Espera: 200 (login page)
```

---

## Etapa 7 — Setup inicial no browser

> Acesse `https://cloud.maiahub.com.br` no browser.

### 7.1 — Primeiro acesso

Como o `NEXTCLOUD_ADMIN_USER` e `NEXTCLOUD_ADMIN_PASSWORD` foram definidos no `.env`, o Nextcloud faz o setup automaticamente no primeiro boot. A tela de login deve aparecer diretamente.

Fazer login com as credenciais admin (`rmf` / `{{NEXTCLOUD_ADMIN_PASSWORD}}`).

> Se aparecer a tela de "escolha o banco de dados" em vez da tela de login, o Nextcloud ainda não concluiu a inicialização automática — aguardar mais 1–2 minutos e recarregar.

### 7.2 — Validar configurações básicas

`Configurações → Administration → Overview`

Verificar que os seguintes itens não estão em vermelho:

- **Security & setup warnings:** não deve ter erros de HTTPS ou proxy
- **Trusted proxies:** deve aparecer sem avisos

Se aparecer "Your web server is not set up properly to resolve `/.well-known/caldav` and `/.well-known/carddav`", adicionar a seguinte configuração no **Custom Nginx Config** do proxy host `cloud.maiahub.com.br`:

```nginx
location = /.well-known/carddav {
    return 301 $scheme://$host/remote.php/dav;
}
location = /.well-known/caldav {
    return 301 $scheme://$host/remote.php/dav;
}
```

---

## Etapa 8 — Instalar apps

> No painel do Nextcloud: **Apps** (ícone no canto superior direito → Apps)

Instalar os apps abaixo por categoria. Clicar em **Download and enable** em cada um.

### Comunicação e colaboração

- **Talk** — videochamadas e chat (nota: sem Coturn, apenas P2P — OK para uso pessoal)
- **Calendar** — calendários
- **Contacts** — agenda de contatos
- **Deck** — quadro Kanban
- **Tasks** — tarefas (integrado com Calendar/CalDAV)
- **Notes** — notas pessoais
- **Whiteboard** — quadro branco colaborativo

### Arquivos e produtividade

- **Nextcloud Office** — edição de documentos (requer Collabora — configurado na Etapa 9)
- **Photos** — galeria de fotos com mapa
- **PDF Viewer** — visualizador de PDF inline
- **Text** — editor de texto/markdown
- **File Reminders** — lembretes de prazo em arquivos
- **Files Download Limit** — limite de downloads em compartilhamentos

### Busca full-text

Instalar nesta ordem:

1. **Full Text Search** — motor de busca central
2. **Full Text Search - Elasticsearch Platform** — conector Elasticsearch
3. **Full Text Search - Files** — indexação de conteúdo de arquivos

### Segurança

- **Two-Factor TOTP Provider** — autenticação de dois fatores (recomendado habilitar após migração)
- **Antivirus for Files** — integração com o ClamAV (configurado na Etapa 9)
- **Password Policy** — política de senhas
- **Auditing / Logging** — log de ações dos usuários
- **Privacy** — controle de dados pessoais

### Notificações e integrações

- **Client Push (notify_push)** — notificações em tempo real nos apps (**instalar antes de configurar na Etapa 9**)
- **DAV Push** — sincronização push para CalDAV/CardDAV

### Admin

- **Monitoring** — métricas Nextcloud (endpoint `/apps/serverinfo/api/v1/info`)
- **Log Reader** — visualizador de logs no painel admin

### RSS

- **News** — leitor RSS integrado

---

## Etapa 9 — Configurar integrações

### 9.1 — Collabora (Nextcloud Office)

`Configurações → Administration → Office`

| Campo | Valor |
| --- | --- |
| Use your own server | ✅ |
| URL do servidor Collabora | `https://office.maiahub.com.br` |

Clicar em **Save** e aguardar a mensagem de confirmação de conexão.

Testar: abrir qualquer arquivo `.docx` ou `.odt` do Nextcloud — deve abrir o editor Collabora.

### 9.2 — Elasticsearch (Full Text Search)

`Configurações → Administration → Full text search`

| Campo | Valor |
| --- | --- |
| Search platform | Elasticsearch |
| Servlet | `http://nextcloud-elasticsearch:9200` |
| Index | `nextcloud` |
| Analyzer tokenizer | standard |

Salvar e iniciar a indexação:

```bash
# Indexar todos os arquivos (leva alguns minutos para 7 GB)
docker exec -u www-data nextcloud php occ fulltextsearch:index

# Acompanhar progresso
docker exec -u www-data nextcloud php occ fulltextsearch:index --output
```

### 9.3 — ClamAV (Antivírus)

> Confirmar antes que o ClamAV concluiu a atualização das definições:

```bash
docker logs nextcloud-clamav --tail=5
# Deve mostrar: "Signatures loaded" e "clamd daemon: started"
```

`Configurações → Administration → Security → Antivirus for Files`

| Campo | Valor |
| --- | --- |
| Antivirus mode | Daemon (Socket) |
| Host | `nextcloud-clamav` |
| Port | `3310` |
| Stream Length | `26214400` (25 MB, padrão) |

Salvar. Testar: fazer upload de um arquivo qualquer e verificar que não há erro de antivírus.

> Para testar com um arquivo de teste EICAR (vírus fictício):
> Baixar de `https://www.eicar.org/download/eicar-com-2/` e tentar fazer upload — deve ser bloqueado com mensagem de vírus.

### 9.4 — Imaginary (Thumbnails)

```bash
# Habilitar Imaginary como provider de preview
docker exec -u www-data nextcloud php occ config:system:set \
  enabledPreviewProviders 0 --value="OC\\Preview\\Imaginary"

# Configurar URL do Imaginary
docker exec -u www-data nextcloud php occ config:system:set \
  preview_imaginary_url --value="http://nextcloud-imaginary:9000"

# Verificar configuração
docker exec -u www-data nextcloud php occ config:system:get preview_imaginary_url
```

### 9.5 — Notify Push

Agora que o app `Client Push (notify_push)` foi instalado na Etapa 8, o binário existe no volume `nextcloud_apps`. Reiniciar o sidecar:

```bash
cd /srv/the-forge/services/cloud
docker compose restart nextcloud-notify-push

# Aguardar inicialização (~5s)
docker logs nextcloud-notify-push --tail=10
# Deve aparecer: "Starting notify_push server"
```

Configurar a integração:

```bash
docker exec -u www-data nextcloud php occ notify_push:setup \
  https://cloud.maiahub.com.br
```

Verificar que tudo está OK:

```bash
docker exec -u www-data nextcloud php occ notify_push:self-test
```

A saída deve mostrar todos os itens como `✓`:
```
✓ connection
✓ push server
✓ self-test
```

---

## Etapa 10 — Migrar dados (7 GB)

Os arquivos foram baixados do Nextcloud da Hostinger para o PC local na etapa pré-migração (P.5).

### 10.1 — Transferir do PC local para a VPS

> Executar na **máquina local** via Tailscale.

```bash
rsync -avz --progress \
  ~/nextcloud_files/ \
  ubuntu@{{OCI_TS_IP}}:/mnt/data/nextcloud/userdata/rmf/files/
```

Flags:
- `-a` — modo arquivo (preserva permissões, timestamps, symlinks)
- `-v` — verbose
- `-z` — compressão em trânsito
- `--progress` — progresso por arquivo

> 7 GB via Tailscale leva entre 5 e 30 minutos dependendo da conexão. `rsync` é retomável — se cair, rodar o mesmo comando novamente e ele sincroniza apenas o que falta.

### 10.2 — Reescanear arquivos na VPS

Após a transferência:

```bash
# O --all escaneia todos os usuários
docker exec -u www-data nextcloud php occ files:scan --all

# Acompanhar progresso (pode demorar alguns minutos para 7 GB)
# Ao final, mostra: "| Folders | Files | Errors |"
```

### 10.3 — Verificar no browser

Acessar `https://cloud.maiahub.com.br` → Files → verificar que os arquivos aparecem na biblioteca.

---

## Etapa 11 — Reimportar dados pessoais

### 11.1 — Contatos (.vcf)

`Apps → Contacts → Configurações (ícone engrenagem) → Import`

Selecionar o arquivo `contacts_export.vcf` exportado na pré-migração (P.1).

Verificar que os contatos aparecem na lista.

### 11.2 — Calendários (.ics)

`Apps → Calendar → Configurações (ícone engrenagem) → Import calendar`

Importar um calendário por vez. Se você exportou múltiplos calendários separados, repetir para cada arquivo `.ics`.

### 11.3 — Tarefas (.ics)

As tarefas do Nextcloud Tasks são compatíveis com o formato iCal — podem ser importadas pelo mesmo mecanismo do Calendar.

`Apps → Calendar → Configurações → Import calendar`

Selecionar o arquivo de tarefas `.ics` exportado em P.3.

### 11.4 — Feeds RSS (.opml)

`Apps → News → Configurações (ícone engrenagem) → Import OPML`

Selecionar o arquivo `.opml` exportado em P.4.

---

## Etapa 12 — Configurar clientes

### 12.1 — DAVx⁵ no Android

1. Abrir o DAVx⁵ → **Add account** → **Login with URL**
2. Preencher:
   - **URL:** `https://cloud.maiahub.com.br/remote.php/dav/`
   - **Usuário:** `rmf`
   - **Senha:** `{{NEXTCLOUD_ADMIN_PASSWORD}}`
3. Selecionar o que sincronizar: **CalDAV** (calendários + tarefas) e **CardDAV** (contatos)
4. Aguardar a primeira sincronização

Verificar nos apps de Contatos e Calendário nativo do Android que os dados aparecem.

### 12.2 — App Nextcloud no celular

1. Instalar o app **Nextcloud** da Play Store (ou F-Droid)
2. Configurar servidor: `https://cloud.maiahub.com.br`
3. Fazer login com `rmf` / `{{NEXTCLOUD_ADMIN_PASSWORD}}`
4. Habilitar **Auto Upload** de fotos se desejado

O app vai usar o **Notify Push** para notificações em tempo real — verificar que notificações chegam ao fechar o app.

---

## Etapa 13 — Atualizar Uptime Kuma

> Acesse `https://monitoring.maiahub.com.br` → **Add New Monitor**

Adicionar os seguintes monitores (padrão ADR-008 — endereçamento Docker interno):

**Nextcloud — health**

| Campo | Valor |
| --- | --- |
| Monitor Type | HTTP(s) |
| Friendly Name | `Nextcloud` |
| URL | `http://nextcloud/status.php` |
| Heartbeat Interval | `60` |
| Notification | Email + Telegram ✅ |

`/status.php` retorna JSON com `{"installed":true,"maintenance":false,...}` — um endpoint de health nativo do Nextcloud.

**Collabora**

| Campo | Valor |
| --- | --- |
| Monitor Type | HTTP(s) |
| Friendly Name | `Collabora` |
| URL | `http://nextcloud-collabora:9980/hosting/capabilities` |

---

## Etapa 14 — Registrar stack no Portainer

`https://portainer.maiahub.com.br → Stacks → Add Stack → Repository`

| Campo | Valor |
| --- | --- |
| Name | `cloud` |
| Repository URL | `https://github.com/{{GITHUB_USER}}/the-forge` |
| Repository reference | `refs/heads/main` |
| Compose path | `services/cloud/compose.yaml` |
| Automatic updates | desabilitado |

Clicar em **Deploy the stack**.

> Como os containers `nextcloud`, `nextcloud-db`, etc. já existem, o Portainer vai adotar a stack existente. Os containers ficam fora por alguns segundos — normal.

---

## Etapa 15 — Commitar e tagear

```bash
# Local
cd ~/projetos/the-forge

# Verificar que nenhum arquivo sensível será commitado
git status
# services/cloud/.env não deve aparecer (coberto pelo .gitignore)

git add services/cloud/ docs/phases/fase-5-nextcloud.md docs/decisions/ADR-009-nextcloud-manual-vs-aio.md
git commit -m "feat(cloud): add nextcloud stack with postgres, redis, collabora, elasticsearch, clamav, notify-push and imaginary"
git tag v1.4-nextcloud
git push && git push --tags
```

---

## Checklist final da Fase 5

### Nextcloud

- [ ] `https://cloud.maiahub.com.br` carrega com cadeado verde
- [ ] Login com `rmf` / `{{NEXTCLOUD_ADMIN_PASSWORD}}` funciona
- [ ] `Configurações → Administration → Overview` sem erros críticos em vermelho
- [ ] 7 GB de arquivos visíveis na biblioteca
- [ ] `docker exec -u www-data nextcloud php occ status` retorna `installed: true`

### Collabora

- [ ] `https://office.maiahub.com.br` responde (pode redirecionar para página de boas-vindas do Collabora)
- [ ] Abrir um arquivo `.docx` no Nextcloud abre o editor online
- [ ] `Configurações → Administration → Office` mostra conexão OK

### Elasticsearch

- [ ] Indexação concluída (`occ fulltextsearch:index` sem erros)
- [ ] Busca por conteúdo de arquivo retorna resultados (ex: buscar texto dentro de um `.pdf`)

### ClamAV

- [ ] `docker logs nextcloud-clamav --tail=5` mostra "Signatures loaded"
- [ ] Upload de arquivo completa sem erro de antivírus
- [ ] (Opcional) Arquivo EICAR de teste é bloqueado

### Notify Push

- [ ] `docker logs nextcloud-notify-push --tail=5` mostra "Starting notify_push server"
- [ ] `occ notify_push:self-test` retorna todos os itens como `✓`
- [ ] Notificação chega no app mobile ao receber um arquivo compartilhado

### Imaginary

- [ ] `docker ps | grep imaginary` mostra container `Up`
- [ ] Galeria de fotos exibe thumbnails (pode levar alguns minutos para gerar os primeiros)

### Migração de dados

- [ ] Todos os arquivos aparecem no Nextcloud Web
- [ ] Contatos visíveis em `Apps → Contacts`
- [ ] Calendários visíveis em `Apps → Calendar`
- [ ] Tarefas visíveis em `Apps → Tasks`
- [ ] Feeds RSS visíveis em `Apps → News`
- [ ] DAVx⁵ sincronizado — contatos e calendários aparecem no Android

### Monitoramento

- [ ] Monitor `Nextcloud` no Uptime Kuma com status verde
- [ ] Monitor `Collabora` no Uptime Kuma com status verde
- [ ] Stack `cloud` registrada no Portainer

### Repositório

- [ ] `services/cloud/compose.yaml` commitado
- [ ] `services/cloud/.env.example` commitado
- [ ] `services/cloud/.gitignore` commitado
- [ ] `services/cloud/.env` **não** commitado
- [ ] `docs/decisions/ADR-009-nextcloud-manual-vs-aio.md` commitado
- [ ] Tag `v1.4-nextcloud` criada

---

## Referência rápida — Operações do dia a dia

```bash
# === NEXTCLOUD — STATUS ===

# Status geral da stack
docker ps --format "table {{.Names}}\t{{.Status}}" | grep nextcloud

# Status do Nextcloud
docker exec -u www-data nextcloud php occ status

# Logs em tempo real
docker logs nextcloud -f --tail=50


# === NEXTCLOUD — MANUTENÇÃO ===

# Modo manutenção ON (para updates ou backup)
docker exec -u www-data nextcloud php occ maintenance:mode --on

# Modo manutenção OFF
docker exec -u www-data nextcloud php occ maintenance:mode --off

# Reescanear arquivos após cópia manual
docker exec -u www-data nextcloud php occ files:scan --all

# Ver apps instalados
docker exec -u www-data nextcloud php occ app:list

# Adicionar usuário
docker exec -u www-data nextcloud php occ user:add <username>


# === NEXTCLOUD — INTEGRAÇÕES ===

# Re-indexar Full Text Search
docker exec -u www-data nextcloud php occ fulltextsearch:index

# Verificar Notify Push
docker exec -u www-data nextcloud php occ notify_push:self-test

# Verificar Imaginary
docker exec -u www-data nextcloud php occ config:system:get preview_imaginary_url


# === BANCO DE DADOS ===

# Dump manual (para backup)
docker exec nextcloud-db pg_dump -U nextcloud nextcloud \
  > /mnt/data/backups/local/nextcloud_db_$(date +%Y%m%d).sql

# Acessar psql
docker exec -it nextcloud-db psql -U nextcloud -d nextcloud


# === SERVIÇOS AUXILIARES ===

# Logs ClamAV
docker logs nextcloud-clamav -f

# Logs Elasticsearch
docker logs nextcloud-elasticsearch -f

# Logs notify_push
docker logs nextcloud-notify-push -f

# Logs Collabora
docker logs nextcloud-collabora -f


# === ATUALIZAÇÃO DA STACK ===

cd /srv/the-forge/services/cloud
docker compose pull
docker exec -u www-data nextcloud php occ maintenance:mode --on
docker compose up -d
docker exec -u www-data nextcloud php occ upgrade
docker exec -u www-data nextcloud php occ maintenance:mode --off
docker exec -u www-data nextcloud php occ db:add-missing-indices
```

---

## Próxima fase

### Fase 6 — Jellyfin + Arr Stack

Servidor de mídia para filmes e séries com automação de download:

- Jellyfin em `jellyfin.maiahub.com.br` (público)
- Sonarr (séries), Radarr (filmes), Prowlarr (indexadores), qBittorrent (torrent)
- Biblioteca apontando para `/mnt/data/media/`
- Criar usuário da namorada no Jellyfin

---

_Fase 5 de 9 — Projeto Homelab_
