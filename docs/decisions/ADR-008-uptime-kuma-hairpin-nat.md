# ADR-008 — Uptime Kuma monitora serviços via endereçamento Docker interno

**Status:** Aceito
**Data:** 2026-05-18

---

## Contexto

O Uptime Kuma roda como container Docker na rede `proxy`. O objetivo era configurar
monitors HTTP(s) usando os domínios públicos dos serviços (`https://npm.maiahub.com.br`,
`https://adguard.maiahub.com.br`, etc.) para testar o stack completo: DNS → NPM → container.

Durante a Fase 4, todos esses monitors falharam com `ENOTFOUND` ou `ETIMEOUT`, mesmo
com os serviços respondendo normalmente via browser.

**Causa raiz: hairpin NAT do Docker**

As regras de DNAT geradas pelo Docker para portas publicadas incluem `! -i <bridge>`:

```
-A DOCKER ! -i br-proxy -p tcp --dport 443 -j DNAT --to-destination npm_ip:443
-A DOCKER ! -i br-proxy -p udp --dport 53  -j DNAT --to-destination adguard_ip:53
```

O `! -i br-proxy` significa que o DNAT **não dispara** para tráfego que sai pela mesma
bridge de onde o pacote originou. Qualquer container na rede `proxy` que tente atingir
outro container via o IP externo do host (IP Tailscale, IP público ou gateway da bridge)
tem seu pacote roteado para fora sem DNAT — e desaparece.

**Cadeia de falha para monitor HTTP(s) via domínio:**

1. Uptime Kuma precisa resolver `npm.maiahub.com.br`
2. Consulta AdGuard em `{{OCI_TS_IP}}:53`
3. Pacote sai via `br-proxy`, DNAT não dispara (`! -i br-proxy`)
4. Pacote vai para `tailscale0`, desaparece → `ETIMEOUT`
5. Sem DNS, não consegue fazer a requisição HTTP → `ENOTFOUND`

O mesmo problema afeta qualquer variação do endereço do host:
- `{{OCI_TS_IP}}` → vai para `tailscale0`, sem DNAT
- Gateway da bridge (`172.18.0.1`) → sai via `br-proxy`, `! -i br-proxy` bloqueia DNAT

Tráfego vindo de fora (dispositivos Tailscale, internet) não tem esse problema porque
chega por `tailscale0` ou `enp0s6`, não pela `br-proxy`.

## Decisão

O Uptime Kuma monitora todos os serviços via endereçamento Docker direto:

**Monitors HTTP(s) — container name na mesma rede:**

```
http://npm:81           ← NPM admin
http://adguard:3000     ← AdGuard admin
http://portainer:9000   ← Portainer
http://netdata:19999    ← Netdata
http://uptime-kuma:3001 ← Uptime Kuma (self)
```

Container names são resolvidos pelo DNS embutido do Docker (127.0.0.11) dentro
da mesma rede bridge — sem DNAT, sem DNS externo.

**Monitor DNS (AdGuard) — IP do container, não IP do host:**

```
Resolver Server: <IP do container adguard na rede proxy>
```

Obtido via:
```bash
docker inspect adguard --format '{{.NetworkSettings.Networks.proxy.IPAddress}}'
```

Dentro da mesma bridge, o pacote vai diretamente ao container — sem DNAT, sem problema.

**Monitors TCP para portas públicas:**

```
TCP Port {{OCI_PUBLIC_IP}}:80   ← verifica que NPM aceita conexões HTTP
TCP Port {{OCI_PUBLIC_IP}}:443  ← verifica que NPM aceita conexões HTTPS
```

Estes monitoram disponibilidade externa real. Não sofrem o problema de hairpin NAT
porque o Uptime Kuma conecta via IP público, que não tem a restrição `! -i br-proxy`.

## Justificativa

**Por container name em vez de domínio:**

O domínio (`https://npm.maiahub.com.br`) testa o stack completo (DNS → NPM → container),
mas requer que o container resolva DNS — o que é impossível sem hairpin NAT funcional.
O container name (`http://npm:81`) testa diretamente se o processo NPM está vivo e
respondendo. Para um homelab pessoal, isso é suficiente — se o NPM cair, os TCP monitors
na porta 443 detectam a indisponibilidade externa, e o monitor interno detecta que o
container parou de responder.

**Por IP do container no monitor DNS em vez de IP do host:**

O monitor DNS do Uptime Kuma envia a query UDP diretamente para o Resolver Server.
Usar o IP do container do AdGuard (não o IP Tailscale) mantém o tráfego dentro da
bridge — sem DNAT, sem a restrição `! -i br-proxy`.

**Por não alterar regras iptables:**

Seria possível adicionar uma regra `iptables -I DOCKER-USER -i br-proxy -o br-proxy -j ACCEPT`
para permitir hairpin NAT. Isso foi descartado porque:
- Contornaria uma proteção intencional do Docker (isolamento entre redes)
- Precisaria de persistência (adicionar ao systemd service `tailscale-docker-forward.service`)
- A abordagem via container name é mais simples e igualmente eficaz

## Consequências

**Como adicionar um novo serviço ao monitoramento:**

Ao subir um novo serviço na rede `proxy`, adicionar no Uptime Kuma:

```
Monitor Type: HTTP(s)
URL: http://<container_name>:<porta_interna>
```

O monitor vai direto ao container sem depender de DNS ou NPM. Ver RUNBOOK.md
para o procedimento completo.

**IP fixo do container AdGuard:**

O IP do container `adguard` foi fixado em `172.18.0.2` via `ipv4_address` no
`services/dns/compose.yaml`. Isso garante que o campo `Resolver Server` no monitor
DNS do Uptime Kuma (`172.18.0.2`) permanece válido mesmo após recriar o container.

Para verificar:

```bash
docker inspect adguard --format '{{.NetworkSettings.Networks.proxy.IPAddress}}'
# Deve sempre retornar 172.18.0.2
```

**Limitação — SSL não é testado:**

Os monitors internos via `http://` não verificam a validade dos certificados SSL.
Os TCP monitors na porta 443 verificam que a porta está aberta mas não o certificado.
Para este homelab, isso é aceitável — os certificados são gerenciados pelo NPM com
renovação automática via Let's Encrypt.

## Artefatos

| Decisão | Onde |
| --- | --- |
| Monitors via container name | Uptime Kuma UI (configuração fora do repo) |
| IP do AdGuard no monitor DNS | Uptime Kuma UI — atualizar se container for recriado |
| Nenhuma alteração em iptables | — |
