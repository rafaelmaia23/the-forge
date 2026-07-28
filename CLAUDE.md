# The Forge — Homelab

Referência para trabalhar neste repositório. Leia antes de fazer qualquer alteração.

---

## O projeto

Infraestrutura de auto-hospedagem completa rodando na **Oracle Cloud Free Tier (ARM A1)**.
Tudo roda como container Docker. O repositório é a fonte da verdade — nada existe fora dele.

Serviços: AdGuard Home (DNS), Nginx Proxy Manager, Nextcloud, Jellyfin + Arr Stack,
Portainer, Uptime Kuma, Netdata, Dawarich. VPN dupla: Tailscale (rede privada) + Mullvad WireGuard (saída).

**Status das fases:**
- ✅ Fase 1 — Fundação Oracle Cloud
- ✅ Fase 2 — AdGuard Home (DNS)
- ✅ Fase 3 — Nginx Proxy Manager (guia em `docs/phases/fase-3-proxy-npm.md`)
- ✅ Fase 4 — Portainer + Uptime Kuma + Netdata (guia em `docs/phases/fase-4-management.md`)
- ✅ Fase 5 — Nextcloud (guia em `docs/phases/fase-5-nextcloud.md`, config em `docs/nextcloud-config-reference.md`)
- ⏳ Fases 6–9 — pendentes

---

## Documentação principal

| Arquivo | Conteúdo |
| --- | --- |
| `docs/overview.md` | Arquitetura completa, plano de execução (fases 1–9), referência de comandos |
| `docs/migration-log.md` | Diário do que foi feito, problemas e soluções por fase |
| `docs/doc-conventions.md` | Como escrever docs: sanitização de IPs, placeholders, formato |
| `docs/backup-reference.md` | O que precisa de backup por fase/serviço (insumo para Fase 8) |
| `docs/nextcloud-config-reference.md` | Estado atual da stack Nextcloud — volumes, redes, apps, workarounds |
| `infrastructure/watchdog/` | Watchdogs de DNS, túnel VPN e reconciliação de boot (ADR-014) |
| `docs/phases/` | Guias de execução passo a passo por fase |
| `docs/decisions/` | Architecture Decision Records (ADRs) |
| `RUNBOOK.md` | Procedimentos operacionais do dia a dia |
| `secrets.env.example` | Template de todas as variáveis sensíveis |

---

## Regras do projeto

### Isolamento por serviço

- Cada serviço tem seu próprio `.gitignore` em `services/<nome>/`
- O `.gitignore` raiz cobre apenas o que é global ao homelab (segredos, logs, dumps SQL, arquivos de SO)
- Padrões específicos de um serviço (`data/`, `letsencrypt/`) ficam no `.gitignore` do próprio serviço, não no raiz
- **Nenhum serviço sobe na VM sem ter `.gitignore` criado e commitado antes**

### Certificados SSL

- **Um certificado por serviço/domínio** — sem wildcards
- **DNS Challenge via Cloudflare** para todos os serviços (necessário para domínios tailscale-only; usado de forma consistente para todos)
- Certificados gerenciados pelo NPM com renovação automática

### DNS

- **Um DNS Rewrite por serviço** no AdGuard — sem wildcards
- Cada fase adiciona seus próprios rewrites quando o serviço sobe (não pré-criar)

### Segredos

- Nunca commitar `.env`, senhas, tokens, chaves privadas, certificados
- Valores reais ficam em `~/.homelab/secrets.env` na VM (fora do repo)
- Placeholders no formato `{{NOME}}` nos docs — mapeados em `secrets.env.example`
- Senhas geradas com: `openssl rand -base64 32`

### Estrutura Docker

- Cada serviço tem seu próprio `compose.yaml` em `services/<nome>/`
- Redes sempre explícitas — nunca usar a rede default do Compose
- `container_name:` sempre definido — necessário para referência cross-stack
- `restart: unless-stopped` em todos os serviços de produção
- **IPs fixos só abaixo de `172.18.128.0`** — a rede `proxy` reserva
  `172.18.0.0/17` para `ipv4_address` e usa `172.18.128.0/17` como pool dinâmico.
  Um IP fixo dentro do pool reintroduz o conflito do ADR-011
- **Todo caminho declarado como `VOLUME` na imagem precisa de volume nomeado no
  compose** — senão vira volume anônimo e um `compose down` descarta o conteúdo
  (ADR-013)

### Rede e VPN

- **Nunca editar um `.conf` do WireGuard com o túnel no ar.** O `wg-quick` só lê
  o arquivo no `up`: um erro fica latente até o próximo boot. Sempre
  `wg-quick down` antes de editar (ADR-014)
- Supervisão testa **comportamento**, não estado: "container Up" e "unit active"
  já mascararam três falhas distintas em julho/2026 (ADR-014)

### Commits

- Cada serviço funcionando = 1 commit
- Padrão de mensagem: `tipo(escopo): descrição` em inglês
- Nunca commitar dados de runtime (`data/`, `letsencrypt/`, logs)
- Tags para marcos: `v1.0-foundation`, `v1.1-dns`, etc.

### Documentação

- Idioma: português nos docs, inglês nos comandos e identificadores técnicos
- Nunca commitar IPs reais, tokens ou credenciais — usar placeholders `{{NOME}}`
- `docs/migration-log.md` atualizado ao final de cada fase com o que foi feito
- Decisões não-óbvias documentadas como ADR em `docs/decisions/`

---

## Estrutura do repositório

```
services/
├── dns/          ← AdGuard Home (Fase 2 ✅)
├── proxy/        ← Nginx Proxy Manager (Fase 3 ✅)
├── cloud/        ← Nextcloud (Fase 5)
├── media/        ← Jellyfin + Arr Stack (Fase 6)
├── management/   ← Portainer (Fase 4)
├── monitoring/   ← Uptime Kuma + Netdata (Fase 4)
└── location/     ← Dawarich (Fase 7)

docs/
├── overview.md           ← referência completa do projeto
├── migration-log.md      ← diário de execução
├── doc-conventions.md    ← regras de documentação
├── backup-reference.md   ← inventário de backup
├── phases/               ← guias de execução por fase
└── decisions/            ← ADRs

infrastructure/
└── provision.sh          ← script de provisionamento do zero

backup/                   ← scripts de backup (Fase 8)
```
