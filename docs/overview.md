# Projeto Homelab — Documento de Contexto e Referência

**Versão:** 1.0  
**Data:** 2026-04-27  
**Autor:** Rafael (rmf)  
**Repositório:** `github.com/seuuser/homelab` _(atualizar após criar)_

---

## Índice

1. [Visão Geral](#1-visão-geral)
2. [Infraestrutura Oracle Cloud](#2-infraestrutura-oracle-cloud)
3. [Arquitetura de Rede](#3-arquitetura-de-rede)
4. [Estrutura do Repositório](#4-estrutura-do-repositório)
5. [Estrutura de Dados na VPS](#5-estrutura-de-dados-na-vps)
6. [Serviços](#6-serviços)
   - [6.1 DNS — AdGuard Home](#61-dns--adguard-home)
   - [6.2 Proxy Reverso — Nginx Proxy Manager](#62-proxy-reverso--nginx-proxy-manager)
   - [6.3 Cloud — Nextcloud Stack Completa](#63-cloud--nextcloud-stack-completa)
   - [6.4 Mídia — Jellyfin + Arr Stack](#64-mídia--jellyfin--arr-stack)
   - [6.5 Gerenciamento — Portainer](#65-gerenciamento--portainer)
   - [6.6 Monitoramento — Uptime Kuma + Netdata](#66-monitoramento--uptime-kuma--netdata)
   - [6.7 Localização — Dawarich](#67-localização--dawarich)
7. [VPN e Privacidade](#7-vpn-e-privacidade)
8. [Estratégia de Backup](#8-estratégia-de-backup)
9. [Convenções e Boas Práticas](#9-convenções-e-boas-práticas)
10. [Plano de Execução](#10-plano-de-execução)
11. [Pontos de Atenção e Riscos](#11-pontos-de-atenção-e-riscos)
12. [Architecture Decision Records (ADRs)](#12-architecture-decision-records-adrs)
13. [Referência de Comandos Úteis](#13-referência-de-comandos-úteis)

---

## 1. Visão Geral

O Projeto Homelab é uma infraestrutura de auto-hospedagem completa rodando na **Oracle Cloud Free Tier (ARM A1)**, construída do zero com foco em:

- **Privacidade** — DNS próprio com bloqueio de trackers, tráfego roteado por VPN
- **Controle** — Todos os serviços self-hosted, sem dependência de serviços de terceiros para dados pessoais
- **Confiabilidade** — Backup 3-2-1 implementado, monitoramento ativo, alertas de falha
- **Manutenibilidade** — Infraestrutura como código, versionada em Git, documentada para referência futura
- **Portfólio** — Projeto documentado para demonstrar habilidades de DevOps e administração de servidores

### Princípios de construção

1. Tudo roda como container Docker
2. Cada serviço/stack tem seu próprio `compose.yaml` isolado
3. O repositório Git é a fonte da verdade — nada existe fora dele
4. Segredos nunca são commitados — apenas arquivos `.env.example`
5. Cada decisão arquitetural relevante é documentada como ADR
6. O histórico de commits conta a história da construção

---

## 2. Infraestrutura Oracle Cloud

### Instância

| Parâmetro                     | Valor                             |
| ----------------------------- | --------------------------------- |
| Provider                      | Oracle Cloud Infrastructure (OCI) |
| Shape                         | `VM.Standard.A1.Flex`             |
| Arquitetura                   | ARM (AArch64)                     |
| OCPUs                         | 4                                 |
| RAM                           | 24 GB                             |
| OS                            | Ubuntu 22.04 LTS                  |
| Boot Volume                   | 50 GB (SO + containers)           |
| Block Volume                  | 150 GB montado em `/mnt/data`     |
| Total Free Tier Block Storage | 200 GB                            |

> **Nota:** O free tier OCI inclui 200 GB de block storage total. 50 GB são usados no boot volume, restando 150 GB para o volume de dados. Monitorar crescimento — especialmente mídia (Jellyfin) e dados do Nextcloud.

### Rede OCI (Security List)

| Porta | Protocolo | Origem         | Serviço                        |
| ----- | --------- | -------------- | ------------------------------ |
| 80    | TCP       | 0.0.0.0/0      | NPM (HTTP → redirect HTTPS)    |
| 443   | TCP       | 0.0.0.0/0      | NPM (HTTPS)                    |
| 22    | TCP       | IPs confiáveis | SSH                            |
| 41641 | UDP       | 0.0.0.0/0      | Tailscale                      |
| 53    | TCP/UDP   | 100.64.0.0/10  | AdGuard DNS (apenas Tailscale) |

> **Atenção:** A porta 53 deve estar fechada para o mundo externo. O AdGuard é acessível apenas dentro da rede Tailscale.

---

## 3. Arquitetura de Rede

### Fluxo de tráfego — Acesso privado (dispositivos pessoais)

```text
Dispositivo (celular/PC/notebook)
    │
    ▼
Tailscale (WireGuard)
    │  DNS configurado = IP Tailscale da VPS (AdGuard)
    │  Exit node habilitado = todo tráfego passa pela VPS
    ▼
VPS Oracle — Interface tailscale0
    │
    ├─► AdGuard Home [:53]
    │       ├── Resolve *.srv.maiahub.com.br → IP público Oracle
    │       ├── Filtra trackers e malware (OISD + AdGuard DNS filter)
    │       └── Upstream: Quad9 DoH (https://dns10.quad9.net/dns-query)
    │
    └─► Proton VPN (kill switch ON, split tunnel: tailscale0 excluído)
            │
            ▼
        Internet (IP público = servidor Proton VPN)
```

> **Detalhe crítico:** O split tunnel da Proton VPN deve excluir a interface `tailscale0` e o range `100.64.0.0/10`. Sem isso, o kill switch da Proton bloqueia o tráfego interno do Tailscale, quebrando o acesso SSH e aos serviços privados.

### Fluxo de tráfego — Acesso público (namorada, família)

```text
Browser externo
    │
    ▼
IP Público Oracle [:443]
    │
    ▼
Nginx Proxy Manager (NPM)
    ├── cloud.srv.maiahub.com.br  → nextcloud:80
    └── jellyfin.srv.maiahub.com.br → jellyfin:8096
```

### Fluxo de tráfego — Painéis de controle (apenas Tailscale)

```text
Dispositivo na rede Tailscale
    │
    ▼
NPM — Access List "tailscale-only" (100.64.0.0/10)
    ├── npm.srv.maiahub.com.br         → npm:81
    ├── portainer.srv.maiahub.com.br   → portainer:9000
    ├── adguard.srv.maiahub.com.br     → adguardhome:3000
    ├── monitoring.srv.maiahub.com.br  → uptime-kuma:3001
    └── netdata.srv.maiahub.com.br     → netdata:19999
```

### Redes Docker

```text
proxy (externa, bridge)
    └── Compartilhada por todos os serviços que precisam ser acessados pelo NPM
        NPM, Nextcloud, Jellyfin, AdGuard, Portainer, Uptime Kuma, Netdata, Dawarich

nextcloud_internal (interna, bridge)
    └── Nextcloud ↔ PostgreSQL ↔ Redis ↔ Elasticsearch ↔ ClamAV ↔ Collabora
        Não exposta externamente — apenas o container nextcloud entra na rede proxy

media_internal (interna, bridge)
    └── Sonarr ↔ Radarr ↔ Prowlarr ↔ qBittorrent
        Apenas Jellyfin entra na rede proxy

location_internal (interna, bridge)
    └── Dawarich ↔ dawarich-db ↔ dawarich-redis
```

---

## 4. Estrutura do Repositório

```text
homelab/
│
├── README.md                          ← Visão geral, tabela de serviços, como replicar
├── ARCHITECTURE.md                    ← Diagrama de rede detalhado, decisões de topologia
├── RUNBOOK.md                         ← Procedimentos operacionais (restart, update, etc.)
├── CHANGELOG.md                       ← Histórico de mudanças relevantes na infra
├── .gitignore                         ← ignora: .env, data/, letsencrypt/, secrets/, *.sql
│
├── infrastructure/
│   ├── provision.sh                   ← Instalação completa do zero (Docker, Tailscale, dirs)
│   ├── firewall.sh                    ← Regras ufw + referência para OCI Security List
│   ├── mounts.sh                      ← Monta block volume, configura /etc/fstab
│   └── README.md                      ← Como usar os scripts de provisioning
│
├── services/
│   ├── dns/                           ← AdGuard Home
│   │   ├── compose.yaml
│   │   ├── config/
│   │   │   └── AdGuardHome.yaml.example
│   │   └── README.md
│   │
│   ├── proxy/                         ← Nginx Proxy Manager
│   │   ├── compose.yaml
│   │   ├── .env.example
│   │   └── README.md
│   │
│   ├── cloud/                         ← Nextcloud stack completa
│   │   ├── compose.yaml               ← nextcloud, postgres, redis, collabora,
│   │   │                                 elasticsearch, clamav, notify_push, imaginary
│   │   ├── .env.example
│   │   ├── config/
│   │   │   └── nextcloud.config.php.example
│   │   └── README.md
│   │
│   ├── media/                         ← Jellyfin + Arr Stack
│   │   ├── compose.yaml               ← jellyfin, sonarr, radarr, prowlarr, qbittorrent
│   │   ├── .env.example
│   │   └── README.md
│   │
│   ├── management/                    ← Portainer
│   │   ├── compose.yaml
│   │   └── README.md
│   │
│   ├── monitoring/                    ← Uptime Kuma + Netdata
│   │   ├── compose.yaml
│   │   └── README.md
│   │
│   └── location/                      ← Dawarich
│       ├── compose.yaml
│       ├── .env.example
│       └── README.md
│
├── backup/
│   ├── backup.sh                      ← Script principal de backup
│   ├── restore.sh                     ← Procedimento documentado de restore
│   ├── .env.example                   ← Credenciais B2, senhas de banco
│   └── README.md                      ← Estratégia 3-2-1, frequências, validação
│
└── docs/
    ├── network-diagram.md             ← Diagrama ASCII/Mermaid da rede completa
    ├── services-overview.md           ← O que cada serviço faz e por quê foi escolhido
    ├── migration-log.md               ← Diário da migração (Hostinger → Oracle)
    ├── disaster-recovery.md           ← Procedimento completo de restore do zero
    └── decisions/                     ← Architecture Decision Records
        ├── ADR-001-docker-por-servico.md
        ├── ADR-002-tailscale-vpn.md
        ├── ADR-003-nextcloud-vs-aio.md
        ├── ADR-004-postgres-vs-mariadb.md
        └── ADR-005-estrategia-backup.md
```

### .gitignore principal

```gitignore
# Segredos
.env
*.secret
secrets/

# Dados dos containers (gerados em runtime)
**/data/
**/letsencrypt/
**/*.log

# Dumps de banco
*.sql
*.sql.gz

# Backups locais
backup/local/

# OS
.DS_Store
Thumbs.db
```

---

## 5. Estrutura de Dados na VPS

```text
/mnt/data/                             ← Block volume Oracle (150 GB)
├── nextcloud/
│   └── userdata/                      ← Arquivos dos usuários (montado no container)
│
├── media/
│   ├── movies/                        ← Jellyfin filmes
│   ├── tv/                            ← Jellyfin séries
│   ├── music/                         ← Jellyfin música (futuro)
│   └── downloads/
│       ├── complete/                  ← qBittorrent — downloads finalizados
│       └── incomplete/                ← qBittorrent — em andamento
│
├── backups/
│   └── local/                         ← Dumps temporários antes de enviar ao B2
│
└── location/
    └── imports/                       ← Importações históricas para o Dawarich

/srv/                                  ← Repositório Git clonado aqui
    └── (estrutura do repositório acima)

/srv/services/dns/adguard_conf/        ← Configuração persistente AdGuard (fora do data/)
/srv/services/dns/adguard_data/        ← Dados persistentes AdGuard
```

> **Convenção:** Dados de aplicação pesada (arquivos de usuário, mídia) ficam em `/mnt/data`. Configurações dos serviços ficam dentro de `/srv/services/*/` e são versionadas ou possuem exemplos versionados.

---

## 6. Serviços

### 6.1 DNS — AdGuard Home

**Diretório:** `services/dns/`  
**Acesso:** `adguard.srv.maiahub.com.br` (privado — apenas Tailscale)  
**Porta interna:** `3000`

**Função:** Servidor DNS privado para todos os dispositivos da rede Tailscale. Filtra anúncios, trackers e malware antes que a requisição saia da rede.

**Configuração relevante:**

| Parâmetro     | Valor                                     |
| ------------- | ----------------------------------------- |
| Bind DNS      | `0.0.0.0:53`                              |
| Upstream DNS  | `https://dns10.quad9.net/dns-query` (DoH) |
| Bootstrap DNS | `9.9.9.10`, `149.112.112.10`              |
| Upstream mode | Load balance                              |
| DNSSEC        | Desabilitado (Quad9 já valida)            |
| Cache         | Habilitado                                |

**DNS Rewrite (crítico):**

```text
*.srv.maiahub.com.br → <IP_PÚBLICO_ORACLE>
```

Este rewrite faz todos os subdomínios do homelab resolverem para a VPS. **Deve ser o primeiro a ser atualizado ao trocar de IP.**

**Blocklists recomendadas:**

- AdGuard DNS filter (padrão)
- OISD Full (`https://big.oisd.nl`) — mais abrangente que AdAway

**No painel Tailscale Admin:** Definir o IP Tailscale da VPS como nameserver global para todos os dispositivos.

---

### 6.2 Proxy Reverso — Nginx Proxy Manager

**Diretório:** `services/proxy/`  
**Acesso ao painel:** `npm.srv.maiahub.com.br` (privado — apenas Tailscale)  
**Portas expostas:** `80`, `443` (públicas) e `81` (painel, interno)

**Função:** Único ponto de entrada para todo tráfego HTTP/HTTPS. Gerencia certificados SSL via Let's Encrypt (DNS Challenge com Cloudflare API) e controla quais serviços são públicos vs. privados via Access Lists.

**Proxy Hosts planejados:**

| Domínio                         | Backend             | Acesso         | Notas     |
| ------------------------------- | ------------------- | -------------- | --------- |
| `cloud.srv.maiahub.com.br`      | `nextcloud:80`      | Público        | Force SSL |
| `jellyfin.srv.maiahub.com.br`   | `jellyfin:8096`     | Público        | Force SSL |
| `npm.srv.maiahub.com.br`        | `npm:81`            | Tailscale only |           |
| `portainer.srv.maiahub.com.br`  | `portainer:9000`    | Tailscale only |           |
| `adguard.srv.maiahub.com.br`    | `adguardhome:3000`  | Tailscale only |           |
| `monitoring.srv.maiahub.com.br` | `uptime-kuma:3001`  | Tailscale only |           |
| `netdata.srv.maiahub.com.br`    | `netdata:19999`     | Tailscale only |           |
| `dawarich.srv.maiahub.com.br`   | `dawarich-app:3000` | Tailscale only |           |

**Access List "tailscale-only":**

- Allow: `100.64.0.0/10` (range completo da rede Tailscale)
- Deny: todos os outros

**Certificados:**

- Wildcard `*.srv.maiahub.com.br` via DNS Challenge (Cloudflare API)
- Não copiar certificados da Hostinger — emitir novos na Oracle
- Renovação automática gerenciada pelo próprio NPM

---

### 6.3 Cloud — Nextcloud Stack Completa

**Diretório:** `services/cloud/`  
**Acesso:** `cloud.srv.maiahub.com.br` (público)  
**Versão:** `nextcloud:30-apache` (verificar compatibilidade com plugins ao subir)

**Decisão arquitetural:** Stack manual em containers separados, sem usar Nextcloud AIO. Isso garante controle total de cada componente, facilita debugging e versionamento. Ver ADR-003.

#### Containers da stack

| Container                 | Imagem                  | Obrigatório | Função                                                       |
| ------------------------- | ----------------------- | ----------- | ------------------------------------------------------------ |
| `nextcloud`               | `nextcloud:30-apache`   | Sim         | Aplicação principal (Apache + PHP)                           |
| `nextcloud-db`            | `postgres:16`           | Sim         | Banco de dados                                               |
| `nextcloud-redis`         | `redis:alpine`          | Sim         | Cache de sessão e file locking                               |
| `nextcloud-collabora`     | `collabora/code:latest` | Sim         | Nextcloud Office (edição de documentos)                      |
| `nextcloud-elasticsearch` | `elasticsearch:8.x`     | Sim         | Full text search                                             |
| `nextcloud-clamav`        | `clamav/clamav:latest`  | Sim         | Antivírus para arquivos                                      |
| `nextcloud-notify-push`   | `nextcloud:30-apache`   | Sim         | Client push (notificações real-time)                         |
| `nextcloud-imaginary`     | `h2non/imaginary`       | Recomendado | Previews de imagem em alta performance                       |
| `nextcloud-coturn`        | `coturn/coturn`         | Condicional | STUN/TURN para Talk (vídeo) — subir só se usar videochamadas |

> **Nota sobre o banco:** O AIO usa PostgreSQL por padrão. Usar `postgres:16` facilita uma eventual migração de dados do Nextcloud atual se necessário, e é a escolha mais performática para Nextcloud em geral.
>
> **Nota sobre elasticsearch:** Verificar a versão exata compatível com o plugin Full Text Search instalado antes de definir a tag da imagem. A versão 8.x requer configurações específicas de segurança (xpack).

#### Apps a instalar no painel após subir

**Comunicação e colaboração:**

- Talk, Calendar, Contacts, Deck, Tasks, Notes, Whiteboard

**Arquivos e produtividade:**

- Nextcloud Office (requer Collabora ativo), Photos, PDF Viewer, Text, File Reminders, Files Download Limit

**Busca:**

- Full Text Search, Full Text Search - Elasticsearch Platform, Full Text Search - Files

**Segurança:**

- Two-Factor TOTP Provider, Antivirus for Files (requer ClamAV), Password Policy, Auditing/Logging, Privacy

**Notificações e integrações:**

- Client Push (notify_push), DAV Push, UnifiedPush Provider, Nextcloud Webhook Support, Contacts Interaction, Related Resources, Recommendations, User Status, Weather Status

**Admin:**

- Monitoring, Log Reader, Support

**RSS:**

- News

**Já inclusos por padrão** (não precisam ser instalados): Activity, Notifications, Dashboard, Brute-force Settings, Collaborative Tags, Comments, Versions, Deleted Files, Update Notification, First Run Wizard, Federation, Share by Mail, Teams

#### Volumes

```yaml
volumes:
  nextcloud_config: # Config PHP do Nextcloud (/var/www/html/config)
  nextcloud_apps: # Apps instalados (/var/www/html/apps)
  nextcloud_db: # Dados PostgreSQL
  nextcloud_redis: # Persistência Redis (opcional mas recomendado)
  # Arquivos dos usuários → /mnt/data/nextcloud/userdata (bind mount, não volume nomeado)
```

#### Variáveis de ambiente críticas

```env
POSTGRES_DB=nextcloud
POSTGRES_USER=nextcloud
POSTGRES_PASSWORD=<senha_forte>
POSTGRES_HOST=nextcloud-db

REDIS_HOST=nextcloud-redis
REDIS_HOST_PASSWORD=<senha_redis>

NEXTCLOUD_ADMIN_USER=rmf
NEXTCLOUD_ADMIN_PASSWORD=<senha_admin>
NEXTCLOUD_TRUSTED_DOMAINS=cloud.srv.maiahub.com.br
OVERWRITEPROTOCOL=https
OVERWRITECLIURL=https://cloud.srv.maiahub.com.br
NC_default_phone_region=BR

# Collabora
COLLABORA_DOMAIN=cloud.srv.maiahub.com.br

# ClamAV
CLAMAV_NO_FRESHCLAMD=false
```

---

### 6.4 Mídia — Jellyfin + Arr Stack

**Diretório:** `services/media/`  
**Acesso Jellyfin:** `jellyfin.srv.maiahub.com.br` (público)  
**Demais:** acessíveis apenas via Tailscale (sem domínio próprio, ou via subdomínios privados)

| Container     | Imagem                           | Porta interna | Função                                     |
| ------------- | -------------------------------- | ------------- | ------------------------------------------ |
| `jellyfin`    | `jellyfin/jellyfin:latest`       | 8096          | Servidor de streaming de mídia             |
| `sonarr`      | `linuxserver/sonarr:latest`      | 8989          | Automação de séries                        |
| `radarr`      | `linuxserver/radarr:latest`      | 7878          | Automação de filmes                        |
| `prowlarr`    | `linuxserver/prowlarr:latest`    | 9696          | Indexador centralizado (substitui Jackett) |
| `qbittorrent` | `linuxserver/qbittorrent:latest` | 8080          | Cliente torrent                            |

**Volumes de mídia** (todos bind mounts para `/mnt/data/media/`):

```yaml
volumes:
  - /mnt/data/media/movies:/movies
  - /mnt/data/media/tv:/tv
  - /mnt/data/media/downloads/complete:/downloads
  - /mnt/data/media/downloads/incomplete:/downloads/incomplete
```

> **Importante:** Sonarr, Radarr e qBittorrent precisam compartilhar o mesmo path de downloads para o hardlinking funcionar corretamente e evitar duplicação de arquivos.

---

### 6.5 Gerenciamento — Portainer

**Diretório:** `services/management/`  
**Acesso:** `portainer.srv.maiahub.com.br` (privado — apenas Tailscale)  
**Porta interna:** `9000`

Gerenciamento visual de containers Docker. Útil para inspecionar logs, reiniciar containers e monitorar uso de recursos sem precisar de SSH para operações simples.

> Portainer CE não persiste estado crítico de negócio — pode ser reinstalado do zero sem perda de dados relevantes. Não é necessário fazer backup do volume `./data`.

---

### 6.6 Monitoramento — Uptime Kuma + Netdata

**Diretório:** `services/monitoring/`

#### Uptime Kuma

**Acesso:** `monitoring.srv.maiahub.com.br` (privado — apenas Tailscale)  
**Porta interna:** `3001`  
**Função:** Monitoramento de uptime e disponibilidade dos serviços com alertas (Telegram, email, etc.).

**Monitores a configurar:**

- Cada proxy host do NPM (HTTP/HTTPS check)
- Porta 53 do AdGuard (DNS check)
- Endpoint de health do Nextcloud (`/status.php`)
- Endpoint de health do Jellyfin

#### Netdata

**Acesso:** `netdata.srv.maiahub.com.br` (privado — apenas Tailscale)  
**Porta interna:** `19999`  
**Função:** Métricas em tempo real do servidor (CPU, RAM, disco, rede, containers Docker).

---

### 6.7 Localização — Dawarich

**Diretório:** `services/location/`  
**Acesso:** `dawarich.srv.maiahub.com.br` (privado — apenas Tailscale)

Substituto self-hosted para o Life360. Histórico de localização com mapa, importação do histórico do Google Maps (formato Takeout), API compatível com Overland (app iOS/Android para envio de localização).

| Container        | Imagem                    | Função              |
| ---------------- | ------------------------- | ------------------- |
| `dawarich-app`   | `freikin/dawarich:latest` | Aplicação principal |
| `dawarich-db`    | `postgres:15`             | Banco de dados      |
| `dawarich-redis` | `redis:alpine`            | Cache/filas         |

---

## 7. VPN e Privacidade

### Tailscale

- **Função na VPS:** Exit node + nameserver DNS (AdGuard)
- **Função nos dispositivos:** Acesso seguro aos serviços privados + rotear tráfego pelo exit node
- **Nota Android:** No Android só é possível ter uma VPN ativa por vez. Usar Tailscale como VPN principal (com exit node habilitado) garante tanto o acesso privado quanto o mascaramento de IP via exit node.

**Configuração na VPS:**

```bash
# IP forwarding (obrigatório para exit node)
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# Subir como exit node
tailscale up --advertise-exit-node
```

**No painel Tailscale Admin:**

- Aprovar o exit node da VPS
- Definir IP Tailscale da VPS como nameserver global

### Proton VPN

- **Função:** Mascarar o IP da VPS na internet (ISP vê tráfego para Proton, sites veem IP do servidor Proton)
- **Kill switch:** ON — se a VPN cair, o tráfego para a internet é bloqueado
- **Split tunnel obrigatório:** Excluir interface `tailscale0` e range `100.64.0.0/10` do túnel Proton para não quebrar o acesso SSH e aos serviços internos

**Fluxo completo de tráfego:**

```text
Dispositivo → [Tailscale WireGuard] → VPS → [Proton VPN] → Internet
                     ↑                   ↑
               DNS: AdGuard          Kill switch ON
               Exit node habilitado  Split tunnel: tailscale0 excluído
```

---

## 8. Estratégia de Backup

### Stack de backup escolhida

A estratégia usa ferramentas diferentes para cada tipo de dado, cada uma escolhida pelo que faz melhor:

| Camada                      | Ferramenta        | O que cobre                                   | Por quê                                                                                                                      |
| --------------------------- | ----------------- | --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Infraestrutura como código  | **Git**           | Compose files, scripts, docs                  | Já é parte do fluxo de desenvolvimento                                                                                       |
| Dados do Nextcloud e bancos | **Restic + B2**   | Arquivos de usuário, dumps PostgreSQL/MariaDB | Backup incremental com versionamento real — permite restaurar o estado de qualquer ponto no tempo                            |
| Arquivos de mídia           | **Rclone + B2**   | `/mnt/data/media/`                            | Mídia não precisa de versionamento — se perder, a Arr Stack re-baixa. Rclone é mais simples e eficiente para grandes volumes |
| Estado da VM                | **Snapshots OCI** | Disco inteiro da instância                    | Disaster recovery rápido — restaura a VM exatamente como estava, sem reconfigurar nada                                       |

> **Por que Restic e não só Rclone para o Nextcloud?** Rclone é um espelho — se você deletar um arquivo por acidente, na próxima sync ele some do B2 também. Restic cria snapshots de pontos no tempo com deduplicação e criptografia. Você pode restaurar como os arquivos estavam ontem, semana passada ou mês passado. Para dados pessoais (fotos, documentos, contatos), isso é essencial.

---

### Regra 3-2-1

| #   | Cópia       | Onde                    | Frequência | Tipo                            |
| --- | ----------- | ----------------------- | ---------- | ------------------------------- |
| 1   | Dado vivo   | VPS Oracle `/mnt/data`  | Contínuo   | Operacional                     |
| 2   | Cópia local | PC pessoal / HD externo | Semanal    | Rclone pull manual do B2        |
| 3   | Offsite     | Backblaze B2            | Diário     | Restic (dados) + Rclone (mídia) |

> **Object Lock no B2 (crítico):** Habilitar Object Lock no bucket com retenção de 30 dias. Mesmo que a VPS seja comprometida e alguém execute um comando de deleção, os arquivos ficam imutáveis pelo período definido. É a proteção contra ransomware.

---

### O que fazer backup e como

| Dado                                                | Ferramenta  | Destino | Frequência     | Versionamento            |
| --------------------------------------------------- | ----------- | ------- | -------------- | ------------------------ |
| Arquivos Nextcloud (`/mnt/data/nextcloud/userdata`) | Restic      | B2      | Diário         | Sim — snapshots por data |
| Banco Nextcloud (PostgreSQL dump)                   | Restic      | B2      | Diário         | Sim                      |
| Banco NPM (MariaDB dump)                            | Restic      | B2      | Diário         | Sim                      |
| Certificados Let's Encrypt                          | Restic      | B2      | Semanal        | Sim                      |
| Configuração AdGuard (`adguard_conf/`)              | Restic      | B2      | Semanal        | Sim                      |
| Configurações dos serviços (`/srv/`)                | Git         | GitHub  | A cada mudança | Sim (histórico Git)      |
| Arquivos de mídia (`/mnt/data/media/`)              | Rclone sync | B2      | Semanal        | Não necessário           |

### O que NÃO precisa de backup

- Dados do Portainer — estado reconstruível do zero em minutos
- Logs dos containers — histórico descartável
- Cache do Redis — regenerado automaticamente
- `downloads/incomplete/` — downloads em andamento, descartáveis
- Imagens Docker — são re-baixadas com `docker compose pull`

---

### Snapshots OCI

Snapshots são feitos manualmente no painel da Oracle (ou via OCI CLI) antes de operações de risco. Não substituem o backup automatizado — são uma rede de segurança para mudanças na própria infra.

**Quando tirar um snapshot:**

- Antes de atualizar o SO (`apt upgrade`)
- Antes de mudar a arquitetura de rede ou Docker
- Antes de atualizar uma stack inteira de serviços
- Após o servidor estar completamente estável pela primeira vez

**Política de retenção:** manter os 2-3 snapshots mais recentes. Snapshots OCI ocupam espaço no free tier, então não acumular indefinidamente.

**Como tirar via OCI CLI:**

```bash
# Listar instâncias para pegar o OCID
oci compute instance list --compartment-id <compartment-ocid>

# Criar snapshot do boot volume
oci compute boot-volume-backup create \
  --boot-volume-id <boot-volume-ocid> \
  --display-name "homelab-pre-update-$(date +%Y%m%d)" \
  --type INCREMENTAL
```

---

### Scripts de backup

#### `backup/backup.sh` — backup diário automatizado

```bash
#!/bin/bash
set -euo pipefail

BACKUP_DIR="/mnt/data/backups/local"
LOG_FILE="/var/log/homelab-backup.log"
RESTIC_REPOSITORY="b2:homelab-backup-restic"
# RESTIC_PASSWORD e B2_ACCOUNT_ID/KEY carregados via /etc/homelab-backup.env

source /etc/homelab-backup.env

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

log "=== Iniciando backup $(date +%Y%m%d_%H%M%S) ==="

# 1. Dump PostgreSQL — Nextcloud
log "Dump PostgreSQL (Nextcloud)..."
docker exec nextcloud-db pg_dump -U nextcloud nextcloud \
  > "$BACKUP_DIR/nextcloud_db.sql"

# 2. Dump MariaDB — NPM
log "Dump MariaDB (NPM)..."
docker exec npm-db mysqldump -u root -p"$NPM_DB_ROOT_PASSWORD" npm \
  > "$BACKUP_DIR/npm_db.sql"

# 3. Backup Restic — arquivos Nextcloud + dumps de banco
log "Restic backup → Backblaze B2..."
restic -r "$RESTIC_REPOSITORY" backup \
  /mnt/data/nextcloud/userdata \
  "$BACKUP_DIR/nextcloud_db.sql" \
  "$BACKUP_DIR/npm_db.sql" \
  /srv/services/dns/adguard_conf/ \
  /srv/services/proxy/letsencrypt/ \
  --exclude "*.part" \
  --exclude "*.log" \
  --tag "daily" \
  --verbose

# 4. Política de retenção — manter últimos 7 diários, 4 semanais, 3 mensais
log "Aplicando política de retenção Restic..."
restic -r "$RESTIC_REPOSITORY" forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3 \
  --prune

log "=== Backup concluído ==="
```

#### `backup/backup-media.sh` — sync de mídia (semanal)

```bash
#!/bin/bash
# Mídia não precisa de versionamento — rclone sync é suficiente
set -euo pipefail
LOG_FILE="/var/log/homelab-backup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

log "=== Sync de mídia → B2 ==="
rclone sync /mnt/data/media/ \
  backblaze:homelab-backup-media \
  --exclude "downloads/incomplete/**" \
  --log-file="$LOG_FILE" \
  --log-level INFO
log "=== Sync de mídia concluído ==="
```

**Crontab:**

```cron
# Backup diário às 3h
0 3 * * * /srv/backup/backup.sh

# Sync de mídia todo domingo às 4h
0 4 * * 0 /srv/backup/backup-media.sh

# Verificação de integridade mensal (check do repositório Restic)
0 10 1 * * restic -r b2:homelab-backup-restic check --log-file=/var/log/homelab-backup.log
```

---

### Configuração inicial do Restic

```bash
# Instalar Restic
apt install restic -y

# Criar arquivo de credenciais (fora do Git, nunca commitar)
cat > /etc/homelab-backup.env << 'EOF'
export RESTIC_PASSWORD="<senha-forte-gerada-com-openssl>"
export B2_ACCOUNT_ID="<backblaze-account-id>"
export B2_ACCOUNT_KEY="<backblaze-application-key>"
export NPM_DB_ROOT_PASSWORD="<senha-mariadb>"
EOF
chmod 600 /etc/homelab-backup.env

# Inicializar repositório Restic no B2
source /etc/homelab-backup.env
restic -r b2:homelab-backup-restic init

# Testar primeiro backup manualmente
/srv/backup/backup.sh
```

---

### Procedimento de validação mensal

Backup não testado é backup inválido. Mensalmente:

1. **Listar snapshots disponíveis:**

   ```bash
   source /etc/homelab-backup.env
   restic -r b2:homelab-backup-restic snapshots
   ```

2. **Verificar integridade do repositório:**

   ```bash
   restic -r b2:homelab-backup-restic check
   ```

3. **Testar restore do banco PostgreSQL em container temporário:**

   ```bash
   # Extrair dump de um snapshot específico
   restic -r b2:homelab-backup-restic restore latest \
     --include "/mnt/data/backups/local/nextcloud_db.sql" \
     --target /tmp/restore-test/

   # Subir postgres temporário e testar
   docker run --rm -e POSTGRES_PASSWORD=test \
     -v /tmp/restore-test:/restore \
     postgres:16 \
     psql -U postgres -f /restore/mnt/data/backups/local/nextcloud_db.sql
   ```

4. **Confirmar Object Lock ativo no bucket B2** — verificar no painel Backblaze.

5. **Registrar resultado** em `docs/migration-log.md` com a data.

---

## 9. Convenções e Boas Práticas

### Git

- **Commits atômicos:** cada serviço funcionando = 1 commit
- **Mensagens descritivas:** `feat(cloud): add nextcloud stack with postgres and redis`
- **Nunca commitar:** arquivos `.env`, dados de containers, certificados, dumps de banco
- **Tags para marcos:** `v1.0-foundation`, `v1.1-nextcloud`, `v1.2-media`, etc.

### Compose files

- Sempre definir `restart: unless-stopped` para serviços de produção
- Sempre definir redes explicitamente (nunca depender da rede default do Compose)
- Usar nomes de container explícitos (`container_name:`) para referência cross-stack
- Colocar `healthcheck:` nos containers que servem de dependência

### Variáveis de ambiente

- Todo serviço com credenciais tem um `.env.example` no repositório
- O `.env` real vive apenas na VPS, nunca no Git
- Senhas geradas com: `openssl rand -base64 32`

### Documentação

- Cada `services/*/README.md` deve conter: propósito, portas, variáveis obrigatórias, como reiniciar, onde ver logs
- `RUNBOOK.md` na raiz deve ser o documento de referência rápida para operações do dia a dia
- `docs/migration-log.md` deve ser atualizado durante a execução com o que funcionou, o que deu errado e como foi resolvido

---

## 10. Plano de Execução

### Pré-migração — Exportar dados do Nextcloud atual (Hostinger)

- [x] **P.1** Exportar contatos: Nextcloud Web → Contatos → Exportar todos como `.vcf`
- [x] **P.2** Exportar calendários: Nextcloud Web → Calendário → Exportar como `.ics` (um por calendário)
- [x] **P.3** Exportar tarefas: Nextcloud Web → Tasks → exportar (formato `.ics`)
- [x] **P.4** Exportar feeds RSS: Nextcloud Web → News → Settings → Export OPML → salvar `.opml`
- [x] **P.5** Baixar os 7GB de arquivos para o PC local
- [x] **P.6** Backup de referência da Hostinger: `tar -czf ~/backup_hostinger_$(date +%Y%m%d).tar.gz /srv/adguard/adguard_conf/ /srv/nginx-proxy-manager/data/`
- [x] **P.7** Anotar/salvar credenciais do `.env` do NPM atual

---

### Fase 1 — Fundação Oracle Cloud

- [ ] **1.1** Ativar Pay As You Go na OCI (necessário para o free tier completo)
- [ ] **1.2** Criar VCN-Homelab com Internet Gateway via VCN Wizard
- [ ] **1.3** Configurar Security List conforme tabela da seção 2
- [ ] **1.4** Provisionar VM A1 (4 OCPU / 24GB RAM / Ubuntu 22.04)
- [ ] **1.5** Configurar block volume de 150GB e montar em `/mnt/data`
- [ ] **1.6** Criar repositório Git `homelab` e clonar em `/srv`
- [ ] **1.7** Executar `infrastructure/provision.sh` (Docker, dirs, rede proxy)
- [ ] **1.8** Instalar e configurar Tailscale como exit node
- [ ] **1.9** Instalar Proton VPN CLI com split tunnel e kill switch
- [ ] **1.10** Anotar IP Tailscale da nova instância Oracle

---

### Fase 2 — DNS (AdGuard Home)

- [ ] **2.1** Subir AdGuard: `cd /srv/services/dns && docker compose up -d`
- [ ] **2.2** Configurar upstream DNS (Quad9 DoH), blocklists (AdGuard + OISD)
- [ ] **2.3** Configurar DNS Rewrite: `*.srv.maiahub.com.br → <IP_PÚBLICO_ORACLE>`
- [ ] **2.4** Testar resolução: `dig @<IP_TAILSCALE_ORACLE> cloud.srv.maiahub.com.br`
- [ ] **2.5** No painel Tailscale Admin: definir VPS Oracle como nameserver global
- [ ] **2.6** Validar que dispositivos pessoais estão consultando o novo DNS

---

### Fase 3 — Proxy Reverso (NPM)

- [ ] **3.1** Subir NPM: `cd /srv/services/proxy && docker compose up -d`
- [ ] **3.2** Acessar painel via IP direto inicialmente (`:81`)
- [ ] **3.3** Emitir certificado wildcard `*.srv.maiahub.com.br` via DNS Challenge (Cloudflare)
- [ ] **3.4** Criar Access List "tailscale-only": allow `100.64.0.0/10`
- [ ] **3.5** Criar proxy host para o próprio NPM: `npm.srv.maiahub.com.br` (com Access List)
- [ ] **3.6** Adicionar demais proxy hosts conforme tabela da seção 6.2 (à medida que os serviços sobem)

---

### Fase 4 — Gerenciamento e Monitoramento

- [ ] **4.1** Subir Portainer: `cd /srv/services/management && docker compose up -d`
- [ ] **4.2** Configurar proxy host no NPM (tailscale-only)
- [ ] **4.3** Subir Uptime Kuma + Netdata: `cd /srv/services/monitoring && docker compose up -d`
- [ ] **4.4** Configurar monitores no Uptime Kuma para cada serviço
- [ ] **4.5** Configurar alertas (Telegram recomendado — fácil de configurar via bot)

---

### Fase 5 — Nextcloud

- [ ] **5.1** Subir a stack: `cd /srv/services/cloud && docker compose up -d`
- [ ] **5.2** Aguardar inicialização e acessar `cloud.srv.maiahub.com.br`
- [ ] **5.3** Configurar proxy host no NPM (público, Force SSL, HTTP/2)
- [ ] **5.4** Instalar todos os apps listados na seção 6.3
- [ ] **5.5** Configurar Collabora, Elasticsearch, ClamAV, notify_push nas configurações admin
- [ ] **5.6** Transferir os 7GB de arquivos:

  ```bash
  rsync -avz --progress ~/nextcloud_files/ /mnt/data/nextcloud/userdata/rmf/files/
  docker exec nextcloud php occ files:scan --all
  ```

- [ ] **5.7** Reimportar contatos (`.vcf`), calendários (`.ics`), tarefas (`.ics`), feeds (`.opml`)
- [ ] **5.8** Configurar DAVx⁵ no Android apontando para o novo servidor
- [ ] **5.9** Validar sincronização de contatos e calendários nos dispositivos
- [ ] **5.10** Desligar Nextcloud na Hostinger

---

### Fase 6 — Mídia (Jellyfin + Arr Stack)

- [ ] **6.1** Subir a stack: `cd /srv/services/media && docker compose up -d`
- [ ] **6.2** Configurar proxy host Jellyfin no NPM (público)
- [ ] **6.3** Configurar Prowlarr com indexadores
- [ ] **6.4** Conectar Sonarr e Radarr ao Prowlarr e ao qBittorrent
- [ ] **6.5** Adicionar biblioteca de mídia no Jellyfin apontando para `/mnt/data/media/`
- [ ] **6.6** Criar usuário para namorada no Jellyfin

---

### Fase 7 — Localização (Dawarich)

- [ ] **7.1** Subir Dawarich: `cd /srv/services/location && docker compose up -d`
- [ ] **7.2** Configurar proxy host no NPM (tailscale-only)
- [ ] **7.3** Importar histórico do Google Maps (Takeout) se desejado
- [ ] **7.4** Configurar app Overland nos dispositivos Android apontando para o Dawarich

---

### Fase 8 — Backup

- [ ] **8.1** Instalar Rclone e configurar remote Backblaze B2
- [ ] **8.2** Criar bucket no B2 com Object Lock habilitado (30 dias de retenção)
- [ ] **8.3** Testar script de backup manualmente: `/srv/backup/backup.sh`
- [ ] **8.4** Verificar arquivos chegando no bucket B2
- [ ] **8.5** Configurar crontab para execução diária
- [ ] **8.6** Documentar e testar procedimento de restore (`backup/restore.sh`)
- [ ] **8.7** Configurar rclone no PC local para pull semanal do B2

---

### Fase 9 — Corte Final

- [ ] **9.1** Validar todos os serviços Oracle funcionando por mínimo 48h
- [ ] **9.2** Confirmar backup automático executando e chegando no B2
- [ ] **9.3** Confirmar sincronização de contatos/calendários funcionando nos dispositivos
- [ ] **9.4** Testar acesso da namorada ao Nextcloud e Jellyfin
- [ ] **9.5** Cancelar/suspender VPS Hostinger
- [ ] **9.6** Atualizar `docs/migration-log.md` com o resultado final

---

## 11. Pontos de Atenção e Riscos

### Críticos

| #   | Risco                                                  | Mitigação                                                                                   |
| --- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| 1   | DNS Rewrite desatualizado após troca de IP             | Atualizar o rewrite no AdGuard é o **primeiro passo** após obter o IP Oracle                |
| 2   | Split tunnel Proton VPN quebra Tailscale               | Configurar split tunnel excluindo `tailscale0` e `100.64.0.0/10` antes de ligar kill switch |
| 3   | Elasticsearch versão incompatível com plugin Nextcloud | Verificar versão compatível antes de subir a stack                                          |
| 4   | Volume `/mnt/data` não montado causa perda de dados    | Verificar `/etc/fstab` com `nofail` e testar `mount -a` antes de subir serviços             |

### Importantes

| #   | Risco                                       | Mitigação                                                        |
| --- | ------------------------------------------- | ---------------------------------------------------------------- |
| 5   | Armazenamento de mídia esgotando os 150GB   | Monitorar com Netdata + alertas no Uptime Kuma para uso de disco |
| 6   | Backup não testado = backup inválido        | Executar restore de teste na Fase 8 antes de cancelar Hostinger  |
| 7   | `NEXTCLOUD_TRUSTED_DOMAINS` mal configurado | Definir corretamente `cloud.srv.maiahub.com.br` antes de subir   |
| 8   | Certificados expirando silenciosamente      | Monitor no Uptime Kuma com check de certificado SSL              |

### Baixo Risco

| #   | Observação                                                 |
| --- | ---------------------------------------------------------- |
| 9   | Portainer pode ser reinstalado do zero sem perda relevante |
| 10  | Logs dos containers não precisam ser migrados              |
| 11  | Estatísticas do AdGuard podem ser zeradas                  |

---

## 12. Architecture Decision Records (ADRs)

### ADR-001 — Docker por serviço vs. Compose único

**Status:** Aceito | **Data:** 2026-04-27

**Contexto:** O servidor executa múltiplos serviços com ciclos de vida e responsabilidades diferentes.

**Decisão:** Cada serviço/stack tem seu próprio `compose.yaml` em diretório separado.

**Consequências:**

- ✅ Falha em um serviço não derruba os demais
- ✅ Updates independentes por serviço
- ✅ Git history claro e rastreável por serviço
- ✅ Mais fácil de documentar e apresentar como portfólio
- ⚠️ A rede `proxy` precisa existir antes de qualquer stack (`docker network create proxy`)

---

### ADR-002 — Tailscale como VPN principal

**Status:** Aceito | **Data:** 2026-04-27

**Contexto:** Necessidade de acesso privado aos serviços da VPS a partir de múltiplos dispositivos, incluindo Android (que suporta apenas uma VPN ativa).

**Decisão:** Tailscale como camada de rede privada + exit node. Proton VPN rodando na VPS (não nos dispositivos) para mascarar o IP de saída.

**Consequências:**

- ✅ Android pode usar Tailscale como única VPN e ter tanto acesso privado quanto mascaramento de IP
- ✅ Sem necessidade de gerenciar chaves WireGuard manualmente
- ⚠️ Dependência de um serviço de coordenação externo (painel Tailscale) — funciona mesmo offline, mas novos dispositivos precisam de conectividade para entrar na rede

---

### ADR-003 — Nextcloud standalone vs. AIO

**Status:** Aceito | **Data:** 2026-04-27

**Contexto:** Nextcloud AIO simplifica o deploy mas é uma caixa-preta difícil de versionar, debugar e documentar. O objetivo do projeto inclui portfólio técnico.

**Decisão:** Stack Nextcloud manual com containers separados (`nextcloud`, `postgres`, `redis`, `collabora`, `elasticsearch`, `clamav`, `notify_push`, `imaginary`).

**Consequências:**

- ✅ Controle total de cada variável de ambiente e volume
- ✅ Compose file totalmente versionável e documentável
- ✅ Mais fácil de debugar problemas por componente
- ⚠️ Mais trabalho de configuração inicial
- ⚠️ Responsabilidade manual de manter compatibilidade entre versões dos componentes

---

### ADR-004 — PostgreSQL vs. MariaDB para Nextcloud

**Status:** Aceito | **Data:** 2026-04-27

**Contexto:** O Nextcloud suporta MySQL/MariaDB e PostgreSQL. O AIO usa PostgreSQL por padrão.

**Decisão:** PostgreSQL 16 para o Nextcloud.

**Consequências:**

- ✅ Melhor performance para workloads de busca e dados estruturados
- ✅ Consistência com o que o AIO usa (facilita eventual migração de dados existentes)
- ✅ Suporte nativo a tipos de dados mais ricos (JSONB, arrays)

---

### ADR-005 — Estratégia de backup: Restic + Rclone + Snapshots OCI

**Status:** Aceito | **Data:** 2026-04-27

**Contexto:** Sem backup no servidor atual. Necessidade de estratégia confiável, com versionamento real para dados pessoais e proteção contra ransomware.

**Decisão:** Stack de três ferramentas com responsabilidades distintas: Restic para dados com versionamento (Nextcloud, bancos), Rclone para mídia sem versionamento, Snapshots OCI para estado da VM antes de mudanças de infra.

**Consequências:**

- ✅ Cumpre a regra 3-2-1 (VPS vivo + PC local + B2 offsite)
- ✅ Restic permite restaurar o estado dos dados em qualquer ponto no tempo (diário/semanal/mensal)
- ✅ Restic tem criptografia e deduplicação embutidas — repositório B2 é menor que um rclone sync puro
- ✅ Object Lock no B2 protege contra deleção acidental ou maliciosa
- ✅ Snapshots OCI permitem rollback instantâneo da VM inteira
- ✅ Rclone para mídia é mais simples e eficiente para grandes volumes sem necessidade de histórico
- ⚠️ Restic requer inicialização do repositório antes do primeiro backup (`restic init`)
- ⚠️ A senha do repositório Restic é irrecuperável — deve ser armazenada em local seguro fora da VPS

---

## 13. Referência de Comandos Úteis

```bash
# === DOCKER ===

# Ver todos os containers rodando
docker ps -a

# Logs de um serviço (últimas 100 linhas, seguindo)
docker compose -f /srv/services/<nome>/compose.yaml logs -f --tail=100

# Reiniciar um serviço
cd /srv/services/<nome> && docker compose restart

# Subir/atualizar um serviço
cd /srv/services/<nome> && docker compose pull && docker compose up -d

# Ver uso de disco por volume
docker system df -v

# Limpar recursos não utilizados (cuidado em produção)
docker system prune -f


# === NEXTCLOUD ===

# Rodar comando occ
docker exec -u www-data nextcloud php occ <comando>

# Reescanear arquivos após cópia manual
docker exec -u www-data nextcloud php occ files:scan --all

# Modo manutenção ON/OFF
docker exec -u www-data nextcloud php occ maintenance:mode --on
docker exec -u www-data nextcloud php occ maintenance:mode --off

# Ver apps instalados
docker exec -u www-data nextcloud php occ app:list


# === REDE ===

# Checar IP Tailscale da VPS
tailscale ip -4

# Testar DNS do AdGuard
dig @<IP_TAILSCALE_VPS> cloud.srv.maiahub.com.br
nslookup portainer.srv.maiahub.com.br <IP_TAILSCALE_VPS>

# Inspecionar rede Docker proxy
docker network inspect proxy

# Ver interfaces de rede
ip addr show


# === BACKUP ===

# Executar backup manualmente
source /etc/homelab-backup.env && /srv/backup/backup.sh

# Listar snapshots disponíveis no Restic
source /etc/homelab-backup.env
restic -r b2:homelab-backup-restic snapshots

# Verificar integridade do repositório Restic
restic -r b2:homelab-backup-restic check

# Restaurar snapshot mais recente para diretório temporário
restic -r b2:homelab-backup-restic restore latest --target /tmp/restore-test/

# Restaurar snapshot específico (usar ID da listagem acima)
restic -r b2:homelab-backup-restic restore <snapshot-id> --target /tmp/restore-test/

# Listar arquivos dentro de um snapshot
restic -r b2:homelab-backup-restic ls latest

# Ver tamanho do repositório no B2
restic -r b2:homelab-backup-restic stats

# Sync de mídia manual
/srv/backup/backup-media.sh

# Ver tamanho do bucket de mídia no B2
rclone size backblaze:homelab-backup-media


# === SISTEMA ===

# Verificar uso de disco
df -h
du -sh /mnt/data/*

# Verificar uso de memória
free -h

# Ver logs do sistema
journalctl -f

# Status do Tailscale
tailscale status

# Status do Proton VPN
protonvpn-cli status
```

---

_Documento mantido em `/srv/docs/` — atualizar conforme o projeto evolui._  
_Versão deste documento: acompanhar via `git log docs/` no repositório._
