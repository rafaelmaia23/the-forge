# ADR-009 — Nextcloud stack manual vs. All-in-One (AIO)

**Status:** Aceito  
**Data:** 2026-05-19

---

## Contexto

Para a Fase 5 do homelab, era necessário escolher como instalar o Nextcloud. Existem duas abordagens oficiais:

**Nextcloud All-in-One (AIO):** solução oficial da equipe Nextcloud que empacota todos os componentes (Nextcloud, PostgreSQL, Redis, Collabora, ClamAV, Fulltextsearch, Imaginary, Backup) em um único container gerenciador que cria e orquestra os demais automaticamente via Docker-in-Docker.

**Stack manual:** cada componente é um container separado, configurado individualmente em um `compose.yaml` versionado no repositório.

---

## Decisão

Stack manual em containers separados em `services/cloud/compose.yaml`.

---

## Justificativas

### Consistência arquitetural

O ADR-001 estabelece que cada serviço tem seu próprio `compose.yaml` em `services/`. A stack manual segue esse princípio — cada container é explícito, versionado e inspecionável.

### Controle sobre componentes

A stack manual permite escolher versões específicas de cada componente:

- PostgreSQL 17 (mais novo, suporte mais longo)
- Elasticsearch 8 (versão compatível verificada antes de subir)
- `nextcloud/aio-imaginary` em vez de `h2non/imaginary` (ARM64 nativo)

O AIO define internamente as versões dos componentes sem exposição de controle.

### Debugging e visibilidade

Com containers separados:
- Logs isolados por serviço (`docker logs nextcloud-elasticsearch -f`)
- Restart granular sem afetar os demais containers
- Inspeção individual de cada container via Portainer
- Métricas por container no Netdata

O AIO oculta os containers internos atrás do gerenciador, dificultando inspeção.

### Compatibilidade com o modelo de backup (Fase 8)

Os volumes nomeados (`nextcloud_config`, `nextcloud_apps`, `nextcloud_db`) e o bind mount em `/mnt/data/nextcloud/userdata` são previsíveis e diretamente integráveis ao script de backup com Restic.

O AIO usa um volume monolítico e gerencia internamente o backup — incompatível com a estratégia Restic + B2 planejada.

### Portfolio e aprendizado

O projeto tem como objetivo explícito demonstrar habilidades de DevOps. A stack manual documenta cada decisão arquitetural e torna o sistema auditável.

---

## Consequências

**Positivas:**
- Controle total sobre versões, configurações e ciclo de vida de cada componente
- Troubleshooting mais fácil com logs e containers separados
- Integração direta com o modelo de backup da Fase 8
- Histórico Git granular por componente

**Negativas:**
- Configuração inicial mais trabalhosa (8 containers vs. 1)
- Atualizações de componentes requerem atenção individual
- Interdependências de versão (ex: Nextcloud 31 ↔ Elasticsearch 8.x) precisam ser verificadas manualmente

---

## Alternativa descartada

**Nextcloud AIO** — descartado pelos motivos acima. Não avaliado em profundidade pois os trade-offs eram evidentes.
