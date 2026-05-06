# Convenções de Documentação

Referência para criar e manter docs neste repositório.

---

## Princípio fundamental: repo público

Este repositório é público. Toda documentação deve ser escrita assumindo que
qualquer pessoa pode ler. **Nunca commitar valores reais de IPs, tokens, senhas
ou identificadores únicos de infraestrutura.**

---

## Sanitização de informações sensíveis

### O que sanitizar

| Tipo | Exemplo real | Placeholder |
| --- | --- | --- |
| IP público Oracle | `152.70.x.x` | `{{OCI_PUBLIC_IP}}` |
| IP Tailscale da VM | `100.120.x.x` | `{{OCI_TS_IP}}` |
| Região OCI | `sa-saopaulo-1` | `{{OCI_REGION}}` |
| Availability Domain | `GrCH:SA-SAOPAULO-1-AD-1` | `{{OCI_AD}}` |
| IP da rede pessoal | `187.x.x.x` | `{{MEU_IP}}` |
| API token Cloudflare | `abc123...` | `{{CF_API_TOKEN}}` |
| Zone ID Cloudflare | `def456...` | `{{CF_ZONE_ID}}` |

### O que NÃO precisa sanitizar

- IPs privados de redes Docker internas (`172.18.x.x`, `10.0.0.x`) — são efêmeros e não roteáveis externamente
- Nomes de interfaces WireGuard (`wg-mull-br`) — já públicos e genéricos
- Prioridades de ip rules (`5200`, `5209`) — operacional, não sensível
- Nomes de containers (`adguard`, `nextcloud`) — definidos no compose.yaml público

### Como usar os placeholders

Escreva o placeholder literal no texto das docs:

```markdown
Acesse o painel em: `http://{{OCI_TS_IP}}:3000`
```

Os valores reais ficam em `secrets.env` (gitignored). Para executar comandos
das docs no terminal, exporte as variáveis primeiro:

```bash
source secrets.env
echo "Painel: http://$OCI_TS_IP:3000"
```

### secrets.env

O arquivo `secrets.env.example` na raiz do repo é o template com todas as
variáveis necessárias. Para uso local:

```bash
cp secrets.env.example secrets.env
# editar secrets.env com os valores reais
```

`secrets.env` está coberto pelo `.gitignore` (`*.env`) e nunca é commitado.

---

## Tipos de documentação

### Guias de fase (`docs/phases/fase-N-*.md`)

Documento executável — descreve passo a passo como implementar uma fase.

- Escrito antes ou durante a execução
- Inclui comandos prontos para copiar/colar
- Usa placeholders para qualquer valor específico da instalação
- Tem checklist final com todos os itens verificáveis
- Não documenta o que deu errado — isso vai no migration-log

### Migration log (`docs/migration-log.md`)

Diário da execução — documenta o que realmente aconteceu.

- Atualizado durante ou logo após a execução de cada fase
- Documenta desvios do plano original e por quê ocorreram
- Documenta problemas encontrados e como foram resolvidos
- Pode incluir identificadores específicos do deploy em contexto de debug
  (ex: bridge name num tcpdump) — são dados históricos, não segredos
- Usa placeholders para IPs e credenciais mesmo em contexto histórico

### ADRs (`docs/decisions/ADR-XXX-*.md`)

Registro de decisão arquitetural — explica o porquê de cada escolha relevante.

- Criado quando uma decisão não-óbvia é tomada
- Formato: Contexto → Decisão → Justificativa → Consequências
- Deve ser atemporal — lido meses depois deve fazer sentido
- Usa placeholders para qualquer valor específico da instalação
- Não documenta o processo de chegar à decisão — só a decisão final e o raciocínio

**Quando criar um ADR:**
- A decisão envolveu avaliar alternativas
- A decisão vai contra o óbvio ou o padrão comum
- Sem documentação, alguém (você mesmo, no futuro) vai questionar a escolha
- A decisão tem consequências não-óbvias que afetam fases futuras

### Network diagram (`docs/network-diagram.md`)

Visão do estado atual da infraestrutura.

- Atualizado ao final de cada fase que altera a topologia de rede
- Versão e data atualizadas no cabeçalho
- Seção "O que ainda não está ativo" removida item a item conforme as fases avançam
- Usa placeholders para todos os IPs

### Overview (`docs/overview.md`)

Documento de referência do projeto completo — arquitetura, decisões, plano.

- Atualizado quando decisões estruturais mudam (não a cada fase)
- Mantém o plano de execução atualizado com checkboxes

---

## Convenções de estilo

- **Idioma:** Português (ptBR) em toda a documentação
- **Código:** inglês nos comandos e identificadores técnicos
- **Tabelas:** usar `| --- |` (com espaços) nos separadores
- **Blocos de código:** sempre especificar a linguagem (` ```bash `, ` ```yaml `, etc.)
- **Commits:** mensagem descritiva em inglês seguindo o padrão `tipo(escopo): descrição`

---

## Checklist antes de commitar docs

- [ ] Nenhum IP real no texto (buscar por `\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b` exceto ranges privados Docker)
- [ ] Nenhum token ou API key visível
- [ ] Novos placeholders adicionados ao `secrets.env.example`
- [ ] Bloco de código tem linguagem especificada
- [ ] Separadores de tabela usam `| --- |` com espaços
