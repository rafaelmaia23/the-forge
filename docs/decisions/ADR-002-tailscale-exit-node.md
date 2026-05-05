# ADR-002 — Tailscale como rede privada e exit node

**Status:** Aceito
**Data:** 2026-05-04

---

## Contexto

Necessidade de acesso privado e seguro aos serviços da VM a partir de
múltiplos dispositivos, incluindo Android. O Android permite apenas uma
VPN ativa por vez — o que cria um conflito: ou usa Tailscale para acessar
serviços privados, ou usa Proton VPN para mascarar o IP de saída na internet.

Usar Proton VPN nos dispositivos e abrir os serviços publicamente na internet
foi descartado por aumentar a superfície de ataque sem necessidade.

## Decisão

Tailscale como camada de rede privada da VM, configurado como exit node.
Proton VPN rodando **na VM** (não nos dispositivos) via WireGuard, com
policy routing para encaminhar apenas o tráfego forwardado pelo Tailscale.

O resultado: o Android usa o Tailscale como única VPN — tendo simultaneamente
acesso aos serviços privados da VM E mascaramento de IP via exit node.

```
Dispositivos → [Tailscale] → VM → [WireGuard/Proton] → Internet
                              ↓
                        serviços locais
                    (resolve direto, não sai)
```

## Justificativa

Alternativas consideradas:

**Proton VPN nos dispositivos + serviços públicos:** aumenta superfície de
ataque, exige certificados e autenticação robusta para cada serviço exposto,
não resolve o conflito do Android.

**WireGuard próprio como VPN de acesso:** mais complexo de manter, sem a
camada de gerenciamento de dispositivos que o Tailscale oferece (MFA,
aprovação, revogação).

**Sem VPN de saída:** expõe o IP da Oracle como origem de todo o tráfego
dos dispositivos — contra o objetivo de privacidade.

## Consequências

**Positivas:**
- Android usa uma única VPN (Tailscale) e tem acesso a serviços E privacidade
- Painéis de controle (Portainer, AdGuard, NPM) nunca ficam expostos
  publicamente — acessíveis apenas via Tailscale
- Tailscale SSH pode substituir regra de firewall SSH por IP fixo
- MFA e aprovação de dispositivos gerenciados no painel Tailscale

**Atenção:**
- Dependência de serviço externo (coordination server Tailscale) para
  novos dispositivos — sem internet, novos devices não entram na rede
- O IP Tailscale da VM muda se a instância for recriada — atualizar
  qualquer DNS Rewrite configurado no AdGuard
- DNS override do Tailscale deve ser desativado até o AdGuard estar no ar
  (Fase 2), para não quebrar resolução DNS nos dispositivos
