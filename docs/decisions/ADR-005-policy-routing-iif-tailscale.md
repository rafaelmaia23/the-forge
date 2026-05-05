# ADR-005 — Policy routing com `iif tailscale0` em vez de `from 100.64.0.0/10`

**Status:** Aceito
**Data:** 2026-05-04

---

## Contexto

Para encaminhar o tráfego dos dispositivos pelo Proton VPN, é necessário
uma regra de policy routing que identifique quais pacotes devem usar a
tabela de rotas 51820 (que tem o WireGuard como gateway padrão).

A abordagem mais intuitiva seria rotear por faixa de IP de origem:
todos os IPs do range Tailscale (`100.64.0.0/10`) usam a tabela 51820.

## Decisão

Usar `iif tailscale0` (incoming interface) como critério de roteamento,
não `from 100.64.0.0/10` (faixa de IP de origem).

```bash
# Correto
ip rule add iif tailscale0 table 51820

# Incorreto — quebra acesso SSH
ip rule add from 100.64.0.0/10 table 51820
```

## Justificativa

A VM tem IP Tailscale `{{OCI_TS_IP}}`, que está dentro do range
`100.64.0.0/10`. Com a regra `from 100.64.0.0/10`, as respostas que a
VM gera para dispositivos via Tailscale — incluindo SSH — têm esse IP
como origem e são roteadas pelo WireGuard. O Proton VPN não sabe rotear
de volta para a rede Tailscale, e o acesso quebra completamente.

O critério `iif tailscale0` é preciso: afeta apenas pacotes que **chegam
pela interface Tailscale sendo forwardados** para a internet. Pacotes que
a VM gera como resposta local (SSH, serviços) não passam por nenhuma
interface de entrada — vão direto para o OUTPUT do kernel — e nunca
batem nessa regra.

A distinção técnica:
```
Tráfego forwardado (dispositivos → internet):
  chega em tailscale0 → PREROUTING → regra iif → tabela 51820 → WireGuard

Respostas locais da VM (SSH, Nextcloud, etc.):
  nasce no OUTPUT → tabela main → enp0s6
  (nunca passa por iif, nunca vai para tabela 51820)
```

Esta distinção foi descoberta empiricamente — três tentativas com
abordagens diferentes quebraram o acesso antes de chegar nesta solução.

## Consequências

**Positivas:**
- Tráfego dos dispositivos sai pelo Proton VPN corretamente
- Acesso SSH e serviços locais continuam funcionando sem interferência
- Regra simples e direta no `.conf` WireGuard via `PostUp`

**Atenção:**
- Tráfego que **nasce na VM** (AdGuard consultando DNS, torrents, apt)
  não é coberto por esta regra — sai pelo IP da Oracle
- Cobertura do tráfego originado na VM está planejada para após a Fase 4
  via `fwmark` no OUTPUT do iptables
  (ver `docs/decisions/CONTEXT_roteamento-seletivo-vm-fase4.md`)
