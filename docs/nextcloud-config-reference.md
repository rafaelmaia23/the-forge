# Nextcloud — Referência de Configuração

Estado atual da stack Nextcloud. Não contém histórico de decisões ou problemas — ver `migration-log.md` e ADRs para isso.

---

## Stack

| Container | Imagem | Porta interna | Função |
| --- | --- | --- | --- |
| `nextcloud` | `nextcloud:33-apache` | `80` | Aplicação principal (Apache + PHP) |
| `nextcloud-db` | `postgres:18` | `5432` | Banco de dados |
| `nextcloud-redis` | `redis:7-alpine` | `6379` | Cache de sessão e file locking |
| `nextcloud-collabora` | `collabora/code:latest` | `9980` | Editor de documentos (Nextcloud Office) |
| `nextcloud-elasticsearch` | `elasticsearch:9.4.2` | `9200` | Busca full-text |
| `nextcloud-clamav` | `clamav/clamav-debian:latest` | `3310` | Antivírus de uploads |
| `nextcloud-notify-push` | `nextcloud:33-apache` | `7867` | Notificações em tempo real (WebSocket) |
| `nextcloud-imaginary` | `nextcloud/aio-imaginary:latest` | `9000` | Thumbnails e previews de imagem |

> ClamAV usa a imagem `clamav-debian` (não `clamav/clamav`) — única variante com suporte ARM64.

---

## Volumes (bind mounts em `/mnt/data/nextcloud/`)

| Caminho no host | Caminho no container | Serviço | Conteúdo |
| --- | --- | --- | --- |
| `/mnt/data/nextcloud/config` | `/var/www/html/config` | nextcloud | `config.php` e configurações PHP |
| `/mnt/data/nextcloud/apps` | `/var/www/html/apps` | nextcloud | Apps bundled da imagem (não-writable) |
| `/mnt/data/nextcloud/custom_apps` | `/var/www/html/custom_apps` | nextcloud, notify-push | Apps instalados via occ (writable) |
| `/mnt/data/nextcloud/userdata` | `/var/www/html/data` | nextcloud | Arquivos dos usuários |
| `/mnt/data/nextcloud/db` | `/var/lib/postgresql` | nextcloud-db | Banco PostgreSQL 18 |
| `/mnt/data/nextcloud/redis` | `/data` | nextcloud-redis | Persistência Redis |
| `/mnt/data/nextcloud/elasticsearch` | `/usr/share/elasticsearch/data` | nextcloud-elasticsearch | Índice de busca |

**Permissões especiais:**
- `custom_apps`: dono `33:33` (www-data) — `sudo chown -R 33:33 /mnt/data/nextcloud/custom_apps`
- `elasticsearch`: dono `1000:1000` (elasticsearch) — `sudo chown -R 1000:1000 /mnt/data/nextcloud/elasticsearch`

---

## Redes Docker

| Rede | Tipo | Containers |
| --- | --- | --- |
| `proxy` | external (bridge) | nextcloud, nextcloud-collabora, nextcloud-notify-push |
| `nextcloud_internal` | internal | todos |

---

## NPM — Proxy hosts

### cloud.maiahub.com.br

| Campo | Valor |
| --- | --- |
| Scheme | `http` |
| Forward | `nextcloud:80` |
| SSL | `cloud.maiahub.com.br` (Let's Encrypt via Cloudflare DNS) |
| Force SSL | ✅ |
| HTTP/2 | ✅ |
| HSTS | ✅ (63072000s) |
| Block Exploits | ✅ |
| Advanced config | `client_max_body_size 0;` |

### office.maiahub.com.br

| Campo | Valor |
| --- | --- |
| Scheme | `http` |
| Forward | `nextcloud-collabora:9980` |
| WebSocket Support | ✅ |
| SSL | `office.maiahub.com.br` (Let's Encrypt via Cloudflare DNS) |
| Force SSL | ✅ |
| HTTP/2 | ✅ |
| Advanced config | `proxy_set_header X-Forwarded-Proto $scheme;` + `proxy_read_timeout 36000s;` |

> Acessar `office.maiahub.com.br` diretamente retorna apenas `ok` — comportamento correto. O Collabora não tem interface própria; funciona somente embutido no Nextcloud.

### /push — Roteamento notify_push

O roteamento do `/push` é feito via `/data/nginx/custom/server_proxy.conf` dentro do container `npm` (arquivo persistido no volume do NPM, não gerenciado pela UI):

```nginx
location /push {
    resolver 127.0.0.11 valid=30s;
    set $push_host "http://nextcloud-notify-push:7867";
    rewrite ^/push/?(.*)$ /$1 break;
    proxy_pass $push_host;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
}
```

**Por que esta abordagem:**
- O Custom Locations tab do NPM + Advanced config causa falha silenciosa na geração do `.conf`
- `server_proxy.conf` é incluído automaticamente em todos os server blocks pelo template do NPM
- O `rewrite` é necessário para remover o prefixo `/push` antes de encaminhar ao binário
- O `resolver 127.0.0.11` com variável em `proxy_pass` evita erro de DNS na inicialização

**Para recriar após perda do volume NPM:**
```bash
docker exec npm mkdir -p /data/nginx/custom
docker exec npm sh -c 'cat > /data/nginx/custom/server_proxy.conf << '"'"'EOF'"'"'
location /push {
    resolver 127.0.0.11 valid=30s;
    set $push_host "http://nextcloud-notify-push:7867";
    rewrite ^/push/?(.*)$ /$1 break;
    proxy_pass $push_host;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
}
EOF'
docker exec npm nginx -t && docker exec npm nginx -s reload
```

---

## Parâmetros de kernel (VM)

Adicionados em `/etc/sysctl.conf`:

```ini
vm.overcommit_memory=1
vm.max_map_count=262144
```

- `vm.overcommit_memory=1` — exigido pelo Redis para alocação de memória
- `vm.max_map_count=262144` — exigido pelo Elasticsearch

---

## config.php — Configurações relevantes

```php
'trusted_domains' => array(
  0 => 'localhost',
  1 => 'cloud.maiahub.com.br',
  2 => 'nextcloud',              // necessário para notify_push (NEXTCLOUD_URL=http://nextcloud)
),
'trusted_proxies' => array(
  0 => '172.16.0.0/12',         // cobre todas as redes Docker
),
'overwriteprotocol' => 'https',
'overwrite.cli.url' => 'https://cloud.maiahub.com.br',
'redis' => array(
  'host' => 'nextcloud-redis',
  'port' => 6379,
  'password' => '...',           // ver secrets.env
),
'memcache.distributed' => '\OC\Memcache\Redis',
'memcache.locking' => '\OC\Memcache\Redis',
'maintenance_window_start' => 6, // 6h UTC = 3h horário de Brasília
```

---

## Extra hosts — Hairpin NAT

Os containers `nextcloud` e `nextcloud-collabora` têm `extra_hosts` no compose.yaml para resolver domínios internamente via NPM — sem precisar de hairpin NAT:

```yaml
# nextcloud
extra_hosts:
  - "cloud.maiahub.com.br:172.18.0.3"
  - "office.maiahub.com.br:172.18.0.3"

# nextcloud-collabora
extra_hosts:
  - "cloud.maiahub.com.br:172.18.0.3"
```

- `nextcloud` precisa de `cloud.maiahub.com.br` para `notify_push:setup` e `office.maiahub.com.br` para validar o Collabora
- `nextcloud-collabora` precisa de `cloud.maiahub.com.br` para fazer as requisições WOPI de volta ao Nextcloud

**O IP do NPM pode mudar** após recriação de containers. Para verificar o IP atual:
```bash
docker inspect npm --format '{{(index .NetworkSettings.Networks "proxy").IPAddress}}'
```

Se mudar, atualizar o `extra_hosts` no compose.yaml e recriar o container nextcloud.

---

## Redis — Senha

A senha do Redis deve ser gerada **sem caracteres especiais** (hex puro):

```bash
openssl rand -hex 32
```

`openssl rand -base64 32` gera senhas com `+`, `/`, `=`, `&`, `#` que quebram:
1. O arquivo `.env` (`#` é tratado como comentário, `&` separa parâmetros)
2. A URL do PHP session handler (`tcp://host:port?auth=PASSWORD` onde `&` e `#` têm significado especial)

O PHP session handler (`session.save_path`) é configurado pelo entrypoint da imagem a partir da env var `REDIS_HOST_PASSWORD`. Só atualiza com `docker compose up -d --force-recreate`, não com `docker compose restart`.

---

## Apps instalados

### Bundled (em `apps/`)
calendar, photos, files_pdfviewer, files_reminders, files_downloadlimit, text, activity, dashboard, bruteforcesettings, password_policy, privacy, twofactor_totp, twofactor_backupcodes, admin_audit, serverinfo, logreader, viewer, notifications, dav, e outros apps core.

### Instalados via occ (em `custom_apps/`)
| App | Versão | Função |
| --- | --- | --- |
| `contacts` | 8.7.0 | Agenda de contatos |
| `deck` | 1.17.3 | Kanban |
| `tasks` | 0.17.1 | Tarefas (CalDAV) |
| `notes` | 6.0.0 | Notas |
| `news` | 28.6.0 | Leitor RSS |
| `whiteboard` | 1.5.9 | Quadro branco |
| `richdocuments` | 10.2.0 | Nextcloud Office (Collabora) |
| `fulltextsearch` | 33.0.0 | Motor de busca full-text |
| `fulltextsearch_elasticsearch` | 33.0.0 | Conector Elasticsearch |
| `files_fulltextsearch` | 33.0.0 | Indexação de conteúdo de arquivos |
| `files_antivirus` | 6.3.0 | Antivírus via ClamAV |
| `notify_push` | 1.3.3 | Notificações push em tempo real |
| `dav_push` | 1.0.1 | Push para CalDAV/CardDAV |
| `suspicious_login` | - | Detecção de logins suspeitos (ML) |

---

## notify_push — Sidecar

O binário `notify_push` corre como container separado usando a imagem `nextcloud:33-apache`:

```yaml
entrypoint: /var/www/html/custom_apps/notify_push/bin/aarch64/notify_push
command: /var/www/html/config/config.php
environment:
  - PORT=7867
  - NEXTCLOUD_URL=http://nextcloud
```

**Comportamento esperado:** o container reinicia até que o app `notify_push` esteja instalado em `custom_apps`. Após instalação, inicia normalmente.

**Self-test:**
```bash
docker exec -u www-data nextcloud php occ notify_push:self-test
# Todos os itens devem mostrar ✓
```

---

## Background jobs — Cron

O modo de background jobs foi trocado de Ajax para Cron. Cron job adicionado no host (`crontab -e` do usuário `ubuntu`):

```
*/5 * * * * docker exec -u www-data nextcloud php -f /var/www/html/cron.php
```

Modo configurado em: **Configurações → Administration → Basic settings → Background jobs → Cron**

---

## CalDAV — Rate limit de criação de calendários

O app `dav` tem rate limit para criação de novos calendários/listas de tarefas:

- **Limite:** 10 criações por hora (padrão)
- **Config:** `occ config:app:set dav rateLimitCalendarCreation --value=N` (limite) e `rateLimitPeriodCalendarCreation` (período em segundos)
- **Backend:** `OC\Security\RateLimiting\Backend\MemoryCacheBackend` usando Redis como distributed cache
- **Chaves Redis:** padrão `*RateLimiting*` com array JSON de timestamps de expiração

**Para migração de muitos calendários**, aumentar o limite temporariamente:
```bash
docker exec -u www-data nextcloud php occ config:app:set dav rateLimitCalendarCreation --value=100
# importar tudo
docker exec -u www-data nextcloud php occ config:app:delete dav rateLimitCalendarCreation
```

**Arquivo crítico** (não modificar): `apps/dav/lib/CalDAV/Security/RateLimitingPlugin.php` — está no bind mount `/mnt/data/nextcloud/apps/`. Qualquer edição persiste no host.

---

## Integrações (Etapa 9)

| Integração | Status | Configuração |
| --- | --- | --- |
| Notify Push | ✅ | `occ notify_push:setup https://cloud.maiahub.com.br/push` |
| Collabora | ✅ | Admin → Office → `https://office.maiahub.com.br` |
| Elasticsearch FTS | ✅ | Admin → Full text search → `http://nextcloud-elasticsearch:9200` |
| ClamAV | ✅ | `av_mode=daemon`, `av_host=nextcloud-clamav`, `av_port=3310` (via occ config:app:set) |
| Imaginary | ✅ | `occ config:system:set enabledPreviewProviders 0 --value="OC\\Preview\\Imaginary"` + `preview_imaginary_url` |

**wopi_allowlist** (necessário para Collabora funcionar):
```bash
occ config:app:set richdocuments wopi_allowlist --value="172.16.0.0/12"
```

**Portainer:** registrar a stack `cloud` apenas como "external" (sem deixar o Portainer gerenciar o deploy). Se o Portainer reimplantar a stack, ele não lê o `.env` local e os containers sobem sem variáveis de ambiente.
