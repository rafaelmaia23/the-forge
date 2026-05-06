# Fase 2 — DNS (AdGuard Home)

## Guia de Execução Completo

**Projeto:** Homelab
**Fase:** 2 de 9
**Objetivo:** Servidor DNS privado com bloqueio de trackers, upstream DoH triplo e resolução de subdomínios internos
**Tempo estimado:** 1–2 horas
**Pré-requisito:** Fase 1 concluída — VM no ar, Tailscale funcionando, `wg-mull-br` ativo

---

## O que esta fase entrega

Ao final desta fase:

- AdGuard Home rodando como container Docker na VM
- Todos os dispositivos na rede Tailscale usando o AdGuard como DNS
- Anúncios e trackers bloqueados antes de sair da rede
- Subdomínios `*.maiahub.com.br` resolvendo para a VM Oracle
- Exceções para serviços externos (blog e clone-tabnews na Vercel)
- Override DNS do Tailscale reativado e funcionando

---

## Decisões arquiteturais desta fase

| Decisão | Escolha | Motivo |
|---|---|---|
| Software DNS | AdGuard Home | Interface amigável, DoH nativo, sem container extra |
| Porta 53 | Desabilitar stub do systemd-resolved | Libera a porta para o AdGuard sem quebrar o sistema |
| Upstream DNS | Quad9 + Cloudflare + Mullvad DoH em paralelo | Velocidade, resiliência e privacidade |
| Blocklists | AdGuard DNS filter + OISD Full | Abrangentes com poucos falsos positivos |
| DNS Rewrite | Wildcard `*.maiahub.com.br` + exceções Vercel | Uma regra cobre todos os serviços futuros |
| Dados | `config/` versionado, `data/` no .gitignore | Configuração rastreável, logs fora do repo |
| Override Tailscale | Ativar só no final | Evita quebrar DNS dos dispositivos durante configuração |

---

## Etapa 1 — Preparar a estrutura na máquina local

> Faça esta etapa na sua **máquina local**.

### 1.1 — Criar a estrutura de diretórios do serviço

```bash
cd ~/projetos/the-forge
mkdir -p services/dns/config
```

### 1.2 — Criar o compose.yaml

```bash
cat > services/dns/compose.yaml << 'EOF'
services:
  adguard:
    image: adguard/adguardhome:latest
    container_name: adguard
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "3000:3000/tcp"
    volumes:
      - ./config:/opt/adguardhome/conf
      - ./data:/opt/adguardhome/work
    networks:
      - proxy

networks:
  proxy:
    external: true
EOF
```

**Por que dois volumes separados:**
- `./config` → onde o `AdGuardHome.yaml` fica — versionado
- `./data` → logs de queries, banco de estatísticas, cache — não versionado

**Por que a porta 3000 está exposta:**
Necessária para o setup inicial via navegador. Após configurar e o NPM estar no ar (Fase 3), o acesso ao painel será via subdomínio e essa porta pode ser removida do `ports:` — o NPM acessa o container pela rede `proxy` interna.

### 1.3 — Criar o .gitignore do serviço

```bash
cat > services/dns/.gitignore << 'EOF'
# Dados de runtime — logs, estatísticas, cache
data/

# O AdGuardHome.yaml real (com senha hash) é versionado intencionalmente.
# O hash bcrypt não expõe a senha — é seguro manter no repositório público.
EOF
```

### 1.4 — Criar o placeholder de configuração

O AdGuard vai gerar o `AdGuardHome.yaml` automaticamente no primeiro setup.
Após configurar, vamos commitar o arquivo real. Por ora, cria um README:

```bash
cat > services/dns/config/.gitkeep << 'EOF'
EOF
```

### 1.5 — Commitar a estrutura

```bash
git add services/dns/
git commit -m "feat(dns): add AdGuard Home service structure"
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

### 2.2 — Verificar se a porta 53 está em uso

```bash
sudo ss -tulnp | grep ':53'
```

Se aparecer `systemd-resolve` ou `127.0.0.53`, a porta está ocupada — siga o passo 2.3.
Se não aparecer nada, pule para a Etapa 3.

### 2.3 — Liberar a porta 53 (desabilitar stub do systemd-resolved)

O `systemd-resolved` tem um "stub listener" em `127.0.0.53:53` que ocupa a porta antes do AdGuard subir. Vamos desativá-lo — o systemd-resolved continua funcionando para o sistema, só para de fingir que é um servidor DNS.

```bash
# Desabilitar o stub listener
sudo mkdir -p /etc/systemd/resolved.conf.d/
sudo tee /etc/systemd/resolved.conf.d/no-stub.conf << 'EOF'
[Resolve]
DNSStubListener=no
EOF

# Aplicar
sudo systemctl restart systemd-resolved

# Verificar que a porta 53 foi liberada
sudo ss -tulnp | grep ':53'
# Não deve aparecer nada agora
```

### 2.4 — Garantir que o resolv.conf está correto

Após desabilitar o stub, o `/etc/resolv.conf` precisa apontar para o resolver real do systemd-resolved (não mais para o stub):

```bash
# Ver o que está configurado atualmente
cat /etc/resolv.conf

# Se apontar para 127.0.0.53, corrigir:
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# Verificar — deve mostrar os servidores DNS reais (não 127.0.0.53)
cat /etc/resolv.conf
```

---

## Etapa 3 — Subir o AdGuard

```bash
cd /srv/the-forge/services/dns
docker compose up -d

# Verificar que subiu
docker ps | grep adguard
docker logs adguard --tail 20
```

O container deve subir sem erros. Se aparecer erro de porta 53 ocupada, volte ao passo 2.3.

---

## Etapa 4 — Configuração inicial pelo painel

> Acesse o painel via **navegador na sua máquina local**.

O painel de setup está em: `http://{{OCI_TS_IP}}:3000`

> Use o IP Tailscale da VM — não o IP público Oracle.

### 4.1 — Assistente de setup

O AdGuard abre um assistente na primeira vez:

1. **Tela de boas-vindas** → Next
2. **Admin Web Interface** → porta `3000`, interface `0.0.0.0` → Next
3. **DNS server** → porta `53`, interface `0.0.0.0` → Next
4. **Credenciais** → criar usuário e senha fortes
5. **Concluir** → Open Dashboard

### 4.2 — Configurar upstream DNS

`Settings → DNS settings → Upstream DNS servers`

Remover os upstreams padrão e adicionar:

```
https://dns10.quad9.net/dns-query
https://1.1.1.1/dns-query
https://doh.mullvad.net/dns-query
```

**Upstream mode:** Parallel requests (todos recebem a query, usa a resposta mais rápida)

**Bootstrap DNS** (usado para resolver os próprios endereços DoH):
```
9.9.9.10
149.112.112.10
1.1.1.1
```

Clicar em **Test upstreams** — todos devem retornar OK.

Salvar.

### 4.3 — Configurar blocklists

`Filters → DNS blocklists → Add blocklist → Add a custom list`

Adicionar:

| Nome | URL |
|---|---|
| AdGuard DNS filter | `https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt` |
| OISD Full | `https://big.oisd.nl` |

Após adicionar, clicar em **Update filters**.

### 4.4 — Configurar DNS Rewrite

`Filters → DNS rewrites → Add DNS rewrite`

**Regra geral (todos os serviços da Oracle):**

| Domain | Answer |
|---|---|
| `*.maiahub.com.br` | `{{OCI_PUBLIC_IP}}` |

**Exceções (serviços na Vercel — não devem bater na Oracle):**

Para domínios na Vercel, não criamos um rewrite — em vez disso, deixamos o AdGuard consultar o upstream normalmente. Isso é feito via **custom filtering rules**:

`Filters → Custom filtering rules`

Adicionar:

```
@@||blog.maiahub.com.br^
@@||clone-tabnews.maiahub.com.br^
```

O prefixo `@@` significa "não bloqueie e não redirecione" — o AdGuard passa a query para o upstream normalmente, que vai resolver pelo Cloudflare público (onde os registros da Vercel estão).

### 4.5 — Configurações gerais recomendadas

`Settings → General settings`:

- **Query log:** habilitado (útil para diagnóstico)
- **Statistics:** habilitado, retenção 7 dias
- **Safe browsing:** a seu critério (bloqueia sites maliciosos conhecidos)
- **Safe search:** desabilitado (filtra resultados de busca — provavelmente indesejado)

`Settings → DNS settings → DNS cache`:

- **Cache size:** 4096 (padrão é suficiente)

---

## Etapa 5 — Testar resolução DNS

> Testes na VM primeiro, depois nos dispositivos.

### 5.1 — Testar da VM

```bash
# Instalar dig se não tiver
sudo apt install -y dnsutils

# Testar resolução de domínio externo
dig @127.0.0.1 google.com

# Testar DNS Rewrite — deve retornar o IP Oracle
dig @127.0.0.1 cloud.maiahub.com.br
# Deve retornar {{OCI_PUBLIC_IP}}

# Testar exceção Vercel — deve retornar IP da Vercel, não Oracle
dig @127.0.0.1 blog.maiahub.com.br
# Deve retornar IP diferente de {{OCI_PUBLIC_IP}}

# Testar que bloqueio funciona
dig @127.0.0.1 doubleclick.net
# Deve retornar 0.0.0.0 ou NXDOMAIN
```

### 5.2 — Testar de um dispositivo via Tailscale (sem ativar override ainda)

No terminal do seu PC ou celular, forçar uma query para o IP Tailscale da VM:

```bash
# No PC (Linux/Mac)
dig @{{OCI_TS_IP}} cloud.maiahub.com.br

# No PC (Windows)
nslookup cloud.maiahub.com.br {{OCI_TS_IP}}
```

Deve retornar `{{OCI_PUBLIC_IP}}`.

---

## Etapa 6 — Verificar porta 53 na Security List OCI

A porta 53 precisa estar **fechada** para o mundo externo. Verificar no painel OCI:

```
OCI Console → Networking → VCN-Homelab → Security Lists → Default Security List
```

Confirmar que **não existe** regra permitindo porta 53 TCP/UDP de `0.0.0.0/0`.

Se existir, remover imediatamente — um servidor DNS aberto para a internet pode ser usado em ataques de amplificação DNS.

> A porta 53 só precisa ser acessível via Tailscale (`100.64.0.0/10`), e esse tráfego já chega pela interface `tailscale0` sem precisar de regra na Security List.

---

## Etapa 7 — Ativar Override DNS no Tailscale

Somente após todos os testes passarem.

### 7.1 — Configurar no painel Tailscale

```
login.tailscale.com/admin/dns
→ Add nameserver → Custom
→ Nameserver: {{OCI_TS_IP}}
→ Use with exit node: marcar
→ Override DNS servers: habilitar
```

### 7.2 — Validar nos dispositivos

Em cada dispositivo com Tailscale conectado, verificar que o DNS mudou:

```bash
# Linux/Mac
cat /etc/resolv.conf
# Deve mostrar o IP Tailscale da VM

# Ou testar diretamente
dig cloud.maiahub.com.br
# Deve retornar {{OCI_PUBLIC_IP}} sem especificar @servidor
```

No Android com Tailscale conectado: abrir `blog.maiahub.com.br` e `cloud.maiahub.com.br` no browser — ambos devem funcionar corretamente.

---

## Etapa 8 — Versionar a configuração

Após tudo funcionando, o `AdGuardHome.yaml` foi gerado e preenchido pelo setup. Vamos versioná-lo:

```bash
# Na VM
cp /srv/the-forge/services/dns/config/AdGuardHome.yaml \
   /srv/the-forge/services/dns/config/AdGuardHome.yaml.bak

# Na máquina local — puxar o arquivo gerado
scp homelab:/srv/the-forge/services/dns/config/AdGuardHome.yaml \
    ~/projetos/the-forge/services/dns/config/AdGuardHome.yaml
```

Revisar o arquivo antes de commitar — remover qualquer valor sensível que não seja o hash da senha (o hash é seguro). Commitar:

```bash
git add services/dns/
git commit -m "feat(dns): add AdGuard Home config and bring up service

- Upstream: Quad9 + Cloudflare + Mullvad DoH (parallel)
- Blocklists: AdGuard DNS filter + OISD Full
- DNS Rewrite: *.maiahub.com.br → OCI
- Exceptions: blog.maiahub.com.br, clone-tabnews.maiahub.com.br (Vercel)"
git push
```

---

## Checklist final da Fase 2

### Container

- [ ] `docker ps` mostra `adguard` com status `Up`
- [ ] `docker logs adguard` sem erros críticos
- [ ] Porta 53 respondendo: `dig @127.0.0.1 google.com` retorna resposta

### Configuração

- [ ] Upstream DNS configurado (Quad9 + Cloudflare + Mullvad)
- [ ] Test upstreams passou (todos OK)
- [ ] Blocklists AdGuard DNS filter + OISD Full adicionadas e atualizadas
- [ ] DNS Rewrite `*.maiahub.com.br → {{OCI_PUBLIC_IP}}` criado
- [ ] Exceções Vercel criadas (`@@||blog...` e `@@||clone-tabnews...`)

### Testes

- [ ] `dig @127.0.0.1 cloud.maiahub.com.br` retorna `{{OCI_PUBLIC_IP}}`
- [ ] `dig @127.0.0.1 blog.maiahub.com.br` retorna IP da Vercel (não Oracle)
- [ ] `dig @127.0.0.1 doubleclick.net` retorna `0.0.0.0` (bloqueado)
- [ ] Porta 53 fechada na Security List OCI para `0.0.0.0/0`

### Tailscale

- [ ] Override DNS ativado no painel Tailscale
- [ ] Dispositivos pessoais resolvendo DNS via AdGuard
- [ ] `blog.maiahub.com.br` abre corretamente nos dispositivos
- [ ] `cloud.maiahub.com.br` resolve para IP Oracle nos dispositivos

### Repositório

- [ ] `services/dns/compose.yaml` commitado
- [ ] `services/dns/config/AdGuardHome.yaml` commitado
- [ ] `services/dns/data/` no `.gitignore` e não commitado
- [ ] Commit com mensagem descritiva

---

## Referência rápida — Operações do AdGuard

```bash
# Ver status
docker ps | grep adguard
docker logs adguard --tail 50

# Reiniciar
docker compose -f /srv/the-forge/services/dns/compose.yaml restart

# Atualizar imagem
cd /srv/the-forge/services/dns
docker compose pull && docker compose up -d

# Testar DNS manualmente
dig @127.0.0.1 <domínio>

# Ver queries em tempo real (no painel AdGuard)
# Dashboard → Query Log → Live

# Verificar porta 53
sudo ss -tulnp | grep ':53'

# Verificar regras de roteamento (para confirmar que DNS não passa pelo Mullvad)
ip rule | grep tailscale
```

---

## Próxima fase

### Fase 3 — Proxy Reverso (Nginx Proxy Manager)

Com o DNS no ar, o próximo passo é subir o NPM para:
- Ser o ponto de entrada único para todo tráfego HTTP/HTTPS
- Emitir certificado wildcard `*.maiahub.com.br` via DNS Challenge (Cloudflare)
- Criar proxy hosts para cada serviço com SSL automático
- Proteger painéis de controle com Access List `tailscale-only`

---

_Fase 2 de 9 — Projeto Homelab_
