# ADR-011 — Reserva de faixa IPAM para IPs fixos na rede `proxy`

**Status:** Aceito
**Data:** 2026-07-28

---

## Contexto

Dois containers da rede `proxy` dependem de endereço estável:

- **`adguard` (`172.18.0.2`)** — o Uptime Kuma tem esse IP hardcoded no monitor de
  DNS e no próprio `dns:` do compose (ADR-008).
- **`npm` (`172.18.0.3`)** — o `extra_hosts` do `nextcloud` e do
  `nextcloud-collabora` aponta `cloud.maiahub.com.br` e `office.maiahub.com.br`
  para esse endereço, contornando o hairpin NAT.

O `adguard` tinha `ipv4_address: 172.18.0.2` no compose. O `npm` não tinha nada —
ele simplesmente *calhava* de receber `172.18.0.3` do pool dinâmico.

O problema: o Docker aloca IPs dinâmicos **a partir do início da subnet** —
`.2`, `.3`, `.4`, … — exatamente os endereços reservados. A rede `proxy` era
criada com `docker network create proxy`, sem nenhuma separação entre a faixa
dinâmica e a estática.

Consequência: a ordem de subida dos containers no boot decide quem fica com
quais endereços. Se um container dinâmico sobe antes do `adguard`, ele leva o
`172.18.0.2`, e o `adguard` — que exige aquele endereço — **não sobe mais**,
com `Address already in use`.

Isso aconteceu duas vezes:

| Data | Quem roubou o quê | Efeito |
| --- | --- | --- |
| 2026-07-09 | `uptime-kuma` pegou o `.2` | AdGuard fora do ar, DNS morto |
| 2026-07-28 | `portainer` pegou o `.2`, `pet-oasis-app` pegou o `.3` | AdGuard fora do ar **e** Nextcloud/Collabora apontando `cloud`/`office` para o container errado — WOPI quebrado em silêncio |

Nos dois casos o gatilho foi um reboot automático por `unattended-upgrade`. A
correção aplicada em 2026-07-09 foi manual (parar o container invasor, subir o
AdGuard, religar o invasor) — ou seja, tratava o sintoma e garantia a
recorrência.

## Decisão

Criar a rede `proxy` com `--ip-range`, separando a faixa dinâmica da estática:

```bash
docker network create \
    --driver bridge \
    --subnet 172.18.0.0/16 \
    --gateway 172.18.0.1 \
    --ip-range 172.18.128.0/17 \
    proxy
```

Resultado:

```
172.18.0.2   – 172.18.127.254   → reservado para ipv4_address (alocação manual)
172.18.128.0 – 172.18.255.254   → pool dinâmico do Docker
```

E fixar por `ipv4_address` todos os containers cujo endereço é referenciado em
algum lugar:

| Container | IP | Quem depende |
| --- | --- | --- |
| `adguard` | `172.18.0.2` | `dns:` e monitor DNS do Uptime Kuma |
| `npm` | `172.18.0.3` | `extra_hosts` do `nextcloud` e do `nextcloud-collabora` |
| `uptime-kuma` | `172.18.0.4` | push URL dos watchdogs, que rodam no host (ADR-014) |

## Justificativa

**Por que `ip_range` e não apenas "subir o adguard primeiro":**
Ordem de subida entre stacks independentes não é controlável no Docker Compose —
não existe `depends_on` cross-stack, e o daemon religa containers no boot em
ordem arbitrária. Qualquer solução baseada em ordem é uma corrida que se perde
eventualmente. O `ip_range` elimina a possibilidade do conflito por construção:
o Docker nunca mais tem como entregar um endereço reservado a um container
dinâmico.

**Por que `/17` e não uma faixa menor:**
`172.18.128.0/17` deixa ~32 mil endereços dinâmicos e ~32 mil reservados — folga
absurda dos dois lados para um homelab, e o corte no meio do `/16` é fácil de
ler em qualquer `docker network inspect`.

**Por que não abandonar os IPs fixos:**
Foi a alternativa considerada primeiro. Exigiria resolver três dependências
distintas: o `dns:` do Uptime Kuma (que não aceita nome de container), o
`extra_hosts` do Nextcloud (idem) e a push URL dos watchdogs (que rodam no host,
onde o DNS do Docker não existe). Nenhuma tem solução por nome — todas precisam
de um IP. Reservar a faixa é mais simples que eliminar as três dependências.

## Consequências

**Positivas:**
- Reboot deixou de ser um evento de risco para o DNS do homelab
- Novos serviços na rede `proxy` não precisam de cuidado nenhum: caem no pool
  dinâmico e nunca colidem com os fixos
- O `extra_hosts` do Nextcloud deixou de depender de coincidência

**Atenção:**
- Aplicar em uma rede existente **exige recriá-la** (`docker network rm`), o que
  obriga a parar todos os containers conectados. Não é uma mudança a quente.
- Todo IP fixo novo deve ficar **abaixo** de `172.18.128.0`. Um `ipv4_address`
  dentro da faixa dinâmica reintroduz exatamente o bug que este ADR resolve.
- Containers de projetos fora deste repositório (ex.: `pet-oasis`) também
  passam a receber IPs do pool dinâmico — o que é o comportamento desejado, mas
  significa que **nenhum** deles deve ter IP hardcoded em lugar nenhum.

## Artefatos

| Onde | O quê |
| --- | --- |
| `infrastructure/provision.sh` (seção 9) | criação da rede com `--ip-range` |
| `services/dns/compose.yaml` | `ipv4_address: 172.18.0.2` |
| `services/proxy/compose.yaml` | `ipv4_address: 172.18.0.3` |
| `services/monitoring/compose.yaml` | `ipv4_address: 172.18.0.4` |

Ver o incidente completo em `docs/migration-log.md` (2026-07-28).
