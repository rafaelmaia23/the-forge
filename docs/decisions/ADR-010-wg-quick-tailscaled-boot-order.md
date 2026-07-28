# ADR-010 — Ordem de boot: wg-quick@wg-mull-br depende de tailscaled

**Status:** Aceito
**Data:** 2026-07-16

---

## Contexto

Em um incidente ocorrido em 2026-07-09, a VPS precisou ser reiniciada (para
resolver um processo de atualização automática travado desde maio). Após o
reboot, os containers Docker subiram normalmente, mas a internet dos
dispositivos que usam a VPS como exit node Tailscale continuou fora do ar. A
correção na hora foi manual: `sudo wg-quick up wg-mull-br`.

Investigação posterior (2026-07-16, via `journalctl -b`) revelou a causa raiz:

```
wg-quick[1215]: [#] ip route add 100.64.0.0/10 dev tailscale0 table 51820
wg-quick[1370]: Cannot find device "tailscale0"
wg-quick[1215]: [#] ip link delete dev wg-mull-br
systemd[1]: wg-quick@wg-mull-br.service: Main process exited, code=exited, status=1/FAILURE
```

O `PostUp` do `wg-mull-br.conf` (ver ADR-005) inclui `ip route add 100.64.0.0/10
dev tailscale0 table 51820` — depende da interface `tailscale0` já existir. A
unidade `wg-quick@.service` (fornecida pelo pacote `wireguard-tools`, não
customizada por este projeto) só declara:

```ini
After=network-online.target nss-lookup.target
Wants=network-online.target nss-lookup.target
```

Nenhuma dependência de `tailscaled.service`. No boot, os dois serviços sobem em
paralelo assim que a rede está online — não há garantia de que `tailscaled`
já tenha criado a interface `tailscale0` antes do `wg-quick` tentar referenciá-la.
Quando isso ocorre, o `wg-quick` falha, apaga a interface que acabou de criar
(`ip link delete`), e fica em estado `failed` — **sem retry automático** — até
alguém subir o túnel manualmente.

## Decisão

Criar um drop-in systemd para adicionar a dependência e uma espera ativa pela
interface, sem modificar o pacote `wireguard-tools`:

```bash
sudo systemctl edit wg-quick@wg-mull-br.service
```

```ini
[Unit]
After=tailscaled.service
Requires=tailscaled.service

[Service]
ExecStartPre=/usr/bin/timeout 30 bash -c 'until ip link show tailscale0 >/dev/null 2>&1; do sleep 1; done'
```

Persistido em `/etc/systemd/system/wg-quick@wg-mull-br.service.d/override.conf`.

## Justificativa

**Por que `Requires=` além de `After=`:**
`After=` sozinho só garante ordem, não que `tailscaled.service` esteja de fato
ativo. Como o túnel Mullvad depende funcionalmente do Tailscale (a rota
`100.64.0.0/10 dev tailscale0` só faz sentido com a interface presente),
`Requires=` deixa a dependência explícita.

**Por que `ExecStartPre` além de `After=`/`Requires=`:**
`systemd` considerar `tailscaled.service` como "started" não significa que a
interface `tailscale0` já existe no kernel — a criação da interface é
assíncrona dentro do próprio `tailscaled`. O `ExecStartPre` espera ativamente
(polling de 1s, timeout de 30s) até a interface aparecer, eliminando a corrida
residual que `After=`/`Requires=` sozinhos não cobrem.

**Por que drop-in e não editar `wg-quick@.service` diretamente:**
`wg-quick@.service` é um arquivo do pacote `wireguard-tools` — seria
sobrescrito em uma atualização do pacote. O drop-in (`systemctl edit`) é o
mecanismo suportado pelo systemd para customização persistente por instância
(`wg-quick@wg-mull-br`, não afeta outras interfaces `wg-quick@*` se existirem).

**Por que não usar `Wants=` no lugar de `Requires=`:**
`Wants=` não impede o `wg-quick` de subir se `tailscaled` falhar ao iniciar. Já
que o túnel depende funcionalmente do Tailscale existir, `Requires=` é a
semântica correta — sem Tailscale, não faz sentido tentar subir o Mullvad.

## Consequências

**Positivas:**
- Reboots futuros não deixam mais o Mullvad em estado `failed` — validado com
  reboot real da VPS em 2026-07-16 (túnel subiu sozinho, com handshake, sem
  intervenção manual).
- A correção é local à unidade `wg-mull-br` — não afeta outras interfaces
  WireGuard que eventualmente existam sob o mesmo template `wg-quick@.service`.

**Atenção / gotcha descoberto durante a validação:**
Rodar `wg-quick up`/`wg-quick down` manualmente (fora do `systemctl`, direto no
shell) enquanto o túnel já está ativo, ou repetidamente em sequência rápida,
pode deixar rotas órfãs na tabela `51820` — especificamente a rota
`100.64.0.0/10 dev tailscale0`, que referencia uma interface diferente da que
está sendo removida (`wg-mull-br`) e por isso não é limpa automaticamente pelo
kernel quando a interface do túnel desaparece. Isso bloqueia o próximo `up` com
`RTNETLINK answers: File exists`. O RUNBOOK.md já documentava a limpeza
correta (`ip route del 100.64.0.0/10 table 51820` + `ip rule del iif
tailscale0 table 51820`) na seção "Trocar de servidor" — reforçado como passo
obrigatório sempre que o túnel for subido/derrubado manualmente, não só ao
trocar de servidor Mullvad.

## Artefatos criados

| Arquivo | Onde |
| --- | --- |
| `/etc/systemd/system/wg-quick@wg-mull-br.service.d/override.conf` | VM — fora do repositório |

> Assim como o `tailscale-docker-forward.service` (ADR-006), este drop-in deve
> ser recriado pelo `provision.sh` em uma reinstalação do zero.

---

## Nota — 2026-07-17: efeito colateral do `Requires=tailscaled.service`

O `Requires=` adicionado aqui propaga parada/reinício: quando `tailscaled`
reinicia por qualquer motivo (inclusive auto-update em background, sem
reboot), `wg-quick@wg-mull-br` reinicia junto. Isso é o comportamento
desejado para o problema que este ADR resolve, mas teve uma consequência não
prevista — o `PostUp` de `wg-mull-br.conf` recria a regra `ip rule iif
tailscale0 table 51820` a cada reinício, e até 2026-07-17 essa regra não
tinha prioridade fixa, causando a recorrência do bug do ADR-006 sempre que o
`tailscaled` atualizava sozinho. Corrigido fixando `priority 20000` no
`wg-mull-br.conf` — ver a atualização de 2026-07-17 no ADR-006 para a causa
raiz completa.

---

## Atualização — 2026-07-28: retry automático e a falha que o `ExecStartPre` não cobre

Este ADR resolveu a corrida de boot, mas a seção "Contexto" já observava que a
unit fica em `failed` **sem retry automático** quando algo dá errado — e isso
continuou verdadeiro para qualquer falha que não fosse a ausência da interface
`tailscale0`.

Foi exatamente o que aconteceu em 2026-07-28: o `wg-mull-br.conf` havia perdido
o bloco `[Peer]` numa edição em 17/07, o reboot releu o arquivo quebrado, e o
túnel subiu **sem peer nenhum** — a unit ficou `active`, e todo o tráfego de
exit node caiu num buraco negro por horas, sem alerta.

Duas adições ao drop-in:

```ini
Restart=on-failure
RestartSec=15
StartLimitBurst=5
StartLimitIntervalSec=300
```

E, para o caso que o systemd **não** consegue detectar — unit `active` com túnel
morto — um watchdog externo que testa handshake e saída real, com failover para
o gateway direto. Ver [ADR-014](ADR-014-watchdogs-e-failover-de-saida.md).

**Lição:** `Restart=on-failure` cobre o processo que falha ao subir. Não cobre o
processo que sobe com sucesso configurando a coisa errada — para isso só um
teste de comportamento serve.
