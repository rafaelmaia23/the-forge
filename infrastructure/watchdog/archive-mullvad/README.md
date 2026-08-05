# Arquivo morto — watchdog do túnel Mullvad

Estes arquivos implementavam o watchdog do túnel Mullvad WireGuard
(`wg-mull-br`), retirado em 2026-08-05 junto com a saída via VPN pública. Ver
[ADR-015](../../../docs/decisions/ADR-015-remocao-mullvad-saida-direta.md).

**Não são mais instalados por `infrastructure/provision.sh`.** Ficam aqui só
como referência histórica e ponto de partida caso a VPN volte a fazer sentido
no futuro — o procedimento completo de rollback está na ADR-015.

O `.conf` do WireGuard com as chaves (que nunca esteve neste repositório,
sempre viveu em `/etc/wireguard/` na VM) e o `.env` com os tokens reais de
push do Uptime Kuma estão guardados fora do repo, em
`~/.homelab/backups/mullvad-removal-2026-08-05/` na própria VM.
