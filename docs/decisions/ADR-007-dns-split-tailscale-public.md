# ADR-007 — DNS split: serviços tailscale-only resolvem para IP Tailscale, serviços públicos para IP público

**Status:** Aceito
**Data:** 2026-05-11

---

## Contexto

O plano original previa um único DNS Rewrite wildcard para todos os serviços:
`*.maiahub.com.br → {{OCI_PUBLIC_IP}}`. Isso simplificaria a configuração do AdGuard,
mas criou um problema durante a execução da Fase 3.

Ao tentar acessar `https://npm.maiahub.com.br` com o Tailscale conectado mas **sem
o exit node ativo**, o acesso resultava em 403 Forbidden. O motivo: o DNS resolvia para
o IP público da Oracle, a requisição saía pela internet normal com o IP real do
dispositivo, e a Access List "tailscale-only" (`100.64.0.0/10`) bloqueava corretamente.

O NPM nunca via o IP Tailscale do cliente — só via o IP de internet.

## Decisão

DNS Rewrites no AdGuard divididos por nível de acesso:

- **Serviços tailscale-only** → DNS resolve para `{{OCI_TS_IP}}` (IP Tailscale da VPS)
- **Serviços públicos** (Nextcloud, Jellyfin) → DNS resolve para `{{OCI_PUBLIC_IP}}`

Cada serviço tem seu próprio DNS Rewrite individual no AdGuard — sem wildcards.

```text
# Tailscale-only (resolvem para o IP Tailscale)
npm.maiahub.com.br       → {{OCI_TS_IP}}
adguard.maiahub.com.br   → {{OCI_TS_IP}}
portainer.maiahub.com.br → {{OCI_TS_IP}}
monitoring.maiahub.com.br → {{OCI_TS_IP}}
netdata.maiahub.com.br   → {{OCI_TS_IP}}
dawarich.maiahub.com.br  → {{OCI_TS_IP}}

# Públicos (resolvem para o IP público)
cloud.maiahub.com.br     → {{OCI_PUBLIC_IP}}
jellyfin.maiahub.com.br  → {{OCI_PUBLIC_IP}}
```

## Justificativa

Quando um dispositivo na rede Tailscale resolve `npm.maiahub.com.br` para o IP Tailscale
da VPS, a conexão flui inteiramente dentro da rede Tailscale:

```
Dispositivo (100.x.x.x) → [Tailscale] → VPS ({{OCI_TS_IP}}:443)
                                              ↓
                                         NPM vê source = 100.x.x.x
                                         Access List: 100.64.0.0/10 → ALLOW ✓
```

Isso funciona sem exit node ativo no dispositivo — a rede Tailscale roteia diretamente
entre os nós. O tráfego de serviços privados não passa pelo Mullvad desnecessariamente.

Para serviços públicos, o IP público é necessário porque usuários externos (sem Tailscale)
precisam acessar diretamente. Esses serviços não têm Access List no NPM.

**Alternativas descartadas:**

- **Wildcard para IP público + exigir exit node:** funcionaria, mas obriga o exit node
  estar sempre ativo para qualquer acesso interno — ineficiente e frágil.
- **Wildcard para IP Tailscale:** serviços públicos ficariam inacessíveis para usuários
  externos, pois o DNS retornaria um IP inacessível fora do Tailscale.

## Consequências

**Positivas:**
- Acesso a serviços internos funciona sem exit node ativo
- Tráfego interno não passa pelo Mullvad — menor latência, menor uso de banda VPN
- Mais correto arquiteturalmente: o DNS reflete a intenção de acesso de cada serviço

**Atenção:**
- Ao trocar o IP da VPS, atualizar **todos** os DNS Rewrites no AdGuard
- Ao trocar o IP Tailscale da VPS (ex: recriar a instância), atualizar os rewrites tailscale-only
- Serviços públicos precisam ter registro DNS no Cloudflare (DNS público) apontando para
  `{{OCI_PUBLIC_IP}}` — o AdGuard só serve clientes Tailscale
- Cada novo serviço adicionado deve ter seu DNS Rewrite categorizado conscientemente
  como tailscale-only ou público ao ser criado
