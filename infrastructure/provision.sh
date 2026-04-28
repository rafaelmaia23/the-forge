#!/bin/bash
# =============================================================================
# Homelab — provision.sh
# Provisionamento inicial da VM Oracle Cloud (Ubuntu 24.04 ARM)
#
# Executa UMA ÚNICA VEZ na VM recém-criada.
# Uso: sudo bash provision.sh
#
# O que este script faz:
#   0. Detecta (ou cria) o usuário de deploy
#   1. Atualiza o sistema
#   2. Instala dependências base
#   3. Instala Docker CE com rotação de logs configurada
#   4. Configura firewall ufw
#   5. Habilita IP forwarding (necessário para Tailscale exit node)
#   6. Cria swapfile de 2 GB
#   7. Configura fail2ban (proteção SSH)
#   8. Configura atualizações automáticas de segurança
#   9. Cria estrutura de diretórios e rede Docker proxy
# =============================================================================

set -euo pipefail

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓ $1${NC}"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}"; }
error()   { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $1${NC}"; exit 1; }
section() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then
    error "Execute como root: sudo bash provision.sh"
fi

# ─── Detectar usuário de deploy ───────────────────────────────────────────────
# Preferência: quem invocou sudo ($SUDO_USER).
# Fallback: ubuntu se já existir.
# Último recurso: criar o usuário ubuntu.
if [ -n "${SUDO_USER:-}" ]; then
    DEPLOY_USER="$SUDO_USER"
    log "Usuário de deploy detectado via SUDO_USER: '$DEPLOY_USER'"
elif id ubuntu &>/dev/null; then
    DEPLOY_USER="ubuntu"
    warn "SUDO_USER não definido — usando usuário 'ubuntu' existente"
else
    DEPLOY_USER="ubuntu"
    useradd -m -s /bin/bash "$DEPLOY_USER"
    usermod -aG sudo "$DEPLOY_USER"
    warn "Usuário '$DEPLOY_USER' criado. Defina uma senha depois: passwd $DEPLOY_USER"
fi
# ─────────────────────────────────────────────────────────────────────────────

section "1/9 — Atualizando sistema"
apt-get update -qq
apt-get upgrade -y
log "Sistema atualizado"

section "2/9 — Instalando dependências base"
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

section "3/9 — Instalando Docker CE"
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

usermod -aG docker "$DEPLOY_USER"

# Rotação de logs: sem isso containers podem encher o disco sem aviso
cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

systemctl enable docker
systemctl restart docker

log "Docker $(docker --version) instalado com log rotation configurada"

section "4/9 — Configurando firewall (ufw)"
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp    comment 'SSH'
ufw allow 80/tcp    comment 'HTTP - NPM redirect'
ufw allow 443/tcp   comment 'HTTPS - NPM'
ufw allow 41641/udp comment 'Tailscale WireGuard'

ufw --force enable

log "Firewall configurado"
ufw status verbose

section "5/9 — Habilitando IP forwarding (Tailscale exit node)"
# A VM precisa rotear pacotes para funcionar como exit node do Tailscale.
# Sem isso o tráfego dos dispositivos não é encaminhado pela VPS.
grep -qxF 'net.ipv4.ip_forward=1' /etc/sysctl.conf \
    || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
grep -qxF 'net.ipv6.conf.all.forwarding=1' /etc/sysctl.conf \
    || echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
sysctl -p
log "IP forwarding habilitado (IPv4 + IPv6)"

section "6/9 — Criando swapfile de 2 GB"
if [ -f /swapfile ]; then
    warn "Swapfile já existe — pulando"
else
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swapfile de 2 GB criado e ativado"
fi

section "7/9 — Configurando fail2ban (proteção SSH)"
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log "fail2ban configurado (SSH: 5 tentativas em 10 min → ban de 1h)"

section "8/9 — Configurando atualizações automáticas de segurança"
# Habilita update diário e upgrade de segurança automático
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# Arquivo separado para overrides: sem reboot automático (controlamos isso)
cat > /etc/apt/apt.conf.d/51homelab-upgrades << 'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF

log "Atualizações automáticas de segurança habilitadas (sem reboot automático)"

section "9/9 — Criando estrutura de diretórios e rede Docker"
mkdir -p /mnt/data/nextcloud/userdata
mkdir -p /mnt/data/media/{movies,tv,music}
mkdir -p /mnt/data/media/downloads/{complete,incomplete}
mkdir -p /mnt/data/backups/local
mkdir -p /mnt/data/location/imports

chown -R "$DEPLOY_USER:$DEPLOY_USER" /mnt/data

# /srv é o diretório FHS para dados de serviços hospedados.
# mkdir -p como segurança caso não exista no sistema.
mkdir -p /srv
chown "$DEPLOY_USER:$DEPLOY_USER" /srv

# Rede compartilhada por todos os serviços acessados pelo Nginx Proxy Manager.
# Deve existir antes de qualquer stack ser iniciada.
docker network create proxy 2>/dev/null || warn "Rede 'proxy' já existe — ok"

log "Estrutura de diretórios e rede Docker 'proxy' criadas"

# =============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Provisioning concluído com sucesso!${NC}"
echo -e "${GREEN}  Usuário de deploy: ${DEPLOY_USER}${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Próximos passos:"
echo "  1. Faça logout e login novamente (para o grupo docker ter efeito)"
echo "  2. Teste: docker ps (deve funcionar sem sudo)"
echo "  3. Clone o repositório: git clone <URL> /srv"
echo "  4. Instale o Tailscale: curl -fsSL https://tailscale.com/install.sh | sh"
echo "     Depois: sudo tailscale up --advertise-exit-node"
echo "  5. Instale o Proton VPN CLI (ver guia de execução - Etapa 6)"
echo ""
