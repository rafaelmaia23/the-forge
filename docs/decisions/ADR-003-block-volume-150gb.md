# ADR-003 — Block volume de 150 GB montado desde a Fase 1

**Status:** Aceito
**Data:** 2026-05-04

---

## Contexto

O free tier OCI inclui 200 GB de block storage total. A distribuição
escolhida foi: boot volume de 50 GB + block volume separado de 150 GB.
A questão era quando criar e montar o block volume.

O plano original do guia previa adiar o block volume para quando o boot
volume se aproximasse de 80% de uso. A alternativa foi criar e montar
desde o início da Fase 1.

## Decisão

Criar o block volume de 150 GB e montá-lo em `/mnt/data` já na Fase 1,
antes de rodar o `provision.sh`.

Montagem em `/mnt/data` (não diretamente em `/mnt`) para permitir múltiplos
volumes no futuro com pontos de montagem descritivos (`/mnt/data`,
`/mnt/backup`, etc.).

Entrada no `/etc/fstab` com `_netdev,noatime,nofail`:
- `_netdev` — recomendação explícita da Oracle para block volumes OCI
  (garante que a rede sobe antes de tentar montar)
- `noatime` — reduz escritas desnecessárias no disco
- `nofail` — VM sobe normalmente mesmo se o volume tiver problema

## Justificativa

Criar o volume desde o início evita a necessidade de migrar dados depois.
Migrar `/mnt/data` com serviços rodando exigiria parar tudo, copiar os
dados, atualizar o fstab e reiniciar — operação com risco de corrupção e
downtime. Mais simples resolver antes de ter dados.

O custo de ter o volume "vazio" por algumas fases é zero — o free tier
cobre os 150 GB independentemente de uso.

## Consequências

**Positivas:**
- Sem necessidade de migração futura — dados já nascem no lugar certo
- Separação clara entre sistema operacional (boot, 50 GB) e dados (150 GB)
- Espaço generoso desde o início sem risco de encher o boot volume

**Atenção:**
- Block volumes OCI são zonais — se a VM for recriada em outro AD, o volume
  precisa ser migrado ou recriado
- Monitorar uso: `df -h /mnt/data` — agir antes de 80% (120 GB)
- O volume pode ser expandido online pelo painel OCI sem downtime,
  mas requer `resize2fs` na VM após o resize
