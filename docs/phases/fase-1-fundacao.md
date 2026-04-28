# Fase 1 — Fundação Oracle Cloud

## Guia de Execução Completo

**Projeto:** Homelab  
**Fase:** 1 de 9  
**Objetivo:** Repositório Git, infraestrutura OCI, Docker, Tailscale e Proton VPN  
**Tempo estimado:** 3–5 horas (dependendo de disponibilidade de VMs ARM na OCI)

---

## Antes de começar

### O que você vai precisar ter em mãos

- Conta na Oracle Cloud (criar em cloud.oracle.com se ainda não tiver)
- Cartão de crédito para ativar Pay As You Go (não será cobrado dentro do free tier)
- Conta no GitHub
- Conta no Tailscale (tailscale.com — plano gratuito é suficiente)
- Conta na Proton VPN com suporte a CLI (plano pago)
- Sua chave SSH pública (`~/.ssh/id_ed25519.pub` ou similar)
- Domínio `maiahub.com.br` com DNS no Cloudflare (já existe)

### Fluxo de trabalho desta fase

```text
Máquina local (Fedora)          GitHub              VM Oracle
       │                           │                     │
       │  edita / cria arquivos    │                     │
       │──────────────────────────►│                     │
       │  git push                 │                     │
       │                           │  git pull / clone   │
       │                           │────────────────────►│
       │                           │                     │  executa scripts
       │                           │                     │  configura serviços
```

Tudo que for script, config, ou documentação nasce na sua máquina local e vai para o GitHub. A VM consome o que está no GitHub. Os únicos arquivos que existem **só na VM** são os `.env` com credenciais reais — esses nunca entram no Git.

---

## Etapa 1 — Repositório Git local

> Faça tudo desta etapa na sua **máquina local** antes de tocar na OCI.

### 1.1 — Criar a estrutura do repositório

```bash
# Escolha onde vai ficar o repo na sua máquina
mkdir ~/projetos/homelab && cd ~/projetos/homelab
git init
```

### 1.2 — Criar o .gitignore (PRIMEIRO arquivo, antes de qualquer outro)

Esta é a etapa mais importante de segurança do repositório. Criá-lo antes de qualquer outro arquivo garante que nada sensível será commitado por acidente.

```bash
cat > .gitignore << 'EOF'
# Segredos e credenciais — NUNCA commitar
.env
*.secret
secrets/

# Dados gerados pelos containers em runtime
**/data/
**/letsencrypt/
**/*.log
logs/

# Dumps de banco de dados
*.sql
*.sql.gz

# Backups locais temporários
backup/local/

# Sistema operacional
.DS_Store
Thumbs.db
*~
EOF
```

### 1.3 — Criar a estrutura de diretórios

```bash
# Diretórios dos serviços
mkdir -p infrastructure
mkdir -p services/{dns,proxy,cloud,media,management,monitoring,location}
mkdir -p backup
mkdir -p docs/decisions

# .gitkeep em cada diretório vazio
# (o Git não rastreia diretórios vazios — o .gitkeep é um placeholder)
find . -type d -empty -not -path './.git/*' -exec touch {}/.gitkeep \;
```

> **Sobre o `.gitkeep`:** É um arquivo vazio sem conteúdo algum. Existe apenas para que o Git rastreie o diretório. Quando você criar arquivos reais dentro de cada pasta (compose.yaml, README.md, etc.), o `.gitkeep` pode ser deletado — ele já terá cumprido seu papel.

### 1.4 — Criar o README.md

```bash
cat > README.md << 'EOF'
# Homelab

Infraestrutura de auto-hospedagem rodando na Oracle Cloud Free Tier (ARM A1).

## Stack de serviços

| Serviço | URL | Acesso |
|---------|-----|--------|
| Nextcloud | cloud.srv.maiahub.com.br | Público |
| Jellyfin | jellyfin.srv.maiahub.com.br | Público |
| Nginx Proxy Manager | npm.srv.maiahub.com.br | Tailscale |
| Portainer | portainer.srv.maiahub.com.br | Tailscale |
| AdGuard Home | adguard.srv.maiahub.com.br | Tailscale |
| Uptime Kuma | monitoring.srv.maiahub.com.br | Tailscale |
| Netdata | netdata.srv.maiahub.com.br | Tailscale |
| Dawarich | dawarich.srv.maiahub.com.br | Tailscale |

## Infraestrutura

- **Provider:** Oracle Cloud Free Tier (ARM A1)
- **Shape:** VM.Standard.A1.Flex — 4 OCPU / 24 GB RAM
- **OS:** Ubuntu 22.04 LTS
- **Rede privada:** Tailscale (exit node + DNS)
- **VPN de saída:** Proton VPN (kill switch + split tunnel)

## Documentação

- [Arquitetura de rede](docs/network-diagram.md)
- [Runbook operacional](RUNBOOK.md)
- [Decisions (ADRs)](docs/decisions/)
- [Diário de execução](docs/migration-log.md)
- [Changelog](CHANGELOG.md)

## Repositório

github.com/SEU_USUARIO/homelab

## Como replicar do zero

1. Configurar conta OCI e ativar Pay As You Go
2. Executar `infrastructure/provision.sh` em VM Ubuntu 22.04 ARM
3. Seguir os READMEs de cada serviço em `services/`
4. Ver `RUNBOOK.md` para operações do dia a dia
EOF
```

### 1.5 — Criar o CHANGELOG.md

```bash
cat > CHANGELOG.md << 'EOF'
# Changelog

Mudanças relevantes na infraestrutura do homelab.
Formato: [Keep a Changelog](https://keepachangelog.com)

---

## [Unreleased]

## [v1.0-foundation] — Em progresso

### Added
- Estrutura inicial do repositório Git
- Infraestrutura Oracle Cloud: VCN, Security List, VM A1 (4 OCPU / 24 GB)
- Docker CE instalado, rede Docker `proxy` criada
- Tailscale como exit node e nameserver DNS privado
- Proton VPN com kill switch e split tunnel (exclui Tailscale)
- Scripts de provisioning em `infrastructure/`
- Documentação: diagrama de rede, migration log, ADRs iniciais
EOF
```

### 1.6 — Criar infrastructure/README.md

````bash
cat > infrastructure/README.md << 'EOF'
# Infrastructure

Scripts de provisionamento e configuração da VM Oracle Cloud.

## Arquivos

| Arquivo | Descrição |
|---------|-----------|
| `provision.sh` | Instalação completa do zero (Docker, dirs, rede proxy) |
| `firewall.sh` | Regras ufw — referência para a OCI Security List |

## Como usar

### Primeiro boot da VM

```bash
# Clonar o repositório
git clone https://github.com/SEU_USUARIO/homelab.git /tmp/homelab-setup

# Executar o provisioning (requer sudo)
sudo bash /tmp/homelab-setup/infrastructure/provision.sh

# Fazer logout e login novamente (grupo docker)
exit
```

### Após o provisioning

1. Instalar Tailscale (ver seção 4 do guia de execução)
2. Instalar Proton VPN CLI (ver seção 5 do guia de execução)
3. Clonar o repositório definitivo em /srv

## Pré-requisitos

- Ubuntu 22.04 LTS (ARM ou x86_64)
- Acesso root / sudo
- Conexão com a internet
  EOF
````

### 1.7 — Criar o script infrastructure/provision.sh

```bash
cat > infrastructure/provision.sh << 'SCRIPT'
#!/bin/bash
# =============================================================================
# Homelab — provision.sh
# Provisionamento inicial da VM Oracle Cloud (Ubuntu 22.04 ARM)
#
# Executa UMA ÚNICA VEZ na VM recém-criada.
# Uso: sudo bash provision.sh
#
# O que este script faz:
#   1. Atualiza o sistema
#   2. Instala dependências base (curl, git, vim, htop, ufw, fail2ban)
#   3. Instala Docker CE e Docker Compose plugin
#   4. Configura o firewall ufw
#   5. Cria a estrutura de diretórios em /mnt/data
#   6. Cria a rede Docker 'proxy'
# =============================================================================

set -euo pipefail

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓ $1${NC}"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}"; }
error()   { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $1${NC}"; exit 1; }
section() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then
    error "Execute como root: sudo bash provision.sh"
fi

section "1/6 — Atualizando sistema"
apt-get update -qq
apt-get upgrade -y
log "Sistema atualizado"

section "2/6 — Instalando dependências base"
apt-get install -y \
    curl \
    wget \
    git \
    vim \
    htop \
    ca-certificates \
    gnupg \
    ufw \
    fail2ban \
    unattended-upgrades \
    apt-transport-https \
    software-properties-common
log "Dependências instaladas"

section "3/6 — Instalando Docker CE"
# Remover versões antigas se existirem
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Adicionar repositório oficial Docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Adicionar usuário ubuntu ao grupo docker
usermod -aG docker ubuntu

# Habilitar e iniciar Docker
systemctl enable docker
systemctl start docker

log "Docker $(docker --version) instalado"

section "4/6 — Configurando firewall (ufw)"
ufw default deny incoming
ufw default allow outgoing

# Regras de entrada
ufw allow 22/tcp    comment 'SSH'
ufw allow 80/tcp    comment 'HTTP - NPM redirect'
ufw allow 443/tcp   comment 'HTTPS - NPM'
ufw allow 41641/udp comment 'Tailscale WireGuard'

# Ativar sem prompt
ufw --force enable

log "Firewall configurado"
ufw status verbose

section "5/6 — Criando estrutura de diretórios"
# Dados das aplicações em /mnt/data
# (por ora no boot volume; block volume extra adicionado quando necessário)
mkdir -p /mnt/data/nextcloud/userdata
mkdir -p /mnt/data/media/{movies,tv,music}
mkdir -p /mnt/data/media/downloads/{complete,incomplete}
mkdir -p /mnt/data/backups/local
mkdir -p /mnt/data/location/imports

# Diretório para o repositório homelab
mkdir -p /srv

log "Estrutura de diretórios criada em /mnt/data"

section "6/6 — Criando rede Docker 'proxy'"
# Esta rede é compartilhada por todos os serviços que precisam
# ser acessados pelo Nginx Proxy Manager.
# Deve existir antes de qualquer stack ser iniciada.
docker network create proxy 2>/dev/null || warn "Rede 'proxy' já existe — ok"

log "Rede Docker 'proxy' criada"

# =============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Provisioning concluído com sucesso!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Próximos passos:"
echo "  1. Faça logout e login novamente (para o grupo docker ter efeito)"
echo "  2. Teste: docker ps (deve funcionar sem sudo)"
echo "  3. Clone o repositório: git clone <URL> /srv"
echo "  4. Instale o Tailscale (ver guia de execução - Etapa 4)"
echo "  5. Instale o Proton VPN CLI (ver guia de execução - Etapa 5)"
echo ""
SCRIPT

chmod +x infrastructure/provision.sh
```

### 1.8 — Primeiro commit

```bash
git add .
git commit -m "chore: initial repo structure, gitignore, and provision script"
```

### 1.9 — Criar repositório no GitHub e fazer push

No GitHub, crie um repositório chamado `homelab` (pode ser privado ou público — sua escolha). Depois conecte e envie:

```bash
git remote add origin git@github.com:SEU_USUARIO/homelab.git
git branch -M main
git push -u origin main
```

Atualize o README com a URL real do repositório:

```bash
# Edite README.md e substitua SEU_USUARIO pelo seu username real
# Depois:
git add README.md
git commit -m "docs: add real repo URL to README"
git push
```

✅ **Checkpoint 1:** Repositório existe no GitHub com a estrutura base e o provision.sh. Antes de continuar, confirme que o push funcionou abrindo o repositório no browser.

---

## Etapa 2 — Oracle Cloud: conta e rede

> Tudo desta etapa é feito no **console web da OCI** (cloud.oracle.com).

### 2.1 — Ativar Pay As You Go

Este passo é crítico para conseguir provisionar VMs ARM A1. Sem ele, a Oracle frequentemente nega o provisionamento com erro de "Out of host capacity" mesmo tendo recursos livres.

```text
Menu superior direito → Billing & Cost Management
→ Payment Method
→ Add Credit Card (preencher dados do cartão)
→ Confirmar ativação do Pay As You Go
```

> Você **não será cobrado** enquanto ficar dentro dos limites do free tier (4 OCPU ARM, 24 GB RAM, 200 GB storage, 10 TB egress/mês). O cartão só é debitado se você criar recursos além do free tier.

### 2.2 — Criar a VCN (Virtual Cloud Network)

```text
Menu principal (hambúrguer) → Networking → Virtual Cloud Networks
→ Start VCN Wizard
→ Selecionar: "Create VCN with Internet Connectivity"
→ Preencher:
    VCN Name: VCN-Homelab
    VCN IPv4 CIDR Block: 10.0.0.0/16
    Public Subnet IPv4 CIDR Block: 10.0.0.0/24
    Private Subnet IPv4 CIDR Block: 10.0.1.0/24
→ Next → Create VCN
```

Aguarde a criação (~30 segundos).

### 2.3 — Configurar a Security List

A Security List controla quais portas aceitam tráfego externo. Precisamos configurar as **Ingress Rules** (entrada).

```text
Networking → Virtual Cloud Networks → VCN-Homelab
→ Security Lists → Default Security List for VCN-Homelab
→ Add Ingress Rules
```

Adicione as seguintes regras (uma por vez):

| Stateless | Source        | Protocol | Porta destino | Descrição                     |
| --------- | ------------- | -------- | ------------- | ----------------------------- |
| Não       | 0.0.0.0/0     | TCP      | 80            | HTTP - redirect HTTPS via NPM |
| Não       | 0.0.0.0/0     | TCP      | 443           | HTTPS                         |
| Não       | **SEU_IP/32** | TCP      | 22            | SSH (apenas seu IP)           |
| Não       | 0.0.0.0/0     | UDP      | 41641         | Tailscale WireGuard           |

- **Porta 22:** Coloque **apenas o seu IP atual** (você pode descobrir em <https://api.ipify.org>). Nunca deixe SSH aberto para 0.0.0.0/0 — é o convite mais direto para ataques de força bruta. Depois que o Tailscale estiver funcionando, você vai remover essa regra inteiramente.

- **Porta 53 ausente intencionalmente:** O AdGuard Home (DNS) só vai escutar na interface Tailscale, não na interface pública. Portanto não precisa de regra pública para essa porta.

### 2.4 — Verificar o resultado da Security List

Ao final, as Ingress Rules devem estar assim:

```text
Regras de entrada (Ingress):
  TCP  0.0.0.0/0      → porta 80    (HTTP)
  TCP  0.0.0.0/0      → porta 443   (HTTPS)
  TCP  SEU_IP/32      → porta 22    (SSH)
  UDP  0.0.0.0/0      → porta 41641 (Tailscale)

Regras de saída (Egress) — padrão, não alterar:
  All  0.0.0.0/0      → All         (permitir todo tráfego de saída)
```

✅ **Checkpoint 2:** VCN criada com Internet Gateway e Security List configurada.

---

## Etapa 3 — Oracle Cloud: provisionar a VM

### 3.1 — Criar a instância

```text
Menu principal → Compute → Instances
→ Create Instance
```

Preencha cada seção:

**Name and placement:**

```text
Name: homelab-oracle
Compartment: (deixar o padrão)
Availability Domain: (qualquer um disponível)
```

**Image and shape:**

```text
Image: Ubuntu 22.04 LTS (Minimal)
  → Change Image → Platform Images → Ubuntu → 22.04 Minimal aarch64
Shape: VM.Standard.A1.Flex
  → Change Shape → Ampere → A1.Flex
  → OCPUs: 4
  → Memory: 24 GB
```

**Networking:**

```text
Virtual cloud network: VCN-Homelab
Subnet: Public Subnet-VCN-Homelab
Assign a public IPv4 address: Yes
```

**SSH keys:**

```text
→ Paste public keys
→ Cole o conteúdo do seu ~/.ssh/id_ed25519.pub
```

**Boot volume:**

```text
Boot volume size: 50 GB (padrão)
(não alterar — o free tier dá 200 GB total; deixaremos 150 GB para um block volume separado quando necessário)
```

Clique em **Create** e aguarde o status mudar para **Running** (2–5 minutos).

### 3.2 — Anotar as informações da instância

Quando a VM estiver Running, anote:

```text
IP Público: ___________________
OCID da instância: ___________________
Boot Volume OCID: ___________________ (para o snapshot depois)
```

Esses dados vão direto para o `docs/migration-log.md`.

### 3.3 — Possível erro: "Out of host capacity"

Se aparecer esse erro ao criar a VM ARM A1, é porque a Oracle não tem capacidade disponível naquela região/AD naquele momento. Opções:

1. **Tentar outro Availability Domain** (AD-1, AD-2, AD-3) na mesma região
2. **Tentar outro horário** — madrugada costuma ter mais disponibilidade
3. **Tentar outra região** — algumas regiões têm mais capacidade ARM disponível (us-ashburn-1, eu-frankfurt-1)
4. **Aguardar** — a Oracle libera capacity ao longo do dia conforme outras instâncias são terminadas

Com Pay As You Go ativo, a chance de conseguir é significativamente maior.

✅ **Checkpoint 3:** VM rodando com IP público anotado.

---

## Etapa 4 — Primeiro acesso e configuração da VM

### 4.1 — Conectar via SSH

```bash
# Na sua máquina local
ssh ubuntu@IP_PÚBLICO_ORACLE
```

Se der erro de permissão, verifique se está usando a chave certa:

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@IP_PÚBLICO_ORACLE
```

### 4.2 — Hardening básico do SSH

Antes de qualquer outra coisa, fortaleça o acesso SSH:

```bash
sudo vim /etc/ssh/sshd_config
```

Localize e ajuste (ou adicione) estas linhas:

```text
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
```

Reinicie o serviço SSH (não feche a sessão atual antes de testar):

```bash
sudo systemctl reload sshd
```

Abra **uma segunda aba no terminal** e teste o acesso:

```bash
# Em outra aba/janela
ssh ubuntu@IP_PÚBLICO_ORACLE
```

Se funcionou, pode fechar a aba de teste e continuar na sessão original.

### 4.3 — Executar o script de provisioning

```bash
# Ainda na VM — clonar o repositório temporariamente para pegar o script
git clone https://github.com/SEU_USUARIO/homelab.git /tmp/homelab-setup

# Executar o provisioning
sudo bash /tmp/homelab-setup/infrastructure/provision.sh
```

O script vai mostrar o progresso de cada etapa. Ao final, a saída deve ser:

```text
============================================
  Provisioning concluído com sucesso!
============================================
```

### 4.4 — Fazer logout e login novamente

O grupo `docker` só tem efeito após uma nova sessão:

```bash
exit
ssh ubuntu@IP_PÚBLICO_ORACLE
```

### 4.5 — Verificar instalação do Docker

```bash
# Deve funcionar sem sudo
docker ps
docker network ls | grep proxy
```

Saída esperada do `docker network ls`:

```text
NETWORK ID     NAME      DRIVER    SCOPE
xxxxxxxxxxxx   bridge    bridge    local
xxxxxxxxxxxx   host      host      local
xxxxxxxxxxxx   none      null      local
xxxxxxxxxxxx   proxy     bridge    local   ← deve aparecer aqui
```

### 4.6 — Clonar o repositório definitivo em /srv

```bash
sudo git clone https://github.com/SEU_USUARIO/homelab.git /srv
sudo chown -R ubuntu:ubuntu /srv
```

A partir daqui, `/srv` é o repositório na VM. Para atualizar com mudanças do GitHub:

```bash
cd /srv && git pull
```

### 4.7 — Verificar estrutura de diretórios

```bash
ls -la /mnt/data/
```

Deve mostrar:

```text
drwxr-xr-x nextcloud/
drwxr-xr-x media/
drwxr-xr-x backups/
drwxr-xr-x location/
```

```bash
ls -la /mnt/data/media/
# movies/  tv/  music/  downloads/
```

✅ **Checkpoint 4:** VM configurada, Docker funcionando, rede proxy criada, repo clonado em /srv.

---

## Etapa 5 — Tailscale

O Tailscale vai criar a rede privada entre seus dispositivos e a VM. A VM será o **exit node** (todo tráfego de internet dos seus dispositivos vai passar por ela) e depois também o **nameserver DNS** (quando o AdGuard subir na Fase 2).

### 5.1 — Instalar Tailscale na VM

```bash
# Na VM
curl -fsSL https://tailscale.com/install.sh | sh
```

### 5.2 — Habilitar IP forwarding

Obrigatório para o funcionamento do exit node:

```bash
# Adicionar ao sysctl
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding=1' | sudo tee -a /etc/sysctl.conf

# Aplicar imediatamente (sem reiniciar)
sudo sysctl -p

# Verificar
sysctl net.ipv4.ip_forward
# Deve retornar: net.ipv4.ip_forward = 1
```

### 5.3 — Autenticar e configurar como exit node

```bash
sudo tailscale up --advertise-exit-node
```

O comando vai exibir uma URL de autenticação parecida com:

```text
To authenticate, visit:

        https://login.tailscale.com/a/XXXXXXXXXXXXXXXX
```

Abra essa URL no browser e faça login na sua conta Tailscale. A VM vai aparecer como um novo dispositivo na rede.

### 5.4 — Anotar o IP Tailscale da VM

```bash
tailscale ip -4
# Exemplo: 100.xx.xx.xx
```

Anote esse IP — ele será usado na Fase 2 para configurar o DNS.

### 5.5 — Configurar o painel Tailscale Admin

Abra <https://login.tailscale.com/admin/machines> no browser.

**Aprovar o exit node:**

```text
Encontre a VM "homelab-oracle" na lista
→ clique nos três pontos (...)
→ Edit route settings
→ Ative "Use as exit node"
→ Save
```

**Configurar DNS (deixar pronto para a Fase 2):**

```text
Menu: DNS
→ Add nameserver
→ Custom
→ IP: <IP_TAILSCALE_DA_VM> (o que você anotou acima)
→ Marcar: "Override local DNS"
→ Save
```

> **Nota:** Com o Override local DNS ativado, todos os seus dispositivos com Tailscale passarão a usar o AdGuard como DNS assim que ele for configurado na Fase 2. Por enquanto não vai quebrar nada — o Tailscale vai tentar consultar o IP da VM na porta 53, mas como o AdGuard ainda não está rodando, vai fazer fallback para o DNS padrão.

### 5.6 — Verificar status do Tailscale

```bash
tailscale status
```

Saída esperada: a VM aparece como `online` e outros dispositivos com Tailscale instalado também aparecem listados.

### 5.7 — Testar acesso via Tailscale

Na sua **máquina local**, tente conectar via SSH usando o IP Tailscale da VM (não o IP público):

```bash
# Na máquina local
ssh ubuntu@100.xx.xx.xx  # IP Tailscale da VM
```

Se funcionar, você tem acesso privado e criptografado à VM independentemente de qualquer regra de firewall público.

✅ **Checkpoint 5:** Tailscale funcionando, exit node aprovado, SSH via IP Tailscale funcionando.

---

## Etapa 6 — Proton VPN CLI

O Proton VPN vai rodar **na VM** (não nos seus dispositivos) para mascarar o IP de saída da VM na internet. Com o Tailscale como exit node, todo o tráfego dos seus dispositivos já passa pela VM — então o Proton VPN faz com que sites externos vejam o IP do servidor Proton, não o IP real da Oracle.

**Configuração crítica:** O kill switch do Proton VPN bloqueia todo tráfego que não passa pelo túnel VPN. Sem o split tunnel configurado corretamente, o Tailscale para de funcionar quando a Proton VPN sobe. Por isso o split tunnel para excluir o range `100.64.0.0/10` (rede Tailscale) é obrigatório.

### 6.1 — Instalar o Proton VPN CLI

```bash
# Na VM
# Adicionar repositório oficial Proton
wget -qO- https://repo.protonvpn.com/debian/public_key.asc \
    | sudo gpg --dearmor -o /usr/share/keyrings/protonvpn-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/protonvpn-archive-keyring.gpg] \
    https://repo.protonvpn.com/debian stable main" \
    | sudo tee /etc/apt/sources.list.d/protonvpn.list

sudo apt-get update
sudo apt-get install -y protonvpn-cli
```

> Se o método acima não funcionar (o processo de instalação do Proton VPN muda com certa frequência), consulte a documentação oficial em: <https://protonvpn.com/support/linux-vpn-setup/>

### 6.2 — Login na conta Proton

```bash
protonvpn-cli login SEU_EMAIL_PROTON
```

O CLI vai pedir sua senha Proton.

### 6.3 — Configurar kill switch

```bash
protonvpn-cli killswitch --on
```

> ⚠️ **Atenção:** Depois de ativar o kill switch, se a VPN cair por qualquer motivo, o tráfego de saída para internet será bloqueado até a VPN reconectar. O acesso via Tailscale continua funcionando (porque vamos configurar o split tunnel no próximo passo).

### 6.4 — Configurar split tunnel (CRÍTICO)

```bash
# Excluir o range da rede Tailscale do túnel Proton
# Isso garante que o tráfego Tailscale nunca passe pelo kill switch
protonvpn-cli split-tunnel --add 100.64.0.0/10

# Verificar que foi adicionado
protonvpn-cli split-tunnel --list
```

### 6.5 — Conectar ao servidor mais rápido

```bash
protonvpn-cli connect --fastest
```

### 6.6 — Verificar que tudo está funcionando simultaneamente

```bash
# 1. Status da Proton VPN (deve mostrar conectado)
protonvpn-cli status

# 2. Verificar IP de saída (deve ser um IP da Proton, não da Oracle)
curl https://api.ipify.org
# Compare com o IP público da VM Oracle — devem ser diferentes

# 3. Status do Tailscale (deve estar online)
tailscale status

# 4. Em outra aba/janela na sua máquina local:
#    Conectar via SSH pelo IP Tailscale (deve continuar funcionando)
ssh ubuntu@100.xx.xx.xx
```

Se todos os quatro verificações passarem, a configuração está correta.

### 6.7 — Configurar reconexão automática da Proton VPN

Para que a VPN reconecte automaticamente após reboots:

```bash
# Criar serviço systemd para auto-reconexão
sudo cat > /etc/systemd/system/protonvpn-auto.service << 'EOF'
[Unit]
Description=ProtonVPN Auto Connect
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/protonvpn-cli connect --fastest
RemainAfterExit=yes
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable protonvpn-auto.service
```

✅ **Checkpoint 6:** Proton VPN conectada com kill switch, split tunnel excluindo Tailscale, IP externo = IP Proton, Tailscale continua funcionando.

---

## Etapa 7 — Documentação do estado final

Com a infraestrutura no ar, documente o estado real (não o planejado). Esses arquivos ficam no repositório e servem como referência futura.

### 7.1 — Criar docs/network-diagram.md

Faça isso na sua **máquina local**, preenchendo com os IPs reais:

````bash
cat > docs/network-diagram.md << 'EOF'
# Diagrama de Rede — Estado atual

**Atualizado em:** YYYY-MM-DD
**Versão:** v1.0-foundation

## Topologia

```

Dispositivos pessoais (celular / PC / notebook)
│
│ WireGuard (Tailscale)
▼
┌─────────────────────────────────────────────────────┐
│ VPS Oracle Cloud — ARM A1 │
│ │
│ IP público: **_._**.**_._** (OCI) │
│ IP Tailscale: 100.**.**.\_\_ (rede privada) │
│ │
│ Interfaces de rede: │
│ eth0 → Internet (IP público Oracle) │
│ tailscale0 → Rede privada Tailscale │
│ 100.64.0.0/10 │
│ protonvpn0 → Túnel Proton VPN │
│ (kill switch ON) │
│ (split tunnel: tailscale0 fora) │
│ │
│ Docker: │
│ rede proxy (bridge) │
│ /mnt/data → boot volume 50 GB │
│ │
│ Tailscale: exit node ativo │
│ Proton VPN: kill switch ON │
│ split tunnel: 100.64.0.0/10 excluído │
└─────────────────────────────────────────────────────┘
│
│ Proton VPN (WireGuard)
▼
Internet pública
(IP visível = servidor Proton VPN, não Oracle)

```

## Fluxo completo de tráfego

```

Meus dispositivos → [Tailscale] → VPS Oracle → [Proton VPN] → Internet
↑ ↑
DNS: AdGuard Kill switch ON
(Fase 2) Split tunnel:
Exit node ON tailscale0 excluído

```

## Configuração OCI

| Parâmetro | Valor |
|-----------|-------|
| Provider | Oracle Cloud Infrastructure |
| Região | _______________ |
| Shape | VM.Standard.A1.Flex |
| OCPUs | 4 |
| RAM | 24 GB |
| OS | Ubuntu 22.04 LTS (ARM) |
| Boot volume | 50 GB |
| IP público | _______________ |

## Security List — Regras de entrada ativas

| Porta | Protocolo | Origem | Serviço |
|-------|-----------|--------|---------|
| 22 | TCP | MEU_IP/32 | SSH (remover após Tailscale estável) |
| 80 | TCP | 0.0.0.0/0 | HTTP |
| 443 | TCP | 0.0.0.0/0 | HTTPS |
| 41641 | UDP | 0.0.0.0/0 | Tailscale WireGuard |

## Redes Docker ativas

| Rede | Driver | Escopo | Propósito |
|------|--------|--------|-----------|
| proxy | bridge | local | Compartilhada por todos os serviços acessados pelo NPM |

> As redes internas de cada stack (nextcloud_internal, media_internal etc.)
> serão criadas nas fases seguintes, quando os serviços subirem.

## O que ainda não está ativo nesta fase

- AdGuard Home (DNS privado) — Fase 2
- Nginx Proxy Manager — Fase 3
- Portainer / Uptime Kuma / Netdata — Fase 4
- Nextcloud — Fase 5
- Jellyfin + Arr Stack — Fase 6
- Dawarich — Fase 7
- Backup Restic + Rclone — Fase 8
- Block volume de 150 GB — quando /mnt/data crescer além do boot volume
EOF
````

### 7.2 — Criar docs/migration-log.md

```bash
cat > docs/migration-log.md << 'EOF'
# Migration Log

Diário de execução da migração Hostinger → Oracle Cloud.
Atualizado durante a execução de cada fase.

---

## YYYY-MM-DD — Fase 1: Fundação Oracle Cloud

### O que foi feito

- Repositório `homelab` criado no GitHub
- Conta OCI com Pay As You Go ativado
- VCN-Homelab criada com Internet Gateway e Public Subnet
- Security List configurada (portas 22, 80, 443, 41641/UDP)
- VM A1 provisionada: 4 OCPU / 24 GB / Ubuntu 22.04 ARM
- `provision.sh` executado: Docker, ufw, estrutura de diretórios
- Rede Docker `proxy` criada
- Tailscale instalado como exit node (aprovado no painel admin)
- Proton VPN CLI instalado com kill switch e split tunnel

### Configurações anotadas

- IP público Oracle: ___.___.___.___
- IP Tailscale da VM: 100.__.__.__
- Região OCI: _______________
- Availability Domain: _______________

### Decisões tomadas durante a execução

- Block volume de 150 GB adiado: boot volume de 50 GB suficiente para Fases 1–4
- `/mnt/data` usando boot volume por ora; será migrado para block volume quando necessário

### Problemas encontrados e soluções

*(preencher durante a execução)*

---

## Próximas fases

- **Fase 2** — AdGuard Home: DNS privado com bloqueio de trackers
- **Fase 3** — Nginx Proxy Manager: proxy reverso com SSL wildcard
- **Fase 4** — Portainer + Uptime Kuma + Netdata: gerenciamento e monitoramento
- **Fase 5** — Nextcloud: migração dos 7 GB de dados da Hostinger
- **Fase 6** — Jellyfin + Arr Stack: servidor de mídia
- **Fase 7** — Dawarich: histórico de localização
- **Fase 8** — Backup: Restic + Rclone + Backblaze B2
- **Fase 9** — Corte final: cancelar Hostinger
EOF
```

### 7.3 — Criar docs/decisions/ADR-001-docker-por-servico.md

Os ADRs documentam o "porquê" de cada decisão arquitetural importante. Crie os três primeiros da Fase 1:

```bash
cat > docs/decisions/ADR-001-docker-por-servico.md << 'EOF'
# ADR-001 — Docker por serviço vs. Compose único

**Status:** Aceito
**Data:** YYYY-MM-DD

## Contexto

O servidor executa múltiplos serviços com ciclos de vida e responsabilidades
diferentes: DNS, proxy reverso, cloud, mídia, monitoramento, localização.

## Decisão

Cada serviço ou stack tem seu próprio `compose.yaml` em diretório separado
dentro de `services/`. Todos compartilham a rede Docker `proxy` (externa, bridge)
que é criada uma única vez durante o provisioning.

## Consequências

**Positivas:**
- Falha em um serviço não derruba os demais
- Updates e restarts independentes por serviço
- Git history claro — cada serviço tem seus próprios commits
- Mais fácil de documentar, debugar e apresentar como portfólio

**Atenção:**
- A rede `proxy` precisa existir antes de qualquer stack ser iniciada
  (`docker network create proxy` — feito no provision.sh)
- Cross-stack networking requer nomes de container explícitos
  (`container_name:` no compose.yaml)
EOF

cat > docs/decisions/ADR-002-tailscale-vpn.md << 'EOF'
# ADR-002 — Tailscale como rede privada principal

**Status:** Aceito
**Data:** YYYY-MM-DD

## Contexto

Necessidade de acesso privado e seguro aos painéis de controle da VPS a partir
de múltiplos dispositivos, incluindo Android. O Android suporta apenas uma VPN
ativa por vez — o que cria um conflito entre acesso privado e mascaramento de IP.

## Decisão

Tailscale como camada de rede privada na VPS, configurado como exit node.
Proton VPN rodando **na VPS** (não nos dispositivos) para mascarar o IP de saída.
Split tunnel obrigatório excluindo `tailscale0` e `100.64.0.0/10` do túnel Proton.

## Consequências

**Positivas:**
- Android usa Tailscale como única VPN, tendo simultaneamente acesso aos
  serviços privados E mascaramento de IP via exit node
- Sem necessidade de gerenciar chaves WireGuard manualmente
- Tailscale SSH pode substituir regras de firewall SSH em IPs fixos

**Atenção:**
- Dependência de serviço externo (painel Tailscale) para novos dispositivos
- O split tunnel precisa ser configurado ANTES de ativar o kill switch Proton
- O IP Tailscale da VM muda se a instância for recriada — atualizar DNS Rewrite
EOF

cat > docs/decisions/ADR-003-boot-volume-fase1.md << 'EOF'
# ADR-003 — Boot volume para /mnt/data nas fases iniciais

**Status:** Aceito
**Data:** YYYY-MM-DD

## Contexto

O free tier OCI inclui 200 GB de block storage total. O boot volume usa 50 GB,
deixando 150 GB disponíveis para um block volume separado. O plano original
previa montar um block volume de 150 GB em `/mnt/data` desde o início.

## Decisão

Adiar a criação do block volume de 150 GB. Usar o espaço disponível no boot
volume de 50 GB para `/mnt/data` nas Fases 1 a 4 (infraestrutura base, sem
dados de usuário).

O block volume será criado, anexado e migrado quando houver necessidade real:
- Antes de subir o Nextcloud (Fase 5, que vai receber 7 GB de dados)
- Ou quando o uso de `/mnt/data` aproximar de 30 GB no boot volume

## Consequências

**Positivas:**
- Simplicidade: sem operação de attach/mount na configuração inicial
- Sem risco de incorrer em cobrança por block volume antes de ser necessário
- Mais fácil de fazer rollback/snapshot enquanto tudo cabe no boot volume

**Atenção:**
- A migração de `/mnt/data` para o block volume requer parar os serviços
  temporariamente e copiar os dados (procedimento documentado no RUNBOOK.md)
- Monitorar uso com `df -h` — agir antes de 80% de uso no boot volume
EOF
```

### 7.4 — Criar RUNBOOK.md inicial

````bash
cat > RUNBOOK.md << 'EOF'
# Runbook — Operações do Homelab

Referência rápida para operações do dia a dia.
Para procedimentos de disaster recovery, ver `docs/disaster-recovery.md`.

---

## Comandos essenciais

### Ver todos os containers

```bash
docker ps -a
```

### Logs de um serviço

```bash
# Últimas 100 linhas, seguindo em tempo real
docker compose -f /srv/services/<nome>/compose.yaml logs -f --tail=100
```

### Reiniciar um serviço

```bash
cd /srv/services/<nome> && docker compose restart
```

### Atualizar um serviço (pull + recreate)

```bash
cd /srv/services/<nome> && docker compose pull && docker compose up -d
```

### Verificar uso de disco

```bash
df -h                  # disco do sistema
du -sh /mnt/data/*     # cada diretório em /mnt/data
docker system df -v    # volumes Docker
```

### Atualizar o repositório na VM

```bash
cd /srv && git pull
```

---

## Status dos serviços de rede

```bash
tailscale status          # status da rede Tailscale
tailscale ip -4           # IP Tailscale da VM
protonvpn-cli status      # status da VPN
curl https://api.ipify.org # IP público atual (deve ser IP Proton)
```

---

## Verificar firewall

```bash
sudo ufw status verbose
```

---

## Fase 1 — Serviços ativos

Nenhum container rodando ainda (base apenas: Docker, Tailscale, Proton VPN).

## Fase 2+ — será atualizado conforme serviços subirem

EOF

````

### 7.5 — Commitar toda a documentação

```bash
# Na máquina local
git add .
git commit -m "docs: add network diagram, migration log, ADRs, and runbook for phase 1"
git push
```

---

## Etapa 8 — Snapshot inicial e commit final

### 8.1 — Tirar snapshot da VM no painel OCI

Antes de qualquer mudança futura, registre o estado inicial limpo da VM:

```text
OCI Console → Compute → Instances → homelab-oracle
→ Boot Volume (na seção de detalhes)
→ Create Boot Volume Backup
→ Name: homelab-v1-foundation-YYYYMMDD
→ Type: Full
→ Create Backup
```

O snapshot leva alguns minutos. Quando concluir, você tem um ponto de restauração completo da VM.

### 8.2 — Remover regra SSH pública (opcional, mas recomendado)

Se você já confirmou que o SSH via Tailscale funciona, remova a regra de SSH público da Security List:

```text
OCI Console → Networking → VCN-Homelab → Security Lists → Default Security List
→ Encontrar a regra TCP porta 22 com seu IP
→ Remover
```

A partir desse ponto, o único acesso à VM é via Tailscale. Mais seguro e sem exposição pública.

> Se não tiver certeza, mantenha a regra por mais alguns dias até ter total confiança no Tailscale.

### 8.3 — Commit e tag final da Fase 1

```bash
# Atualizar CHANGELOG.md com a data real de conclusão
# Editar: mudar "Em progresso" para "YYYY-MM-DD" na seção v1.0-foundation

git add .
git commit -m "feat(infra): complete phase 1 - oracle cloud foundation

- OCI: VCN, Security List, VM A1 (4 OCPU / 24 GB / Ubuntu 22.04 ARM)
- Docker CE instalado, rede Docker 'proxy' criada
- /mnt/data estruturado no boot volume (block volume adiado para Fase 5)
- Tailscale: exit node ativo, aprovado no painel admin
- Proton VPN: kill switch ON, split tunnel excluindo 100.64.0.0/10
- provision.sh: script de reprovisioning documentado
- Documentação: network-diagram, migration-log, 3 ADRs, RUNBOOK inicial
- Snapshot OCI: homelab-v1-foundation"

git tag v1.0-foundation
git push && git push --tags
```

---

## Checklist final da Fase 1

Antes de partir para a Fase 2, valide cada item:

### Repositório

- [ ] Repo existe no GitHub e está acessível
- [ ] `.gitignore` correto (teste: `git status` não mostra arquivos `.env`)
- [ ] `provision.sh` commitado e funcionando
- [ ] `docs/network-diagram.md` preenchido com IPs reais
- [ ] `docs/migration-log.md` atualizado com o que foi feito
- [ ] `CHANGELOG.md` com data real de conclusão
- [ ] Tag `v1.0-foundation` criada e pushada

### Oracle Cloud

- [ ] Pay As You Go ativado
- [ ] VCN-Homelab criada com Internet Gateway
- [ ] Security List com as 4 regras corretas
- [ ] VM A1 em estado Running (4 OCPU / 24 GB)
- [ ] IP público anotado no migration-log
- [ ] Snapshot `homelab-v1-foundation-YYYYMMDD` criado

### VM — Sistema base

- [ ] SSH funcionando via IP público (ou somente Tailscale se regra removida)
- [ ] `docker ps` funciona sem sudo
- [ ] Rede Docker `proxy` existe: `docker network ls | grep proxy`
- [ ] `/mnt/data` e subdiretórios existem: `ls /mnt/data/`
- [ ] `/srv` contém o repositório: `ls /srv/`
- [ ] UFW ativo: `sudo ufw status`

### Tailscale

- [ ] Instalado e autenticado na VM
- [ ] IP forwarding ativo: `sysctl net.ipv4.ip_forward` retorna 1
- [ ] Exit node aprovado no painel admin (login.tailscale.com)
- [ ] DNS override configurado no painel Tailscale (apontando para IP Tailscale da VM)
- [ ] SSH via IP Tailscale funcionando: `ssh ubuntu@100.xx.xx.xx`
- [ ] `tailscale status` mostra VM online

### Proton VPN

- [ ] Instalado e autenticado
- [ ] Kill switch ativo: `protonvpn-cli killswitch --list`
- [ ] Split tunnel com 100.64.0.0/10: `protonvpn-cli split-tunnel --list`
- [ ] Conectado ao servidor: `protonvpn-cli status`
- [ ] IP externo = IP Proton (não Oracle): `curl https://api.ipify.org`
- [ ] Tailscale continua funcionando com Proton ativo: `tailscale status`
- [ ] SSH via Tailscale funciona com Proton ativo

---

## Próxima fase

### Fase 2 — DNS (AdGuard Home)

Com a fundação no ar, o próximo passo é subir o AdGuard Home como servidor DNS privado. Ele vai:

- Filtrar anúncios e trackers antes de qualquer requisição sair da rede
- Ser o DNS de todos os seus dispositivos via Tailscale
- Resolver os subdomínios `*.srv.maiahub.com.br` para o IP público da Oracle

A Fase 2 é a mais simples das fases de serviço — um único container, sem banco de dados, sem dependências externas.

---

_Documento gerado para o projeto Homelab — Rafael (rmf)_
_Repositório: github.com/SEU_USUARIO/homelab_
