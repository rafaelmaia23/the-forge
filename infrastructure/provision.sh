#!/bin/bash
# =============================================================================
# Homelab — provision.sh
# Provisionamento inicial da VM Oracle Cloud (Ubuntu 22.04/24.04 ARM)
#
# Uso:
#   git clone https://github.com/SEU_USUARIO/homelab.git /srv
#   sudo bash /srv/infrastructure/provision.sh
#
# O script detecta automaticamente onde o repositório está clonado
# e usa essa pasta como HOMELAB_DIR. Se quiser rodar de outro lugar,
# exporte a variável antes: HOMELAB_DIR=/outro/caminho sudo -E bash provision.sh
#
# O que este script faz:
#   0. Detecta usuário de deploy e diretório do homelab
#   1. Atualiza pacotes de segurança (sem dist-upgrade)
#   2. Instala dependências base
#   3. Instala Docker CE com rotação de logs
#   4. Configura firewall ufw
#   5. Habilita IP forwarding (necessário para Tailscale exit node)
#   6. Cria swapfile de 2 GB
#   7. Configura fail2ban (proteção SSH)
#   8. Configura atualizações automáticas de segurança
#   9. Cria estrutura de diretórios e rede Docker proxy
#  10. Cria serviço tailscale-docker-forward (ADR-006) e saída direta do exit
#      node Tailscale (ADR-015)
#  11. Instala watchdogs de DNS e reconciliação de stacks no boot (ADR-014)
# =============================================================================

set -euo pipefail

# ─── Cores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓ $1${NC}"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}"; }
error()   { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $1${NC}"; exit 1; }
info()    { echo -e "${CYAN}[$(date '+%H:%M:%S')] → $1${NC}"; }
section() { echo -e "\n${YELLOW}━━━ $1 ━━━${NC}"; }

# ─── Verificações iniciais ────────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && error "Execute como root: sudo bash provision.sh"

# Ubuntu 22.04 ou 24.04
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]] || [[ "$VERSION_ID" != "22.04" && "$VERSION_ID" != "24.04" ]]; then
        warn "Sistema detectado: $PRETTY_NAME — este script foi testado no Ubuntu 22.04/24.04"
    fi
fi

# ─── 0. Detectar usuário de deploy ───────────────────────────────────────────
# Ordem de preferência:
#   1. SUDO_USER (quem invocou sudo — o mais confiável)
#   2. Variável DEPLOY_USER exportada manualmente
#   3. Usuário 'ubuntu' se já existir
#   4. Criar usuário 'ubuntu'
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    DEPLOY_USER="$SUDO_USER"
    log "Usuário de deploy: '$DEPLOY_USER' (via SUDO_USER)"
elif [ -n "${DEPLOY_USER:-}" ]; then
    log "Usuário de deploy: '$DEPLOY_USER' (via variável exportada)"
elif id ubuntu &>/dev/null; then
    DEPLOY_USER="ubuntu"
    warn "SUDO_USER não disponível — usando usuário 'ubuntu' existente"
else
    DEPLOY_USER="ubuntu"
    useradd -m -s /bin/bash "$DEPLOY_USER"
    usermod -aG sudo "$DEPLOY_USER"
    warn "Usuário '$DEPLOY_USER' criado. Defina uma senha depois com: passwd $DEPLOY_USER"
fi

DEPLOY_HOME=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)

# ─── 0. Detectar HOMELAB_DIR ──────────────────────────────────────────────────
# O script resolve seu próprio caminho real (mesmo se chamado via bash /path/to/script.sh)
# e sobe dois níveis para chegar à raiz do repositório:
#   /srv/infrastructure/provision.sh → HOMELAB_DIR=/srv
#   ~/homelab/infrastructure/provision.sh → HOMELAB_DIR=~/homelab
#
# Se HOMELAB_DIR já estiver exportado, usa o valor informado.
if [ -z "${HOMELAB_DIR:-}" ]; then
    SCRIPT_REAL_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    HOMELAB_DIR="$(dirname "$SCRIPT_REAL_PATH")"
fi

# Validar: o diretório deve conter o .git ou pelo menos o infrastructure/
if [ ! -d "$HOMELAB_DIR/infrastructure" ] && [ ! -d "$HOMELAB_DIR/.git" ]; then
    error "HOMELAB_DIR='$HOMELAB_DIR' não parece ser a raiz do repositório homelab.\n  Exporte manualmente: HOMELAB_DIR=/caminho/correto sudo -E bash provision.sh"
fi

# Dados em /mnt/data (block volume / boot volume)
# Não acoplado ao HOMELAB_DIR — dados de runtime ficam fora do repositório
DATA_DIR="/mnt/data"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Homelab — Provision${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Usuário de deploy : $DEPLOY_USER ($DEPLOY_HOME)"
info "Homelab dir       : $HOMELAB_DIR"
info "Data dir          : $DATA_DIR"
info "Sistema           : ${PRETTY_NAME:-desconhecido}"
echo ""

# ─── 1. Atualizar pacotes de segurança ───────────────────────────────────────
section "1/11 — Atualizando pacotes de segurança"
apt-get update -qq
# Apenas pacotes de segurança com upgrade normal — sem dist-upgrade
# para evitar substituição do kernel ou mudanças de versão major em produção
apt-get upgrade -y
log "Pacotes atualizados"

# ─── 2. Dependências base ─────────────────────────────────────────────────────
section "2/11 — Instalando dependências base"
apt-get install -y \
    curl \
    wget \
    git \
    vim \
    htop \
    jq \
    ca-certificates \
    gnupg \
    ufw \
    fail2ban \
    unattended-upgrades \
    apt-transport-https \
    software-properties-common
log "Dependências instaladas"

# ─── 3. Docker CE ─────────────────────────────────────────────────────────────
section "3/11 — Instalando Docker CE"

if command -v docker &>/dev/null; then
    warn "Docker já instalado ($(docker --version)) — pulando instalação"
else
    # Remover pacotes conflitantes (lista oficial Docker docs)
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        apt-get remove -y "$pkg" 2>/dev/null || true
    done

    # Repositório oficial Docker
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

    log "Docker $(docker --version) instalado"
fi

# Adicionar ao grupo docker (idempotente — usermod não falha se já for membro)
usermod -aG docker "$DEPLOY_USER"

# Rotação de logs — sem isso containers enchem o disco silenciosamente
if [ ! -f /etc/docker/daemon.json ]; then
    cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    log "Log rotation configurada"
else
    warn "daemon.json já existe — verifique manualmente se log rotation está configurada"
fi

systemctl enable docker
systemctl restart docker

# ─── 4. Firewall ──────────────────────────────────────────────────────────────
section "4/11 — Configurando firewall (ufw)"
ufw default deny incoming
ufw default allow outgoing

# ufw allow é idempotente — adiciona a regra só se não existir
ufw allow 22/tcp    comment 'SSH'
ufw allow 80/tcp    comment 'HTTP - NPM redirect'
ufw allow 443/tcp   comment 'HTTPS - NPM'
ufw allow 41641/udp comment 'Tailscale WireGuard'

ufw --force enable
log "Firewall ativo"
ufw status verbose

# ─── 5. IP Forwarding ─────────────────────────────────────────────────────────
section "5/11 — Habilitando IP forwarding (Tailscale exit node)"
# Sem isso, os pacotes dos dispositivos chegam na VM via Tailscale
# mas são descartados — a VM não os encaminha para a internet.
grep -qxF 'net.ipv4.ip_forward=1' /etc/sysctl.conf \
    || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
grep -qxF 'net.ipv6.conf.all.forwarding=1' /etc/sysctl.conf \
    || echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
sysctl -p > /dev/null
log "IP forwarding ativo (IPv4 + IPv6)"

# ─── 6. Swap ──────────────────────────────────────────────────────────────────
section "6/11 — Criando swapfile de 2 GB"
if swapon --show | grep -q /swapfile; then
    warn "Swapfile já está ativo — pulando"
elif [ -f /swapfile ]; then
    warn "Arquivo /swapfile existe mas não está ativo — ativando"
    swapon /swapfile
    grep -qF '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swapfile de 2 GB criado e ativado"
fi

# ─── 7. fail2ban ──────────────────────────────────────────────────────────────
section "7/11 — Configurando fail2ban (proteção SSH)"
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ssh
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log "fail2ban ativo (SSH: 5 tentativas em 10 min → ban de 1h)"

# ─── 8. Atualizações automáticas ──────────────────────────────────────────────
section "8/11 — Atualizações automáticas de segurança"
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/51homelab-upgrades << 'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF

log "Atualizações automáticas de segurança habilitadas (sem reboot automático)"

# ─── 9. Diretórios e rede Docker ──────────────────────────────────────────────
section "9/11 — Estrutura de diretórios e rede Docker"

# Dados de runtime — separados do repositório
mkdir -p "$DATA_DIR"/nextcloud/userdata
mkdir -p "$DATA_DIR"/media/{movies,tv,music}
mkdir -p "$DATA_DIR"/media/downloads/{complete,incomplete}
mkdir -p "$DATA_DIR"/backups/local
mkdir -p "$DATA_DIR"/location/imports
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DATA_DIR"
log "Estrutura em $DATA_DIR criada"

# Garantir que o HOMELAB_DIR pertence ao usuário de deploy
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$HOMELAB_DIR"
log "Ownership de $HOMELAB_DIR → $DEPLOY_USER"

# Rede compartilhada por todos os serviços acessados pelo Nginx Proxy Manager
#
# O --ip-range separa a faixa dinâmica da faixa de IPs fixos. Sem ele, o Docker
# aloca IPs dinâmicos a partir do início da subnet (.2, .3, ...) — exatamente os
# endereços reservados via ipv4_address no compose. Se um container dinâmico
# subir antes do adguard (172.18.0.2) ou do npm (172.18.0.3) após um reboot, ele
# ocupa o endereço e o container com IP fixo não sobe mais. Aconteceu duas vezes
# (2026-07-09 e 2026-07-28, ver migration-log).
#
#   172.18.0.2  – 172.18.127.254  → reservado para ipv4_address (fixos)
#   172.18.128.0 – 172.18.255.254 → pool dinâmico do Docker
#
# Ver docs/decisions/ADR-011-ipam-reserva-faixa-estatica.md
if docker network inspect proxy &>/dev/null; then
    warn "Rede Docker 'proxy' já existe — ok"
else
    docker network create \
        --driver bridge \
        --subnet 172.18.0.0/16 \
        --gateway 172.18.0.1 \
        --ip-range 172.18.128.0/17 \
        proxy
    log "Rede Docker 'proxy' criada (faixa dinâmica 172.18.128.0/17)"
fi

# ─── 10. Tailscale → Docker forwarding + saída direta (exit node) ───────────
section "10/11 — Tailscale → Docker forwarding + saída direta (exit node)"

# Sem esta configuração, pacotes de clientes Tailscale destinados a containers
# Docker podem ser desviados por qualquer outra regra de policy routing com
# prioridade mais alta e desaparecer. O script abaixo descobre a prioridade
# viva da regra "iif tailscale0" em tempo real (em vez de depender de um
# número fixo) e reinstala a nossa uma posição abaixo — segue funcionando
# mesmo sem nenhuma regra concorrente hoje.
# Ver docs/decisions/ADR-006-tailscale-docker-routing.md e ADR-015 (remoção
# do Mullvad, 2026-08-05).
cat > /usr/local/sbin/tailscale-docker-forward.sh << 'EOF'
#!/bin/bash
set -euo pipefail

iptables -C DOCKER-USER -i tailscale0 -j ACCEPT 2>/dev/null || \
  iptables -I DOCKER-USER -i tailscale0 -j ACCEPT

while ip rule del to 172.16.0.0/12 lookup main 2>/dev/null; do :; done

ts_prio=$(ip rule list | awk -F: '/iif tailscale0/{print $1; exit}')
our_prio=$(( ${ts_prio:-101} - 1 ))

ip rule add to 172.16.0.0/12 lookup main priority "${our_prio}"
EOF
chmod 755 /usr/local/sbin/tailscale-docker-forward.sh

cat > /etc/systemd/system/tailscale-docker-forward.service << 'EOF'
[Unit]
Description=Allow Tailscale traffic to Docker containers
After=docker.service tailscaled.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tailscale-docker-forward.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tailscale-docker-forward.service
log "tailscale-docker-forward.service criado e habilitado"

# Saída direta (sem VPN) para quando o exit node da Tailscale for ligado
# manualmente num dispositivo (ADR-015). O tailscaled não faz SNAT desse
# tráfego (--snat-subnet-routes=false, necessário para o Access List do NPM
# ver o IP real — ver ADR-007), então sem isso o tráfego do exit node sai
# com origem CGNAT (100.64.0.0/10) e é descartado no primeiro roteador.
cat > /usr/local/sbin/tailscale-exit-masquerade.sh << 'EOF'
#!/bin/bash
set -euo pipefail
IFACE=$(ip route show default | awk '/^default/ {print $5; exit}')
[ -n "${IFACE}" ] || { echo "tailscale-exit-masquerade: sem interface padrão encontrada" >&2; exit 1; }

iptables -t nat -C POSTROUTING -s 100.64.0.0/10 -o "${IFACE}" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 100.64.0.0/10 -o "${IFACE}" -j MASQUERADE
EOF
chmod 755 /usr/local/sbin/tailscale-exit-masquerade.sh

cat > /etc/systemd/system/tailscale-exit-masquerade.service << 'EOF'
[Unit]
Description=MASQUERADE de saída direta para o exit node Tailscale (opt-in, ADR-015)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tailscale-exit-masquerade.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tailscale-exit-masquerade.service
log "tailscale-exit-masquerade.service criado e habilitado"

# ─── 11. Watchdogs e reconciliação de boot ───────────────────────────────────
section "11/11 — Watchdogs (DNS, stacks no boot)"

# 2026-07: "container rodando" e "serviço systemd active" não significam
# serviço funcionando — o adguard ficou de pé com todos os upstreams mortos.
# O watchdog de DNS testa o comportamento real e age sozinho. Ver ADR-014.
# (o watchdog do túnel Mullvad existiu até 2026-08-05, ver ADR-015 e
# infrastructure/watchdog/archive-mullvad/)
install -m 0755 "$HOMELAB_DIR"/infrastructure/watchdog/homelab-dns-watchdog.sh    /usr/local/sbin/
install -m 0755 "$HOMELAB_DIR"/infrastructure/watchdog/homelab-stacks-boot.sh     /usr/local/sbin/
install -m 0644 "$HOMELAB_DIR"/infrastructure/watchdog/systemd/*.service /etc/systemd/system/
install -m 0644 "$HOMELAB_DIR"/infrastructure/watchdog/systemd/*.timer   /etc/systemd/system/

# O .env real fica fora do repositório — contém as push URLs do Uptime Kuma,
# que são tokens de acesso.
if [ ! -f /etc/homelab-watchdog.env ]; then
    install -m 0600 "$HOMELAB_DIR"/infrastructure/watchdog/homelab-watchdog.env.example \
        /etc/homelab-watchdog.env
    warn "/etc/homelab-watchdog.env criado a partir do exemplo — preencha os tokens de push"
else
    warn "/etc/homelab-watchdog.env já existe — preservado"
fi

systemctl daemon-reload
systemctl enable homelab-stacks-boot.service
systemctl enable --now homelab-dns-watchdog.timer
log "Watchdogs instalados e timers ativos"

# =============================================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Provisioning concluído!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Homelab dir : ${CYAN}$HOMELAB_DIR${NC}"
echo -e "  Data dir    : ${CYAN}$DATA_DIR${NC}"
echo -e "  Deploy user : ${CYAN}$DEPLOY_USER${NC}"
echo ""
echo "Próximos passos:"
echo "  1. Saia e entre novamente na sessão SSH (grupo docker só tem efeito após isso)"
echo "  2. Confirme: docker ps   →  deve funcionar sem sudo"
echo "  3. Instale o Tailscale: curl -fsSL https://tailscale.com/install.sh | sh"
echo "     Depois: sudo tailscale up --advertise-exit-node"
echo "     (saída direta, sem VPN — exit node é opt-in por dispositivo, ver ADR-015)"
echo ""