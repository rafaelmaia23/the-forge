# ADR-014 — Watchdogs funcionais e failover de saída

**Status:** Aceito
**Data:** 2026-07-28

---

## Contexto

Julho de 2026 teve três falhas com a mesma assinatura: **"container rodando" e
"unit systemd active" não significam serviço funcionando**, e nenhuma das
camadas de supervisão existentes percebeu.

| Falha | O que o supervisor via | O que estava acontecendo |
| --- | --- | --- |
| AdGuard, 2026-07-28 00:45 | container `Up`, `restart: unless-stopped` satisfeito | todos os upstreams DoH em timeout — nenhuma query resolvia |
| Túnel Mullvad, 2026-07-28 | `systemctl is-active` = `active` | interface no ar **sem nenhum peer** — `wg-mull-br.conf` havia perdido o bloco `[Peer]` |
| AdGuard, 2026-07-09 e 2026-07-28 | container `exited`, sem retry | conflito de IP no boot (ADR-011); ficou parado até intervenção manual |

O caso do túnel é o mais ilustrativo. O `[Peer]` foi removido por acidente numa
edição em 2026-07-17 (o backup de 17:32 tem o bloco; o arquivo vivo, de 17:36,
não). O `wg-quick` só lê o `.conf` no `up`, então a interface seguiu **11 dias**
funcionando com o peer carregado no kernel. O reboot de 2026-07-28 15:03 foi a
primeira vez que o arquivo quebrado foi relido — e a partir dali a tabela 51820
apontava `default dev wg-mull-br` para um túnel sem peer: **buraco negro** para
todo o tráfego de exit node. Os dispositivos ficaram sem internet; a VPS
continuou perfeitamente saudável por qualquer métrica.

Nenhum alerta foi emitido em nenhum dos três casos — e o Uptime Kuma, mesmo
quando detectava, não conseguia entregar a notificação (ADR-012).

## Decisão

Três unidades systemd que verificam **comportamento**, não estado, e agem
sozinhas.

### 1. `homelab-dns-watchdog` (timer, 60s)

Resolve uma query real contra o AdGuard (`dig @172.18.0.2`). Duas falhas
seguidas → `docker compose up -d` na stack `dns`. Bate heartbeat no Uptime Kuma
apenas quando a query responde.

### 2. `homelab-vpn-watchdog` (timer, 60s)

Saúde do túnel = idade do último handshake **e** saída real pela interface
(`curl --interface wg-mull-br`). O handshake sozinho não bastaria: a interface
existe sem peer no cenário de 2026-07-28.

Em dois estágios:

1. **Túnel morto** → `systemctl restart wg-quick@wg-mull-br`
2. **Continuou morto** → *failover*: aponta o `default` da tabela 51820 para o
   gateway direto e adiciona MASQUERADE na interface física. Os dispositivos
   voltam a navegar **sem** o Mullvad — degradado, mas funcionando, e avisado.
3. **Túnel voltou** → desfaz o failover sozinho.

Enquanto degradado, tenta reerguer o túnel a cada 5 ciclos.

### 3. `homelab-stacks-boot` (oneshot, após `docker.service`)

Roda `docker compose up -d` em todas as stacks do repositório uma vez após o
boot. Idempotente: reconcilia o que ficou para trás sem tocar no que já subiu.

Complementarmente, `Restart=on-failure` + `RestartSec=15` no drop-in do
`wg-quick@wg-mull-br` — antes, uma falha no boot deixava a unit em `failed`
para sempre.

## Justificativa

**Por que testar comportamento e não estado:**
É a lição das três falhas. `docker ps` e `systemctl is-active` respondem "o
processo existe", que não é a pergunta que importa. Uma query DNS que resolve e
um `curl` que sai pelo túnel respondem a pergunta certa.

**Por que failover em vez de só alertar:**
O usuário explicitou o requisito: *"se um serviço cair, quero que tenha um
fallback, mesmo que não seja privado ou seguro, mas que mantenha funcionando"*.
Perder a privacidade do Mullvad por alguns minutos é incomparavelmente melhor do
que ficar sem internet em todos os aparelhos sem saber por quê.

**Por que heartbeat só no sucesso (push monitor):**
Um monitor que depende do watchdog *reportar* a falha morre junto com o host. Com
push, o silêncio é o alerta: se o watchdog não roda, ou o servidor caiu, ou o
timer morreu — os dois merecem aviso.

**Por que o watchdog remove a rota de failover antes de reiniciar o túnel:**
Descoberto em ensaio, e é a parte menos óbvia deste ADR. O `PostUp` do
`wg-mull-br.conf` instalava o `default` da tabela 51820 com `ip route add`. Com
a rota de failover ocupando o mesmo `default`, o `wg-quick` abortava com
`RTNETLINK answers: File exists` e **apagava a interface que acabara de criar**.
Ou seja: a rede de segurança impedia a recuperação, prendendo o sistema no estado
degradado que ela deveria tornar temporário. Corrigido nos dois lados — o
`.conf` passou a usar `ip route replace`, e o watchdog remove a rota antes de
tentar (e a reinstala se o restart falhar, para não deixar os dispositivos sem
rota alguma no intervalo).

## Consequências

**Positivas:**
- Ciclo completo validado em ensaio: túnel morto e `.conf` removido → degradado
  para o gateway direto no ciclo 2 → `.conf` restaurado → túnel de volta e
  failover desfeito no ciclo 5, com saída confirmada em `br-sao-wg-201`
- Entrega de alerta validada com o AdGuard parado (ADR-012)
- Reboot deixou de exigir supervisão humana

**Atenção:**
- **O `/etc/wireguard/wg-mull-br.conf` vive fora do repositório.** As três
  correções de idempotência aplicadas nele (`ip route replace`, `iptables -C`
  antes de `-A` no MASQUERADE e no TCPMSS) **não estão versionadas**. Um `.conf`
  novo colado do painel do Mullvad vem sem elas e reintroduz os bugs. O
  watchdog foi escrito para tolerar isso, mas o RUNBOOK deve ser seguido ao
  rotacionar chaves.
- **Nunca editar um `.conf` do WireGuard sem `wg-quick down` antes.** O erro
  fica latente até o próximo boot — no caso do `[Peer]`, foram 11 dias entre a
  causa e o sintoma, sem nenhuma correlação aparente.
- Em modo degradado o tráfego dos dispositivos sai pelo IP da Oracle, sem
  Mullvad. É intencional, mas deve ser tratado como incidente, não como estado
  aceitável.
- As push URLs em `/etc/homelab-watchdog.env` são tokens de acesso ao Uptime
  Kuma. O arquivo é `0600` e fica fora do repositório; só o `.example` é
  versionado.

## Artefatos

| Onde | O quê |
| --- | --- |
| `infrastructure/watchdog/*.sh` | os três scripts |
| `infrastructure/watchdog/systemd/` | units e timers |
| `infrastructure/watchdog/homelab-watchdog.env.example` | template da config |
| `infrastructure/provision.sh` (seção 11) | instalação e habilitação |
| `/etc/homelab-watchdog.env` | VM — fora do repositório (tokens) |
| `/etc/systemd/system/wg-quick@wg-mull-br.service.d/override.conf` | VM — `Restart=on-failure` |

---

## Atualização — 2026-07-29: teste do caminho de saída

O watchdog do túnel verificava a saúde do **túnel**, não do **caminho**. Em
2026-07-29 as duas `ip rule` de policy routing foram varridas por uma renovação
de lease DHCP (ver ADR-006, atualização de 2026-07-29). O túnel seguiu
impecável — handshake fresco, `mullvad_exit_ip: true` — e mesmo assim o tráfego
dos dispositivos saía pela interface física com origem CGNAT e morria em
silêncio. O watchdog reportava saúde o tempo todo, corretamente: o túnel estava
mesmo saudável.

Adicionado `exit_path_healthy()`:

```bash
ip route get 1.1.1.1 from 100.64.0.1 iif tailscale0
# saudável se responder "dev wg-mull-br"
```

E `repair_exit_path()`, que reinstala as duas regras sem tocar no túnel, e loga
as últimas linhas do journal do `tailscaled` — foi essa instrumentação que
identificou o culpado na primeira ocorrência.

Validado apagando as duas regras à mão: rota caiu para `via 10.0.0.1 dev
enp0s6`, o watchdog detectou, reinstalou, e a rota voltou para `dev wg-mull-br
table 51820`.

**Lição, terceira vez no mesmo dia:** "o túnel está saudável" e "os dispositivos
têm internet" são perguntas diferentes. Cada camada precisa do seu próprio teste
de resultado, e o teste tem que ser feito na ponta que importa.
