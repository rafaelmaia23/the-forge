# ADR-006 — Roteamento Tailscale → Docker: ip rule para tabela main

**Status:** Aceito
**Data:** 2026-05-06

---

## Contexto

Ao subir o primeiro serviço Docker (AdGuard Home, Fase 2), o painel na porta 3000
ficou inacessível para clientes externos via Tailscale, mesmo com o container
rodando corretamente e respondendo localmente.

O diagnóstico revelou uma interação entre dois mecanismos que funcionam
corretamente de forma isolada mas colidem quando combinados:

1. **DNAT do Docker** — redireciona tráfego de `{{OCI_TS_IP}}:3000` para `172.18.0.2:3000`
   (IP interno do container na rede `proxy`)

2. **Policy routing do Mullvad** — regra `iif tailscale0 lookup 51820` (prioridade 5209)
   direciona todo tráfego que chega pelo Tailscale para a tabela de rotas 51820

O problema: após o DNAT alterar o destino para `172.18.0.2`, a decisão de
roteamento usa a tabela 51820 (porque o pacote veio pelo `tailscale0`). Essa
tabela contém apenas:

```
default dev wg-mull-br scope link
100.64.0.0/10 dev tailscale0 scope link
```

Não há rota para `172.18.0.0/16` (nem para nenhuma rede Docker). O kernel usa o
`default` — o gateway Mullvad — e o pacote vai para o servidor VPN e desaparece.

O tráfego *local* da VM (curl do próprio host) funcionava porque o kernel usa a
tabela `local` + `main` para tráfego originado localmente, não a tabela 51820.

## Decisão

Adicionar uma ip rule com prioridade inferior a 5209 que redireciona tráfego
destinado a redes Docker para a tabela `main`:

```bash
ip rule add to 172.16.0.0/12 lookup main priority 5200
```

A regra `172.16.0.0/12` cobre todo o pool de endereços que o Docker usa por
padrão para suas redes internas (`172.16.x.x` a `172.31.x.x`), sem precisar
saber o nome ou subnet de cada bridge.

Complementarmente, a chain `DOCKER-USER` precisa de uma regra ACCEPT para
`tailscale0`, pois a política padrão do FORWARD é DROP:

```bash
iptables -I DOCKER-USER -i tailscale0 -j ACCEPT
```

Ambas são persistidas via systemd service `tailscale-docker-forward.service`,
que depende do `docker.service` e `tailscaled.service`.

## Justificativa

**Por `priority 5200` e não outro valor:**
A regra `iif tailscale0 lookup 51820` está em prioridade 5209. Qualquer valor
menor que 5209 funciona. O valor 5200 foi escolhido por ser próximo o suficiente
para indicar relacionamento (mesma centena), sem conflitar com as demais regras
do sistema (5210, 5230, 5250, 5270 — todas do Tailscale).

**Por `172.16.0.0/12` e não rotas específicas:**
Adicionar rotas por bridge específica (`172.18.0.0/16 dev <nome-da-bridge>`)
exigiria atualização manual a cada nova rede Docker criada (nextcloud_internal,
media_internal, etc.) e dependeria do nome da bridge — que é gerado a partir do
ID da rede e pode mudar se a rede for recriada. O range `172.16.0.0/12` é
mais amplo que o necessário mas cobre todos os casos sem manutenção.

**Por DOCKER-USER e não uma chain UFW:**
O Docker insere `DOCKER-USER` antes de todas as suas chains no FORWARD. É o
ponto oficial recomendado pela documentação Docker para regras de usuário que
devem ter precedência sobre as regras automáticas do Docker.

## Consequências

**Positivas:**
- Qualquer serviço futuro em rede Docker é acessível via Tailscale automaticamente
- Não há dependência de nomes de bridge ou subnets específicas
- A regra é idempotente (o service usa `-C` para verificar antes de inserir)

**Atenção:**
- A regra `to 172.16.0.0/12 lookup main` tem prioridade sobre a tabela 51820
  para destinos Docker. Isso é correto — tráfego aos containers não deve sair
  pelo Mullvad.
- Se o Docker for configurado para usar um pool diferente de `172.16.0.0/12`,
  será necessário adicionar outra ip rule para o novo range.

## Artefatos criados

| Arquivo | Onde |
| --- | --- |
| `/etc/systemd/system/tailscale-docker-forward.service` | VM — fora do repositório |
| `/usr/local/sbin/tailscale-docker-forward.sh` | VM — fora do repositório (script do `ExecStart`, ver atualização 2026-07-17) |
| `/etc/wireguard/wg-mull-br.conf` (`priority 20000` fixa na regra `iif tailscale0`) | VM — fora do repositório (ver atualização 2026-07-17) |
| UFW rule: `route allow in on tailscale0` | VM — persistido pelo UFW |
| UFW rule: `allow from 100.64.0.0/10 to any port 3000` | VM — temporário (remover na Fase 3) |

> O `tailscale-docker-forward.service` deve ser criado pelo `provision.sh` para
> que uma reinstalação do zero já contenha essa configuração.

---

## Atualização — 2026-07-16: prioridade 5200 deixou de ser suficiente

**Contexto:** Em 2026-07-16, todos os painéis internos (`*.maiahub.com.br`
tailscale-only) ficaram inacessíveis a partir de **todos** os dispositivos
Tailscale, mesmo com AdGuard, DNAT do Docker, firewall e túnel Mullvad
auditados e saudáveis individualmente. Uma captura de pacotes (`tcpdump -i any
port 53`) revelou a causa: pacotes chegando por `tailscale0` e destinados ao
AdGuard (`172.18.0.2:53`) estavam sendo desviados para fora pela interface
`wg-mull-br` — com o IP de origem mascarado para `10.69.63.119` (endereço
interno do túnel Mullvad) — antes de chegar ao container.

**Causa raiz:** a regra interna do próprio Tailscale (`iif tailscale0 lookup
51820`) não está mais na prioridade **5209** documentada acima — nesta versão
do `tailscaled` (1.98.8) ela está em `172.16.0.0/12 lookup main`, priority
**5199**. Como `ip rule` avalia números de prioridade em ordem crescente
(menor primeiro), a regra do Tailscale (5199) passou a ser avaliada **antes**
da nossa (5200). Como a tabela 51820 tem uma rota `default dev wg-mull-br`
(catch-all), qualquer pacote vindo de `tailscale0` — incluindo os já
DNATados para `172.18.0.2` — encontra essa rota default na regra 5199 e para
aí; a regra 5200 nunca chega a ser avaliada. Todo tráfego Tailscale→Docker
passou a ser desviado pelo túnel Mullvad, sofrendo MASQUERADE (todos os
clientes Tailscale passam a aparecer como uma única origem, `10.69.63.119`,
para o AdGuard) — o que explica a falha intermitente (não 100% consistente)
observada.

**Decisão revisada:** a prioridade da nossa regra não pode depender de ficar
"logo abaixo" de um valor específico que o Tailscale escolhe internamente e
pode mudar entre versões. Prioridade alterada de `5200` para **`100`** — bem
abaixo de toda a faixa que o Tailscale usa (5199–5270 observados), tornando a
regra robusta a mudanças futuras de versão:

```bash
ip rule del to 172.16.0.0/12 lookup main priority 5200
ip rule add to 172.16.0.0/12 lookup main priority 100
```

`/etc/systemd/system/tailscale-docker-forward.service` atualizado para usar
`priority 100` no `ExecStart`. Validado com captura de pacotes: tráfego
Tailscale→Docker passou a ir direto pela bridge (`br-3f53f4cdd713` →
`veth...`), sem tocar `wg-mull-br`, e o cliente real voltou a receber a
resposta correta do AdGuard de forma consistente.

**Lição para o futuro:** nunca escolher uma prioridade de `ip rule` "relativa"
a uma regra gerenciada por outro sistema (Tailscale, neste caso) sem
verificar se essa referência é estável entre versões. Preferir sempre um
valor bem afastado de toda a faixa observada do outro sistema. Ver incidente
completo em `docs/migration-log.md` (2026-07-09/16).

> **Nota (2026-07-17):** a atribuição a "regra interna do Tailscale" acima
> estava **errada** — a regra `iif tailscale0 lookup 51820` nunca foi gerenciada
> pelo Tailscale. Ver a atualização abaixo para a causa raiz real.

---

## Atualização — 2026-07-17: a causa raiz de 07-16 estava mal diagnosticada

**Contexto:** menos de 24h depois da correção acima (prioridade 100), o mesmo
sintoma voltou — todos os painéis internos inacessíveis via Tailscale, em
todos os dispositivos. `ip rule list` mostrava a regra `iif tailscale0 lookup
51820` agora em priority **99** (não 5199 como no dia anterior), de novo
acima da nossa (100), reabrindo o mesmo desvio pelo `wg-mull-br`.

**Causa raiz real:** a regra `iif tailscale0 lookup 51820` **não é gerenciada
pelo Tailscale** — a atribuição a "regra interna do Tailscale" na atualização
de 07-16 estava incorreta. Ela é criada pelo nosso próprio
`/etc/wireguard/wg-mull-br.conf`, num `PostUp` que existe desde a Fase 1:

```
PostUp = ip rule add iif tailscale0 table 51820
```

Sem `priority` explícita. Toda vez que o `wg-quick` sobe o túnel, o
`iproute2` atribui um valor de prioridade arbitrário para essa regra, com
base no estado do sistema naquele momento — por isso ela apareceu em 5209
(maio), 5199 (07-16) e 99 (07-17): não é o Tailscale mudando de versão, é a
nossa própria regra sendo recriada sem posição fixa toda vez que o
`wg-mull-br` reinicia.

E por que ela reiniciou hoje sem ninguém mexer manualmente? O `tailscaled`
fez auto-update em background (1.98.8 → 1.98.9, `journalctl -u tailscaled`
mostra o restart às 15:31 UTC). O drop-in do ADR-010 declara
`Requires=tailscaled.service` em `wg-quick@wg-mull-br.service` — e
`Requires=` propaga parada/reinício: quando `tailscaled.service` reinicia,
`wg-quick@wg-mull-br.service` reinicia junto, o `PostUp` roda de novo, e a
regra sem prioridade fixa cai em outro valor arbitrário. Uma correção do
ADR-010 (pensada para resolver a corrida de boot) acabou criando um gatilho
de recorrência para o bug do ADR-006.

**Decisão definitiva:**

1. **Fixar a prioridade na origem**, em `/etc/wireguard/wg-mull-br.conf`:
   ```
   PostUp   = ip rule del iif tailscale0 lookup 51820 priority 20000 2>/dev/null || true; ip rule add iif tailscale0 table 51820 priority 20000
   PostDown = ip rule del iif tailscale0 lookup 51820 priority 20000 2>/dev/null || true
   ```
   O `del` antes do `add` (com `|| true`, não só `2>/dev/null` — redirecionar
   stderr não zera o exit code, e o `wg-quick` roda com `set -e`) torna o
   `PostUp` idempotente: subir o túnel duas vezes seguidas, ou depois de um
   `PostDown` que falhou pela metade, não trava mais em `RTNETLINK answers:
   File exists`. O mesmo padrão foi aplicado à rota `100.64.0.0/10 dev
   tailscale0 table 51820`, que tem o mesmo problema de idempotência.

2. **Self-healing como camada extra**, em
   `tailscale-docker-forward.service`: o `ExecStart` foi trocado por um
   script (`/usr/local/sbin/tailscale-docker-forward.sh`) que descobre a
   prioridade viva da regra `iif tailscale0` (via `ip rule list`, que sempre
   imprime a palavra-chave como `lookup`, nunca `table`, independente de qual
   foi usada no `ip rule add`) e instala a nossa regra uma posição abaixo —
   com fallback para 100 caso a regra do Mullvad não exista. O serviço
   também ganhou `PartOf=wg-quick@wg-mull-br.service`, que o reinicia
   automaticamente sempre que o `wg-quick@wg-mull-br` reiniciar (por
   qualquer motivo, incluindo a cascata do `tailscaled`), reaplicando a
   prioridade correta sem intervenção manual. Validado ao vivo: um
   `systemctl restart wg-quick@wg-mull-br.service` (simulando o auto-update
   de hoje) disparou o restart do `tailscale-docker-forward.service` via
   `PartOf`, que recalculou e reinstalou a regra corretamente (priority
   19999, uma abaixo dos 20000 fixos).

**Por que as duas camadas, e não só uma:** fixar a prioridade na origem
(1) resolve o problema definitivamente enquanto ninguém editar o `.conf` à
mão; o self-healing (2) é a rede de segurança para quando isso acontecer de
novo apesar da fixação — por exemplo, se um `.conf` novo for gerado a partir
do site do Mullvad (rotação de chaves, ver RUNBOOK) e a linha `priority
20000` for perdida na hora de colar o novo conteúdo.

**Lição para o futuro:** ao investigar um "número que muda sozinho" em uma
regra do sistema, verificar primeiro **quem realmente cria essa regra** —
`grep` nos `.conf`/`PostUp` do próprio repositório antes de assumir que é
outro daemon gerenciando algo internamente. O diagnóstico de 07-16 gastou
tempo investigando versões do `tailscaled` quando a causa estava numa linha
sem `priority` no nosso próprio arquivo, criado na Fase 1. Ver incidente
completo em `docs/migration-log.md` (2026-07-17).

---

## Atualização — 2026-07-29: a causa raiz recorrente nunca foi a prioridade

**Contexto:** quarta recorrência. Sintoma novo: o exit node parou de funcionar
para os dispositivos (celular sem internet com o Tailscale ligado), enquanto os
painéis continuavam acessíveis e o servidor parecia perfeitamente saudável —
túnel com handshake fresco, `mullvad_exit_ip: true`, unit `active`, DNS
respondendo em 2ms.

**Causa raiz, com prova no journal do `tailscaled` (`Jul 29 06:28:31`):**

```
monitor: RTM_DELROUTE: dst=10.0.0.0/24   table=254   <- enp0s6 perdendo o endereço
monitor: RTM_DELROUTE: dst=10.0.0.166/32 table=255
monitor: ip rule deleted: Priority:5210    (do Tailscale)
monitor: ip rule deleted: Priority:20000   <- nossa (iif tailscale0)
monitor: ip rule deleted: Priority:5230    (do Tailscale)
monitor: ip rule deleted: Priority:19999   <- nossa (to 172.16.0.0/12)
monitor: ip rule deleted: Priority:5270    (do Tailscale)
monitor: ip rule deleted: Priority:5250    (do Tailscale)
```

Uma renovação de lease DHCP na `enp0s6` removeu o endereço da interface e
disparou um **flush completo das `ip rule` do sistema**. O `tailscaled`
reconstruiu as suas; as nossas duas ficaram para trás.

Sem a regra `iif tailscale0`, o tráfego dos dispositivos caiu na tabela `main` e
saiu pela interface física com origem `100.64.0.0/10` — CGNAT, não roteável — e
sem MASQUERADE, porque a única regra existente casa com `-o wg-mull-br`. Os
pacotes eram descartados no primeiro roteador: SYN sem resposta, timeout
infinito, e **nenhum sinal do lado do servidor**.

Os painéis continuaram funcionando porque a *outra* regra sumiu junto: sem
`to 172.16.0.0/12 lookup main`, o tráfego para os containers cai na tabela
`main`, que já tem as rotas das bridges. Duas ausências que se cancelavam para
um caminho e se somavam contra o outro — o que mascarou o problema.

**Por que as três correções anteriores não resolveram:** todas trataram a
*prioridade* da regra (5200 → 100 → 20000 fixa → autocalculada). A prioridade
era um problema real e está resolvida. Mas o modo de falha recorrente é outro:
**a regra simplesmente deixa de existir**, varrida por um evento de rede que não
tem nada a ver com o Mullvad nem com o Tailscale. Nenhuma escolha de prioridade
protege contra isso.

**Decisão:** parar de tentar tornar a regra imune e passar a **vigiar o
resultado**. O `homelab-vpn-watchdog` (ADR-014) ganhou um teste do caminho de
saída que pergunta direto ao kernel:

```bash
ip route get 1.1.1.1 from 100.64.0.1 iif tailscale0
# deve responder "dev wg-mull-br table 51820"
```

Origem sintética, não precisa de peer conectado, custa uma syscall. Se a
resposta não for a interface do túnel, o watchdog reinstala as duas regras e
notifica. Janela máxima de exposição: 60 segundos.

**Lição:** três ADRs seguidos trataram o sintoma que estava visível (a
prioridade errada) porque a regra sempre *existia* quando fomos olhar. O modo de
falha real — a regra não existir — só apareceu quando um teste verificou o
**resultado** (o pacote sai por onde?) em vez do **estado** (a regra está com a
prioridade certa?). É a mesma lição do ADR-014, por outro caminho.
