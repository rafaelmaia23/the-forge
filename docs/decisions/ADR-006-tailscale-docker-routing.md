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
