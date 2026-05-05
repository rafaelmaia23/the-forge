# ADR-004 — WireGuard direto com Mullvad VPN

**Status:** Aceito
**Data:** 2026-05-04 (atualizado 2026-05-05 — troca Proton → Mullvad)

---

## Contexto

A necessidade era um provedor VPN rodando na VM via WireGuard para mascarar
o IP de saída dos dispositivos via exit node Tailscale. O Proton VPN foi a
primeira escolha por ser um provedor conhecido com suporte a WireGuard.

## Decisão

Usar WireGuard diretamente com arquivos `.conf` gerados no painel do
**Mullvad VPN** (`mullvad.net/en/account/wireguard-config`).

## Justificativa

**Por que não a CLI do Proton VPN:**
A CLI oficial não funciona em ambientes headless. Ela depende de
`gnome-keyring` e `NetworkManager` — componentes de desktop que não existem
numa VM servidor. A autenticação funciona mas `protonvpn connect` falha
silenciosamente.

**Por que não o Proton VPN via WireGuard:**
Os servidores listados pelo Proton como "BR-SP" estavam fisicamente em Miami
(AS9009 M247 Europe SRL), resultando em ~200ms de latência e 30% de packet
loss. Verificado via `curl https://ipinfo.io/<IP_SERVIDOR>`.

**Por que Mullvad:**
O Mullvad tem política explícita de não usar servidores virtuais — todos os
servidores estão fisicamente onde estão listados. Os servidores BR do Mullvad
via provider Datapacket em São Paulo apresentaram 0.5ms de latência da Oracle
SP e 0% de packet loss. Resultado prático: ~300 Mbps de throughput nos
dispositivos com exit node ativo, indistinguível de navegar sem VPN.

O Mullvad também suporta ambiente headless via CLI oficial, mas o WireGuard
direto foi mantido por ser mais controlado e compatível com o policy routing
customizado que o setup exige.

## Consequências

**Positivas:**
- Funciona em ambiente headless sem dependências de desktop
- Servidores fisicamente em São Paulo — latência mínima da Oracle SP
- Mais estável — sem camada de abstração sobre o protocolo
- Configuração versionada em arquivo de texto (com placeholders)
- Múltiplos servidores pré-configurados (BR, US, UK) para troca rápida

**Atenção:**
- Trocar de servidor requer limpeza manual de rotas órfãs antes de subir
  o próximo tunnel (`ip route del` + `ip rule del`)
- Kill switch e split tunnel implementados via `PostUp`/`PostDown` no `.conf`
- Arquivos `.conf` do Mullvad não expiram automaticamente, mas as chaves
  WireGuard podem ser rotacionadas manualmente no painel quando necessário
