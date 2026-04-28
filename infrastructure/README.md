# Infrastructure

Scripts de provisionamento e configuração da VM Oracle Cloud.

## Arquivos

| Arquivo        | Descrição                                              |
| -------------- | ------------------------------------------------------ |
| `provision.sh` | Instalação completa do zero (Docker, dirs, rede proxy) |
| `firewall.sh`  | Regras ufw — referência para a OCI Security List       |

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
