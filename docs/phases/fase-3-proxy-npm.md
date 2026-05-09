# Fase 3 — Proxy Reverso (Nginx Proxy Manager)

## Guia de Execução Completo

**Projeto:** Homelab
**Fase:** 3 de 9
**Objetivo:** Ponto de entrada único para todo tráfego HTTP/HTTPS com SSL wildcard automático e controle de acesso por IP
**Tempo estimado:** 1–2 horas
**Pré-requisito:** Fase 2 concluída — AdGuard Home no ar, Override DNS do Tailscale ativo, domínio `maiahub.com.br` gerenciado pelo Cloudflare

---

## O que esta fase entrega

Ao final desta fase:

- Nginx Proxy Manager rodando como container Docker na VM
- Certificado SSL wildcard `*.maiahub.com.br` emitido e renovado automaticamente via DNS Challenge (Cloudflare)
- Access List `tailscale-only` configurada — painéis de controle acessíveis apenas na rede Tailscale
- Proxy host para o próprio painel NPM (`npm.maiahub.com.br`) com SSL e restrição Tailscale
- Proxy host para o painel AdGuard (`adguard.maiahub.com.br`) com SSL e restrição Tailscale
- Regra UFW temporária da Fase 2 (porta 3000 direta) removida — AdGuard acessível apenas via proxy

---

## Decisões arquiteturais desta fase

| Decisão | Escolha | Motivo |
| --- | --- | --- |
| Software de proxy | Nginx Proxy Manager | Interface gráfica, DNS Challenge nativo, Access Lists sem configuração extra |
| Banco de dados | MariaDB (container `npm-db`) | Compatível com o plano de backup da Fase 8 (`mysqldump`); mais robusto que SQLite para produção |
| Certificado | Wildcard `*.maiahub.com.br` via DNS Challenge | HTTP Challenge não suporta wildcard; DNS Challenge não depende de porta 80 exposta |
| Provider DNS Challenge | Cloudflare | Domínio já gerenciado pelo Cloudflare; API madura com suporte nativo no NPM |
| Armazenamento de certificados | Bind mount `./letsencrypt` | Path previsível (`/srv/the-forge/services/proxy/letsencrypt/`) facilita backup da Fase 8 |
| Acesso ao painel NPM | Exclusivo Tailscale (Access List) | Painel de administração não deve ser exposto publicamente |

---

## Etapa 1 — Preparar a estrutura na máquina local

> Faça esta etapa na sua **máquina local**.

### 1.1 — Criar a estrutura de diretórios

```bash
cd ~/projetos/the-forge
mkdir -p services/proxy
```

### 1.2 — Criar o compose.yaml

```bash
cat > services/proxy/compose.yaml << 'EOF'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    environment:
      DB_MYSQL_HOST: npm-db
      DB_MYSQL_NAME: ${NPM_DB_NAME}
      DB_MYSQL_USER: ${NPM_DB_USER}
      DB_MYSQL_PASSWORD: ${NPM_DB_PASSWORD}
    volumes:
      - npm_data:/data
      - ./letsencrypt:/etc/letsencrypt
    depends_on:
      - npm-db
    networks:
      - proxy
      - npm_internal

  npm-db:
    image: jc21/mariadb-aria:latest
    container_name: npm-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${NPM_DB_ROOT_PASSWORD}
      MYSQL_DATABASE: ${NPM_DB_NAME}
      MYSQL_USER: ${NPM_DB_USER}
      MYSQL_PASSWORD: ${NPM_DB_PASSWORD}
    volumes:
      - npm_db:/var/lib/mysql
    networks:
      - npm_internal

networks:
  proxy:
    external: true
  npm_internal:
    driver: bridge
    internal: true

volumes:
  npm_data:
  npm_db:
EOF
```

**Por que dois containers:**

- `npm` → a aplicação proxy em si; lê o estado do banco e gerencia o Nginx internamente
- `npm-db` → MariaDB isolado na rede `npm_internal` — não exposto para outras stacks

**Por que `letsencrypt/` como bind mount e não volume nomeado:**

O diretório `./letsencrypt` fica em `/srv/the-forge/services/proxy/letsencrypt/` — path fixo e previsível que o script de backup da Fase 8 já referencia. Com volume nomeado, o path seria dentro de `/var/lib/docker/volumes/...` e exigiria mapeamento extra no backup. O diretório já está coberto pelo `.gitignore` do projeto (`**/letsencrypt/`).

**Por que a porta 81 está exposta:**

Necessária para acesso inicial ao painel de administração antes de criar o proxy host. Após criar o proxy host `npm.maiahub.com.br`, o acesso ao painel se dá via HTTPS na porta 443. A porta 81 pode ser removida do `ports:` após isso — o NPM acessa o próprio painel pelo container `npm` na rede `proxy` interna.

> **Nota de segurança:** A porta 81 só é acessível via Tailscale porque o UFW bloqueia todo tráfego externo por padrão. Mesmo assim, criar o proxy host e remover a porta 81 é uma boa prática.

### 1.3 — Criar o .env.example

```bash
cat > services/proxy/.env.example << 'EOF'
# Banco de dados do NPM
NPM_DB_NAME=npm
NPM_DB_USER=npm
NPM_DB_PASSWORD=
NPM_DB_ROOT_PASSWORD=
EOF
```

### 1.4 — Criar o .gitignore do serviço

```bash
cat > services/proxy/.gitignore << 'EOF'
# Certificados e chaves privadas — nunca commitar
letsencrypt/

# .env com credenciais reais
.env
EOF
```

> O `.gitignore` raiz já cobre `**/letsencrypt/` e `*.env`, mas um `.gitignore` local torna a intenção explícita para quem lê o diretório.

### 1.5 — Commitar a estrutura

```bash
git add services/proxy/
git commit -m "feat(proxy): add Nginx Proxy Manager service structure"
git push
```

---

## Etapa 2 — Criar o .env na VM

> A partir daqui, tudo na **VM via SSH**.

```bash
ssh homelab
```

### 2.1 — Atualizar o repositório

```bash
cd /srv/the-forge && git pull
```

### 2.2 — Verificar se as portas 80 e 443 estão livres

```bash
sudo ss -tulnp | grep -E ':80|:443|:81'
```

Não deve aparecer nada ocupando essas portas. Se aparecer, identificar o processo e parar antes de continuar.

### 2.3 — Criar o .env com as credenciais reais

```bash
cd /srv/the-forge/services/proxy

# Gerar senhas fortes
NPM_DB_PASSWORD=$(openssl rand -base64 24)
NPM_DB_ROOT_PASSWORD=$(openssl rand -base64 24)

cat > .env << EOF
NPM_DB_NAME=npm
NPM_DB_USER=npm
NPM_DB_PASSWORD=${NPM_DB_PASSWORD}
NPM_DB_ROOT_PASSWORD=${NPM_DB_ROOT_PASSWORD}
EOF

chmod 600 .env

# Anotar as senhas no secrets.env local para referência futura
echo "NPM_DB_PASSWORD=${NPM_DB_PASSWORD}" >> ~/.homelab/secrets.env
echo "NPM_DB_ROOT_PASSWORD=${NPM_DB_ROOT_PASSWORD}" >> ~/.homelab/secrets.env
```

---

## Etapa 3 — Subir o NPM

```bash
cd /srv/the-forge/services/proxy
docker compose up -d

# Acompanhar a inicialização
docker compose logs -f --tail=50
```

Aguardar até aparecer algo como `started` ou `listening on`. A primeira inicialização pode levar 30–60 segundos enquanto o MariaDB prepara o schema.

```bash
# Verificar que ambos os containers estão rodando
docker ps | grep npm
```

Deve mostrar `npm` e `npm-db` com status `Up`.

---

## Etapa 4 — Configuração inicial pelo painel

> Acesse o painel via **navegador na sua máquina local**.

O painel de administração está em: `http://{{OCI_TS_IP}}:81`

> Use o IP Tailscale da VM — não o IP público Oracle.

### 4.1 — Primeiro acesso

Credenciais padrão do NPM:

| Campo | Valor padrão |
| --- | --- |
| Email | `admin@example.com` |
| Senha | `changeme` |

Ao entrar, o NPM imediatamente solicita a troca de email e senha. Definir:

- **Email:** seu email real
- **Nome:** como preferir
- **Senha:** forte, gerada com `openssl rand -base64 24`

Anotar a nova senha no `~/.homelab/secrets.env` da VM.

---

## Etapa 5 — Emitir certificado wildcard

`SSL Certificates → Add SSL Certificate → Let's Encrypt`

### 5.1 — Preencher o formulário

| Campo | Valor |
| --- | --- |
| Domain Names | `*.maiahub.com.br` |
| Email Address | seu email |
| Use a DNS Challenge | ✅ habilitado |
| DNS Provider | Cloudflare |
| Credentials File Content | (ver abaixo) |
| Propagation Seconds | 60 |
| I Agree to ToS | ✅ |

**Credentials File Content** — colar exatamente neste formato:

```
dns_cloudflare_api_token = {{CF_API_TOKEN}}
```

> O token precisa ter permissão **Zone:DNS:Edit** para a zona `maiahub.com.br`. Criar em `dash.cloudflare.com → My Profile → API Tokens → Create Token → Edit zone DNS`.

### 5.2 — Salvar e aguardar

Clicar em **Save**. O NPM vai:

1. Criar um registro TXT `_acme-challenge.maiahub.com.br` no Cloudflare via API
2. Aguardar a propagação (60s configurado)
3. Solicitar o certificado à Let's Encrypt
4. Remover o registro TXT

O processo leva 1–3 minutos. Ao concluir, o certificado aparece na lista com validade de 90 dias (renovação automática pelo NPM).

**Se falhar com "Timeout" ou "DNS record not found":** aumentar Propagation Seconds para 120 e tentar novamente.

---

## Etapa 6 — Criar Access List tailscale-only

`Access Lists → Add Access List`

| Campo | Valor |
| --- | --- |
| Name | `tailscale-only` |
| Satisfy Any | desabilitado |
| Pass Auth to Host | desabilitado |

Na seção **Allow**:

| Address | (vazio) |
| --- | --- |
| `100.64.0.0/10` | — |

Na seção **Deny** (já vem preenchido):

| Address |
| --- |
| `all` |

Salvar.

> O range `100.64.0.0/10` é o espaço de endereços CGNAT usado pelo Tailscale para todos os dispositivos da rede. Qualquer cliente Tailscale tem IP nesse range e passa pela Access List; clientes externos são bloqueados automaticamente pelo `deny all`.

---

## Etapa 7 — Criar proxy hosts

`Proxy Hosts → Add Proxy Host`

### 7.1 — Painel NPM

| Campo | Valor |
| --- | --- |
| Domain Names | `npm.maiahub.com.br` |
| Scheme | `http` |
| Forward Hostname/IP | `npm` |
| Forward Port | `81` |
| Block Common Exploits | ✅ |

Aba **SSL**:

| Campo | Valor |
| --- | --- |
| SSL Certificate | `*.maiahub.com.br` (o que acabamos de emitir) |
| Force SSL | ✅ |
| HTTP/2 Support | ✅ |

Aba **Access List**:

| Campo | Valor |
| --- | --- |
| Access List | `tailscale-only` |

Salvar.

Testar acessando `https://npm.maiahub.com.br` num dispositivo com Tailscale conectado — deve abrir o painel NPM com cadeado verde.

### 7.2 — Painel AdGuard

| Campo | Valor |
| --- | --- |
| Domain Names | `adguard.maiahub.com.br` |
| Scheme | `http` |
| Forward Hostname/IP | `adguard` |
| Forward Port | `3000` |
| Block Common Exploits | ✅ |

Aba **SSL**: mesmas configurações do NPM (certificado wildcard, Force SSL, HTTP/2).

Aba **Access List**: `tailscale-only`.

Salvar.

Testar acessando `https://adguard.maiahub.com.br` via Tailscale.

---

## Etapa 8 — Atualizar DNS Rewrite no AdGuard

As fases seguintes vão criar mais serviços. Adicionar os DNS Rewrites no AdGuard agora para não precisar voltar depois:

`Filters → DNS rewrites → Add DNS rewrite`

| Domain | Answer |
| --- | --- |
| `portainer.maiahub.com.br` | `{{OCI_PUBLIC_IP}}` |
| `monitoring.maiahub.com.br` | `{{OCI_PUBLIC_IP}}` |
| `netdata.maiahub.com.br` | `{{OCI_PUBLIC_IP}}` |
| `jellyfin.maiahub.com.br` | `{{OCI_PUBLIC_IP}}` |
| `dawarich.maiahub.com.br` | `{{OCI_PUBLIC_IP}}` |

> Os rewrites `cloud.maiahub.com.br`, `adguard.maiahub.com.br` e `npm.maiahub.com.br` já foram criados na Fase 2.

---

## Etapa 9 — Remover regra UFW temporária da Fase 2

Na Fase 2, abrimos a porta 3000 diretamente para acessar o AdGuard via Tailscale. Com o NPM no ar e o proxy host criado, esse acesso direto não é mais necessário:

```bash
# Verificar o número da regra antes de deletar
sudo ufw status numbered

# Remover as regras da porta 3000 (identificar pelo número na listagem acima)
# Exemplo — confirmar o número correto antes de executar:
sudo ufw delete <número-da-regra-3000-tailscale>
```

Após remover:

```bash
# Confirmar que a regra foi removida
sudo ufw status | grep 3000
# Não deve aparecer nada
```

Testar que `https://adguard.maiahub.com.br` ainda funciona via Tailscale (acesso via proxy NPM).

---

## Etapa 10 — Versionar

```bash
# Na máquina local, confirmar que nada sensível foi commitado
cd ~/projetos/the-forge
git status

# O .gitignore já cobre letsencrypt/ e .env — confirmar visualmente
git diff --cached

# Não há arquivos novos para commitar nesta etapa (compose.yaml já foi commitado no passo 1.5)
# Se tiver algum arquivo de config que foi ajustado:
git add services/proxy/
git commit -m "feat(proxy): bring up NPM with MariaDB and wildcard SSL

- Wildcard cert *.maiahub.com.br via Cloudflare DNS Challenge
- Access List tailscale-only: 100.64.0.0/10
- Proxy hosts: npm.maiahub.com.br, adguard.maiahub.com.br
- Direct UFW rule for AdGuard port 3000 removed"
git push
```

---

## Checklist final da Fase 3

### Containers

- [ ] `docker ps` mostra `npm` e `npm-db` com status `Up`
- [ ] `docker logs npm --tail 30` sem erros críticos
- [ ] `docker logs npm-db --tail 30` sem erros críticos

### Certificado SSL

- [ ] Certificado `*.maiahub.com.br` listado em SSL Certificates com status válido
- [ ] Data de expiração é 90 dias a partir de hoje (renovação automática configurada)

### Access List

- [ ] Access List `tailscale-only` criada com `allow 100.64.0.0/10` e `deny all`

### Proxy Hosts

- [ ] `https://npm.maiahub.com.br` abre com cadeado verde via Tailscale
- [ ] `https://npm.maiahub.com.br` retorna 403/bloqueado de IP fora do Tailscale
- [ ] `https://adguard.maiahub.com.br` abre com cadeado verde via Tailscale
- [ ] `https://adguard.maiahub.com.br` retorna 403/bloqueado de IP fora do Tailscale

### DNS

- [ ] DNS Rewrites para fases futuras adicionados no AdGuard (portainer, monitoring, netdata, jellyfin, dawarich)
- [ ] `dig @{{OCI_TS_IP}} npm.maiahub.com.br` retorna `{{OCI_PUBLIC_IP}}`

### Limpeza

- [ ] Regra UFW da porta 3000 removida (`sudo ufw status` não mostra regra para 3000)
- [ ] Acesso ao AdGuard via `https://adguard.maiahub.com.br` ainda funciona após remoção da regra

### Repositório

- [ ] `services/proxy/compose.yaml` commitado
- [ ] `services/proxy/.env.example` commitado
- [ ] `services/proxy/.gitignore` commitado
- [ ] `services/proxy/letsencrypt/` **não** commitado (coberto pelo .gitignore)
- [ ] `services/proxy/.env` **não** commitado

---

## Referência rápida — Operações do NPM

```bash
# Ver status dos containers
docker ps | grep npm

# Logs do NPM
docker compose -f /srv/the-forge/services/proxy/compose.yaml logs -f --tail=50

# Reiniciar NPM (sem derrubar MariaDB)
docker restart npm

# Reiniciar toda a stack
cd /srv/the-forge/services/proxy && docker compose restart

# Atualizar imagem
cd /srv/the-forge/services/proxy
docker compose pull && docker compose up -d

# Verificar certificados no container
docker exec npm ls /etc/letsencrypt/live/

# Forçar renovação de certificado (normalmente automática)
docker exec npm sh -c "cd /app && node index.js certbot renew"

# Ver regras UFW atuais
sudo ufw status numbered

# Testar proxy host do terminal
curl -sk https://npm.maiahub.com.br -o /dev/null -w "%{http_code}\n"
# Deve retornar 200 (ou 301/302 para redirect) se vier de IP Tailscale
```

---

## Próxima fase

### Fase 4 — Gerenciamento e Monitoramento (Portainer + Uptime Kuma + Netdata)

Com o NPM no ar e o wildcard SSL configurado, as fases seguintes são diretas: subir o serviço, criar o proxy host no NPM e adicionar o monitor no Uptime Kuma (quando estiver no ar). O DNS Rewrite já foi criado nesta fase.

Fase 4 entrega:
- **Portainer** — gerenciamento visual de containers via `portainer.maiahub.com.br`
- **Uptime Kuma** — monitoramento de uptime e alertas via `monitoring.maiahub.com.br`
- **Netdata** — métricas em tempo real do servidor via `netdata.maiahub.com.br`

---

_Fase 3 de 9 — Projeto Homelab_
