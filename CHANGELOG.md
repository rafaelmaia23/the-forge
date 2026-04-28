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
