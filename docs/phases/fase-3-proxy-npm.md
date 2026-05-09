# Fase 3 — Proxy Reverso (Nginx Proxy Manager)

## Guia de Execução Completo

**Projeto:** Homelab
**Fase:** 3 de 9
**Objetivo:** Ponto de entrada único para tráfego HTTP/HTTPS com SSL individual por serviço e controle de acesso por IP
**Tempo estimado:** 1–2 horas
**Pré-requisito:** Fase 2 concluída — AdGuard no ar, override DNS do Tailscale ativo, DNS Rewrites `npm.maiahub.com.br` e `adguard.maiahub.com.br` já criados

---

## O que esta fase entrega

Ao final desta fase:

- Nginx Proxy Manager rodando como container Docker na VM
- Certificado SSL individual para `npm.maiahub.com.br` via DNS Challenge (Cloudflare)
- Certificado SSL individual para `adguard.maiahub.com.br` via DNS Challenge (Cloudflare)
- Access List `tailscale-only` configurada — painéis acessíveis apenas na rede Tailscale
- Proxy host `npm.maiahub.com.br` com HTTPS e restrição Tailscale
- Proxy host `adguard.maiahub.com.br` com HTTPS e restrição Tailscale
- Porta 81 removida do compose.yaml — painel NPM acessível apenas via proxy
- Regra UFW temporária da Fase 2 (porta 3000 direta ao AdGuard) removida

---

## Decisões arquiteturais desta fase

| Decisão | Escolha | Motivo |
| --- | --- | --- |
| Software de proxy | Nginx Proxy Manager | Interface gráfica, DNS Challenge nativo, Access Lists sem configuração extra |
| Database | SQLite (default NPM) | Sem container extra; adequado para uso pessoal sem perdas de funcionalidade |
| Certificados | Um por serviço via DNS Challenge | Isola cada serviço; DNS Challenge é necessário para domínios tailscale-only (HTTP Challenge requer acesso externo ao port 80) |
| Storage | Bind mounts `./data` e `./letsencrypt` | Padrão oficial NPM; paths previsíveis e diretos para o backup da Fase 8 |
| Porta 81 | Remover do compose após setup | Painel acessível só via HTTPS; recuperação de emergência via SSH se necessário |

---

## Por que DNS Challenge para todos os serviços

O Let's Encrypt oferece dois mecanismos de verificação:

- **HTTP-01:** verifica colocando um arquivo em `http://domínio/.well-known/acme-challenge/`. Não funciona para serviços tailscale-only — os servidores da Let's Encrypt (internet pública) são bloqueados pela Access List do NPM.
- **DNS-01:** verifica adicionando um registro TXT `_acme-challenge.domínio` no DNS público (Cloudflare). Não depende de acesso HTTP ao servidor — funciona para qualquer domínio, privado ou público.

Como todos os painéis de controle são tailscale-only, DNS Challenge é obrigatório para eles. Por consistência, usamos DNS Challenge para todos os serviços do homelab.

---

## Etapa 1 — Preparar a estrutura na máquina local

> Faça esta etapa na sua **máquina local**.

### 1.1 — Criar o compose.yaml

```bash
mkdir -p ~/projetos/the-forge/services/proxy

cat > ~/projetos/the-forge/services/proxy/compose.yaml << 'EOF'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - proxy

networks:
  proxy:
    external: true
EOF
```

**Por que dois bind mounts e não volumes nomeados:**

- `./data` → SQLite DB + configuração interna do NPM. Path fixo em `/srv/the-forge/services/proxy/data/` — incluído diretamente no backup Restic da Fase 8.
- `./letsencrypt` → certificados e chaves privadas. Mesmo path previsível para backup. Já coberto pelo `.gitignore` do serviço.

Ambos seguem o padrão da documentação oficial do NPM.

**Por que a porta 81 está aqui inicialmente:**

Necessária para o primeiro acesso ao painel antes de criar o proxy host. Será removida na Etapa 10 após o proxy estar verificado.

### 1.2 — Criar o .gitignore do serviço

```bash
cat > ~/projetos/the-forge/services/proxy/.gitignore << 'EOF'
# Dados de runtime do NPM (SQLite DB, configuração interna, logs)
data/

# Certificados e chaves privadas — gerados pelo Let's Encrypt
letsencrypt/
EOF
```

> Esses padrões são específicos do NPM e ficam aqui, não no `.gitignore` raiz do projeto.

### 1.3 — Commitar

```bash
cd ~/projetos/the-forge
git add services/proxy/
git commit -m "feat(proxy): add Nginx Proxy Manager service structure"
git push
```

---

## Etapa 2 — Preparar a VM

> A partir daqui, tudo na **VM via SSH**.

```bash
ssh homelab
```

### 2.1 — Atualizar o repositório

```bash
cd /srv/the-forge && git pull
```

### 2.2 — Verificar se as portas estão livres

```bash
sudo ss -tulnp | grep -E ':80 |:443 |:81 '
```

Não deve aparecer nada. Se aparecer, identificar o processo e parar antes de continuar.

---

## Etapa 3 — Subir o NPM

```bash
cd /srv/the-forge/services/proxy
docker compose up -d

# Acompanhar inicialização (aguardar ~30s)
docker logs npm --tail 30 -f
```

Aguardar aparecer algo como `Server Listening on port 81` antes de continuar.

```bash
# Confirmar que está rodando
docker ps | grep npm
```

---

## Etapa 4 — Configuração inicial do painel

> Acesse via **navegador na sua máquina local**.

Painel em: `http://{{OCI_TS_IP}}:81`

### 4.1 — Primeiro acesso

Credenciais padrão:

| Campo | Valor |
| --- | --- |
| Email | `admin@example.com` |
| Senha | `changeme` |

O NPM solicita imediatamente a troca. Definir:

- **Email:** seu email real
- **Nome:** como preferir
- **Senha:** forte — `openssl rand -base64 24`

Anotar a senha em `~/.homelab/secrets.env` na VM:

```bash
echo "NPM_ADMIN_PASSWORD=<senha>" >> ~/.homelab/secrets.env
```

---

## Etapa 5 — Criar Access List tailscale-only

`Access Lists → Add Access List`

| Campo | Valor |
| --- | --- |
| Name | `tailscale-only` |
| Satisfy Any | desabilitado |
| Pass Auth to Host | desabilitado |

Na seção **Allow**:

```
100.64.0.0/10
```

Na seção **Deny**: `all` (já preenchido por padrão).

Salvar.

> `100.64.0.0/10` é o espaço CGNAT do Tailscale — todos os dispositivos da sua rede têm IP nesse range. Qualquer IP externo é bloqueado automaticamente pelo `deny all`.

---

## Etapa 6 — Emitir certificado: npm.maiahub.com.br

`SSL Certificates → Add SSL Certificate → Let's Encrypt`

| Campo | Valor |
| --- | --- |
| Domain Names | `npm.maiahub.com.br` |
| Email Address | seu email |
| Use a DNS Challenge | ✅ habilitado |
| DNS Provider | Cloudflare |
| Credentials File Content | ver abaixo |
| Propagation Seconds | `60` |
| I Agree to ToS | ✅ |

**Credentials File Content** (colar exatamente assim):

```
dns_cloudflare_api_token = {{CF_API_TOKEN}}
```

> O token precisa de permissão **Zone:DNS:Edit** para `maiahub.com.br`. Criar em `dash.cloudflare.com → My Profile → API Tokens → Create Token → Edit zone DNS`.

Clicar em **Save**. O NPM vai:
1. Adicionar `_acme-challenge.npm.maiahub.com.br` TXT no Cloudflare via API
2. Aguardar propagação (60s)
3. Let's Encrypt verifica o TXT no DNS público do Cloudflare
4. Certificado emitido — TXT removido automaticamente

Processo leva 1–3 minutos. Se falhar com timeout, aumentar para 120s e tentar novamente.

---

## Etapa 7 — Criar proxy host: npm.maiahub.com.br

`Proxy Hosts → Add Proxy Host`

**Aba Details:**

| Campo | Valor |
| --- | --- |
| Domain Names | `npm.maiahub.com.br` |
| Scheme | `http` |
| Forward Hostname/IP | `npm` |
| Forward Port | `81` |
| Block Common Exploits | ✅ |

**Aba SSL:**

| Campo | Valor |
| --- | --- |
| SSL Certificate | `npm.maiahub.com.br` |
| Force SSL | ✅ |
| HTTP/2 Support | ✅ |

**Aba Access List:**

| Campo | Valor |
| --- | --- |
| Access List | `tailscale-only` |

Salvar e testar: `https://npm.maiahub.com.br` via Tailscale deve abrir com cadeado verde.

---

## Etapa 8 — Emitir certificado: adguard.maiahub.com.br

Repetir o processo da Etapa 6, alterando apenas o domain:

| Campo | Valor |
| --- | --- |
| Domain Names | `adguard.maiahub.com.br` |

O restante das configurações (Cloudflare, token, propagation) é idêntico.

---

## Etapa 9 — Criar proxy host: adguard.maiahub.com.br

Repetir o processo da Etapa 7, com:

| Campo | Valor |
| --- | --- |
| Domain Names | `adguard.maiahub.com.br` |
| Forward Hostname/IP | `adguard` |
| Forward Port | `3000` |
| SSL Certificate | `adguard.maiahub.com.br` |

Testar: `https://adguard.maiahub.com.br` via Tailscale deve abrir o painel AdGuard com cadeado verde.

---

## Etapa 10 — Remover porta 81 do compose.yaml

> Somente após verificar que `https://npm.maiahub.com.br` está funcionando.

### 10.1 — Editar o compose.yaml localmente

Remover a linha `- "81:81"` da seção `ports`:

```yaml
# Antes:
ports:
  - "80:80"
  - "443:443"
  - "81:81"

# Depois:
ports:
  - "80:80"
  - "443:443"
```

### 10.2 — Commitar e aplicar na VM

```bash
# Local
git add services/proxy/compose.yaml
git commit -m "feat(proxy): remove direct port 81 after proxy host verified"
git push

# VM
cd /srv/the-forge/services/proxy
git pull
docker compose up -d
```

### 10.3 — Verificar

```bash
# Porta 81 não deve aparecer mais
sudo ss -tulnp | grep ':81'

# Proxy ainda funciona
curl -sk https://npm.maiahub.com.br -o /dev/null -w "%{http_code}\n"
# Deve retornar 200 ou 301
```

### 10.4 — Recuperação de emergência (se proxy host falhar)

Se `https://npm.maiahub.com.br` parar de funcionar após remover a porta:

```bash
# Opção 1: acessar de dentro da VM
ssh homelab
curl http://localhost:81

# Opção 2: adicionar porta temporariamente no compose
# Editar compose.yaml na VM, adicionar de volta "81:81", subir com docker compose up -d
# Diagnosticar, corrigir o proxy host, depois remover a porta novamente
```

---

## Etapa 11 — Remover regra UFW da Fase 2

Na Fase 2, a porta 3000 foi aberta diretamente para acesso ao AdGuard via Tailscale. Com o proxy host no ar, essa rota direta não é mais necessária.

```bash
# Ver as regras numeradas
sudo ufw status numbered

# Identificar a regra da porta 3000 (algo como "allow from 100.64.0.0/10 to any port 3000")
# Deletar pelo número
sudo ufw delete <número>

# Confirmar remoção
sudo ufw status | grep 3000
# Não deve aparecer nada

# Testar que AdGuard ainda funciona via proxy
curl -sk https://adguard.maiahub.com.br -o /dev/null -w "%{http_code}\n"
```

---

## Checklist final da Fase 3

### Container

- [ ] `docker ps` mostra `npm` com status `Up`
- [ ] `docker logs npm --tail 30` sem erros críticos
- [ ] `sudo ss -tulnp | grep ':81'` não retorna nada (porta removida)

### Certificados

- [ ] `npm.maiahub.com.br` listado em SSL Certificates com status válido
- [ ] `adguard.maiahub.com.br` listado em SSL Certificates com status válido
- [ ] Ambos com validade ~90 dias (renovação automática pelo NPM)

### Access List

- [ ] Access List `tailscale-only` criada com `allow 100.64.0.0/10` + `deny all`

### Proxy Hosts

- [ ] `https://npm.maiahub.com.br` abre com cadeado verde via Tailscale
- [ ] `https://npm.maiahub.com.br` retorna 403 de IP fora do Tailscale
- [ ] `https://adguard.maiahub.com.br` abre com cadeado verde via Tailscale
- [ ] `https://adguard.maiahub.com.br` retorna 403 de IP fora do Tailscale

### Limpeza

- [ ] Porta 81 removida do compose.yaml e não aparece em `ss -tulnp`
- [ ] Regra UFW porta 3000 removida (`ufw status` não mostra regra para 3000)
- [ ] Acesso ao AdGuard ainda funciona via `https://adguard.maiahub.com.br`

### Repositório

- [ ] `services/proxy/compose.yaml` commitado (sem porta 81)
- [ ] `services/proxy/.gitignore` commitado
- [ ] `services/proxy/data/` **não** commitado
- [ ] `services/proxy/letsencrypt/` **não** commitado

---

## Referência rápida — Operações do NPM

```bash
# Status
docker ps | grep npm
docker logs npm --tail 50

# Reiniciar NPM
docker restart npm

# Atualizar imagem
cd /srv/the-forge/services/proxy
docker compose pull && docker compose up -d

# Verificar certificados
docker exec npm ls /etc/letsencrypt/live/

# Testar proxy host
curl -sk https://npm.maiahub.com.br -o /dev/null -w "%{http_code}\n"
curl -sk https://adguard.maiahub.com.br -o /dev/null -w "%{http_code}\n"

# Ver regras UFW
sudo ufw status numbered

# Acesso de emergência ao painel (se proxy falhar)
# Adicionar temporariamente "81:81" no compose.yaml e docker compose up -d
```

---

## Próxima fase

### Fase 4 — Gerenciamento e Monitoramento (Portainer + Uptime Kuma + Netdata)

Cada serviço que subir a partir daqui segue o mesmo padrão estabelecido nesta fase:

1. Subir o container
2. Adicionar DNS Rewrite no AdGuard para o domínio do serviço
3. Emitir certificado individual via DNS Challenge no NPM
4. Criar proxy host com SSL + Access List tailscale-only
5. Commitar

Fase 4 entrega:
- **Portainer** — gerenciamento visual de containers (`portainer.maiahub.com.br`)
- **Uptime Kuma** — monitoramento de uptime e alertas (`monitoring.maiahub.com.br`)
- **Netdata** — métricas em tempo real do servidor (`netdata.maiahub.com.br`)

---

_Fase 3 de 9 — Projeto Homelab_
