# ADR-012 — O monitoramento não pode depender do que ele monitora

**Status:** Aceito
**Data:** 2026-07-28

---

## Contexto

O AdGuard é o DNS de todo o homelab. Três componentes apontavam para ele — e
todos os três param de funcionar quando ele cai, cada um agravando o problema:

**1. O host (VPS)**
O `/etc/resolv.conf` da VPS apontava para `100.100.100.100` (MagicDNS do
Tailscale), que encaminha para o AdGuard, que é um container **rodando na
própria VPS**. Com o AdGuard fora, o servidor perdia resolução de nomes:
`apt`, `docker pull`, o CLI do Claude — nada resolvia. A VPS tinha internet
(`curl https://1.1.1.1` respondia na hora) e parecia offline.

**2. O Uptime Kuma**
Tinha `dns: [172.18.0.2]` — apenas o AdGuard. Com o AdGuard fora, ele
*detectava* a queda mas não conseguia resolver o endpoint do canal de
notificação (`api.telegram.org`), e a entrega falhava em silêncio. O sintoma
relatado pelo usuário foi exatamente esse: *"quando cai o DNS ele não notifica
direito"*. O monitor funcionava; o alerta é que não saía — precisamente quando
mais importava.

**3. Os dispositivos**
Recebem o AdGuard como DNS via Tailscale. Com ele fora, ficam sem internet —
não por falta de conectividade, mas por falta de resolução.

Em 2026-07-28 os três aconteceram ao mesmo tempo. O usuário perdeu internet em
todos os aparelhos, não conseguiu diagnosticar pelo servidor (que estava sem
DNS) e não recebeu nenhum alerta (que não conseguia sair).

## Decisão

Quebrar a dependência circular em cada camada, **sem** tocar no DNS dos
dispositivos — onde o AdGuard continua sendo o único resolvedor, para preservar
o bloqueio de anúncios.

**Host:** `/etc/resolv.conf` estático, apontando para o resolvedor da Oracle com
fallback público, e `tailscale set --accept-dns=false` na VPS:

```
nameserver 169.254.169.254
nameserver 9.9.9.9
search vcnhomelab.oraclevcn.com
```

**Uptime Kuma:** fallback público no `dns:` do compose:

```yaml
dns:
  - 172.18.0.2   # AdGuard — resolve os domínios internos
  - 9.9.9.9      # fallback — garante que o alerta consiga sair
```

**Dispositivos:** inalterados. Apenas o AdGuard.

## Justificativa

**Por que não colocar um segundo DNS também nos dispositivos:**
Foi a primeira proposta e o usuário a recusou, com razão. Com dois resolvedores
globais no Tailscale, parte das queries iria para o público mesmo com o AdGuard
vivo — e o bloqueio de anúncios deixaria de ser confiável. O ganho de
resiliência não compensava, porque o problema real não era "o AdGuard é um
ponto único de falha" e sim "**o AdGuard não conseguia subir depois de um
reboot**" (ADR-011) e "**ninguém era avisado**" (este ADR + ADR-014).

**Por que o fallback no Uptime Kuma não tem esse custo:**
O Uptime Kuma não navega. Ele resolve endpoints de monitoramento e de
notificação. Não há anúncio para bloquear no caminho, então o fallback é ganho
puro.

**Por que `resolv.conf` estático no host em vez do stub do systemd-resolved:**
O `/etc/resolv.conf` estava em modo `foreign` (escrito pelo tailscaled), e nesse
modo o systemd-resolved **lê o próprio arquivo** como fonte dos servidores
globais — um ciclo que se realimentava e mantinha o `100.100.100.100` morto na
lista mesmo após reiniciar o serviço. O `stub-resolv.conf` também estava
adulterado (symlink para o `resolv.conf`, não um arquivo com `127.0.0.53`). Como
a VPS reinicia sozinha por `unattended-upgrade`, optou-se pela configuração com
menos peças móveis e sem dependência de arquivos voláteis em `/run`.

## Consequências

**Positivas:**
- Uma queda do AdGuard deixou de derrubar o diagnóstico junto com o serviço: a
  VPS continua resolvendo, e o alerta continua saindo
- O bloqueio de anúncios nos dispositivos ficou intacto
- Validado ao vivo em 2026-07-28: com o `adguard` parado, o `uptime-kuma`
  resolveu `api.telegram.org` pelo fallback e o alerta foi entregue

**Atenção:**
- O host deixou de resolver os domínios internos (`*.maiahub.com.br`
  tailscale-only). Procedimentos no RUNBOOK devem usar `dig @172.18.0.2`
  explicitamente em vez de depender da resolução do host.
- O `/etc/resolv.conf` estático pode ser sobrescrito se alguém reativar
  `--accept-dns=true` **na VPS** (não confundir com os dispositivos, onde ele
  deve permanecer ligado).
- Os dispositivos continuam com DNS único. A válvula de escape manual, para
  quando o AdGuard cair e o watchdog não resolver, é
  `tailscale set --accept-dns=false` no dispositivo — documentado no RUNBOOK
  como primeiro socorro.
