# The Forge - A Personal Homelab

Infraestrutura de auto-hospedagem rodando na Oracle Cloud (ARM A1).

## Stack de serviços

| Serviço             | URL                           | Acesso    |
| ------------------- | ----------------------------- | --------- |
| Nextcloud           | cloud.srv.maiahub.com.br      | Público   |
| Jellyfin            | jellyfin.srv.maiahub.com.br   | Público   |
| Nginx Proxy Manager | npm.srv.maiahub.com.br        | Tailscale |
| Portainer           | portainer.srv.maiahub.com.br  | Tailscale |
| AdGuard Home        | adguard.srv.maiahub.com.br    | Tailscale |
| Uptime Kuma         | monitoring.srv.maiahub.com.br | Tailscale |
| Netdata             | netdata.srv.maiahub.com.br    | Tailscale |
| Dawarich            | dawarich.srv.maiahub.com.br   | Tailscale |

## Infraestrutura

- **Provider:** Oracle Cloud (ARM A1)
- **Shape:** VM.Standard.A1.Flex — 4 OCPU / 24 GB RAM
- **OS:** Ubuntu 24.04 LTS
- **Rede privada:** Tailscale (exit node + DNS)
- **VPN de saída:** Proton VPN (kill switch + split tunnel)

## Documentação

| Documento                                   | Descrição                                 |
| ------------------------------------------- | ----------------------------------------- |
| [Overview](docs/overview.md)                | Arquitetura completa, serviços, decisões  |
| [Runbook](RUNBOOK.md)                       | Operações do dia a dia                    |
| [Guias de execução](docs/phases/)           | Passo a passo de cada fase                |
| [ADRs](docs/decisions/)                     | Registro de decisões arquiteturais        |
| [Migration log](docs/migration-log.md)      | Diário da migração Hostinger → Oracle     |
| [Changelog](CHANGELOG.md)                   | Histórico de mudanças na infra            |
| [Diagrama de rede](docs/network-diagram.md) | Topologia, fluxo de tráfego, redes Docker |

## Repositório

[The Forge](https://github.com/rafaelmaia23/the-forge)

## Como replicar do zero

1. Configurar conta OCI
2. Executar `infrastructure/provision.sh` em VM Ubuntu 24.04 ARM
3. Seguir os READMEs de cada serviço em `services/`
4. Ver `RUNBOOK.md` para operações do dia a dia
