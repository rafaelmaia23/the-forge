# ADR-015 — Remoção do Mullvad WireGuard; saída direta com exit node opt-in

**Status:** Aceito
**Data:** 2026-08-05

---

## Contexto

Desde a Fase 1, a VPS operava como duas VPNs empilhadas: Tailscale como rede
privada + exit node, encaminhando o tráfego dos dispositivos por um túnel
Mullvad WireGuard (`wg-mull-br`) via policy routing (`iif tailscale0 lookup
51820`, ver ADR-002, ADR-004, ADR-005). Essa combinação funcionou, mas seu
custo operacional acabou sendo alto:

- **ADR-006** (regra de prioridade sumindo): a regra `iif tailscale0 lookup
  51820`, sem prioridade fixa, tinha seu valor redefinido pelo `iproute2` toda
  vez que o `wg-quick` reiniciava — o que acontecia sempre que o `tailscaled`
  se auto-atualizava, por causa do `Requires=` do ADR-010. Duas ocorrências em
  produção (2026-07-16 e 2026-07-17) desviaram todo o tráfego Tailscale→Docker
  para dentro do túnel Mullvad.
- **ADR-010** (ordem de boot): o `wg-quick@wg-mull-br` dependia de
  `tailscale0` existir; sem essa dependência explícita, um boot podia
  apagar a própria interface Mullvad por falha de `PostUp`.
- **ADR-014** (incidente de 2026-07-28): o bloco `[Peer]` do `.conf` foi
  perdido numa edição manual e ficou **11 dias** latente até o próximo boot
  reler o arquivo quebrado — os dispositivos ficaram sem internet, a VPS
  continuou "saudável" por qualquer métrica de estado.
- O próprio `enter_failover()` do watchdog de VPN, criado para lidar com
  esses incidentes, já demonstrava — como estado degradado *temporário* — que
  a saída direta (sem Mullvad, MASQUERADE pela interface física) funciona
  bem. Este ADR torna esse estado o padrão permanente e deliberado, em vez de
  uma emergência.

Por custo e simplicidade operacional, a assinatura Mullvad foi cancelada.

## Decisão

- **Remover** o túnel `wg-mull-br`, seus 3 backups `.bak-*` e os 4 configs
  regionais nunca usados (`wg-mull-{ch,jp,uk,us}.conf`), a unit
  `wg-quick@wg-mull-br.service` (mascarada) e o drop-in systemd do ADR-010.
- **Preservar sem alteração** a rede privada Tailscale e o DNS AdGuard para
  os dispositivos — nenhuma mudança em `tailscaled`, na rede Docker `proxy`,
  nas rewrites do AdGuard, ou no `homelab-dns-watchdog`.
- **Preservar `tailscale up --advertise-exit-node`** — o servidor continua
  oferecendo a função de exit node. O uso passa a ser **100% opt-in por
  dispositivo** (`tailscale set --exit-node=<ip>` quando quiser mascarar o
  IP; `tailscale set --exit-node=` para voltar ao padrão). Nenhum dispositivo
  usa por padrão — confirmado em produção (`tailscale status` mostrava todos
  os pares como `direct` mesmo antes desta mudança).
- **Novo `tailscale-exit-masquerade.sh`/`.service`**: instala um
  `MASQUERADE` persistente de `100.64.0.0/10` pela interface física
  (descoberta em runtime via `ip route show default`, não fixada), para o
  exit node opt-in continuar funcionando sem o Mullvad. Sem isso, o tráfego
  do exit node sairia com origem CGNAT não roteável e seria descartado no
  primeiro roteador — o `tailscaled` não faz esse NAT sozinho porque
  `--snat-subnet-routes=false` está ligado (ver abaixo).
- **Manter `tailscale set --snat-subnet-routes=false`** (ADR-007) — não
  relacionado ao Mullvad, necessário para o Access List do NPM enxergar o IP
  Tailscale real dos dispositivos. Reativar reintroduziria os 403
  documentados em 2026-07-29.
- **Desacoplar `tailscale-docker-forward.service`** do ciclo de vida do
  Mullvad — a unit tinha `PartOf=wg-quick@wg-mull-br.service`, que faria
  parar o Mullvad derrubar junto a regra `DOCKER-USER -i tailscale0 -j
  ACCEPT` (necessária para os dispositivos alcançarem o AdGuard e os
  painéis). Removido `PartOf=` e a dependência em `After=`.
- **Aposentar `homelab-vpn-watchdog`** (script, unit, timer) — monitorava
  especificamente o túnel Mullvad; sem túnel, não há mais o que supervisionar
  nessa camada. Movido para `infrastructure/watchdog/archive-mullvad/`
  (versionado, não instalado por `provision.sh`). `homelab-dns-watchdog` e
  `homelab-stacks-boot` continuam intactos e ativos.

## O que foi preservado vs. removido

| | Preservado | Removido |
| --- | --- | --- |
| Rede privada | Tailscale (rede, MagicDNS, acesso aos painéis) | — |
| DNS | AdGuard + `homelab-dns-watchdog` | — |
| Exit node | Capacidade anunciada, uso opt-in por dispositivo | Uso automático/permanente (nunca existiu de fato) |
| Saída à internet | Direta, via IP público Oracle | Túnel Mullvad WireGuard |
| Docker forwarding | `tailscale-docker-forward.service` (desacoplado) | `PartOf=wg-quick@wg-mull-br.service` |
| Watchdogs | DNS, stacks-boot | Watchdog de VPN/failover |
| Config Mullvad | Backup em `~/.homelab/backups/mullvad-removal-2026-08-05/` (VM) | `/etc/wireguard/wg-mull-*.conf*`, override systemd |

## Justificativa

O trade-off aceito é perder o IP mascarado *por padrão* — os dispositivos
agora saem com o IP da própria rede, não mais com um IP Mullvad. O usuário
avaliou esse ponto explicitamente e decidiu que a privacidade adicional não
compensava mais o custo e a complexidade operacional, dado o histórico de
incidentes acima. A opção de mascarar o IP pontualmente (ligando o exit node
num dispositivo específico) continua disponível para os casos em que isso
importar — só deixou de ser o caminho padrão.

## Consequências

**Positivas:**
- Elimina inteiramente a classe de incidentes documentada em ADR-006/010/014
  — não há mais duas VPNs competindo por prioridade de rota, nem um `.conf`
  fora do repositório cujo erro fica latente até o próximo boot.
- Menos uma assinatura paga, menos uma superfície de falha.
- `RUNBOOK.md`/`overview.md` ficam mais simples — menos procedimentos de
  emergência específicos de VPN dupla.

**Atenção:**
- O IP de saída dos dispositivos passa a ser o IP público da rede de cada
  um (ou o IP Oracle, se o exit node estiver ligado) — não há mais IP
  Mullvad por padrão.
- Se o exit node for ligado num dispositivo, o tráfego sai pelo IP público
  Oracle, publicamente atribuível à VPS — sem o anonimato de uma VPN
  comercial. Aceito conscientemente.

## Rollback

1. `git checkout pre-mullvad-removal-2026-08-05 -- infrastructure/ docs/ CLAUDE.md RUNBOOK.md`
2. Restaurar os arquivos de `~/.homelab/backups/mullvad-removal-2026-08-05/`
   na VM:
   ```bash
   sudo cp ~/.homelab/backups/mullvad-removal-2026-08-05/etc-wireguard/* /etc/wireguard/
   sudo cp -a ~/.homelab/backups/mullvad-removal-2026-08-05/systemd/wg-quick@wg-mull-br.service.d \
     /etc/systemd/system/
   ```
3. `sudo systemctl unmask wg-quick@wg-mull-br.service`
4. `sudo systemctl daemon-reload && sudo systemctl enable --now wg-quick@wg-mull-br.service`
5. Restaurar `PartOf=wg-quick@wg-mull-br.service` em
   `tailscale-docker-forward.service` (repo e unit ao vivo).
6. Reinstalar o watchdog de VPN a partir de
   `infrastructure/watchdog/archive-mullvad/` (script em
   `/usr/local/sbin/`, units em `/etc/systemd/system/`,
   `systemctl enable --now homelab-vpn-watchdog.timer`).
7. Restaurar o bloco `VPN_PUSH_URL`/`WG_*` em `/etc/homelab-watchdog.env` a
   partir de `~/.homelab/backups/mullvad-removal-2026-08-05/homelab-watchdog.env.pre-removal`
   (tokens reais — não versionar).
8. Remover/desabilitar `tailscale-exit-masquerade.service` — redundante com
   o MASQUERADE que o `PostUp` do `wg-mull-br.conf` volta a instalar.

## Artefatos

| Onde | O quê |
| --- | --- |
| git tag `pre-mullvad-removal-2026-08-05` | ponto de restauração completo do repositório |
| `~/.homelab/backups/mullvad-removal-2026-08-05/` (VM, fora do repo) | `.conf`s do WireGuard com chaves, override systemd, `.env` com tokens reais, snapshot de `ip rule`/`ip route`/`iptables`/`wg show` de antes da mudança |
| `infrastructure/watchdog/archive-mullvad/` | script, unit e timer do watchdog de VPN (sem segredos, versionado) |
| `/usr/local/sbin/tailscale-exit-masquerade.sh` + `.service` | NAT de saída direta para o exit node opt-in |
