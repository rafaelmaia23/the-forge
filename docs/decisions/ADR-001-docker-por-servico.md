# ADR-001 — Docker por serviço vs. Compose único

**Status:** Aceito
**Data:** 2026-05-04

---

## Contexto

O servidor executa múltiplos serviços com ciclos de vida e responsabilidades
diferentes: DNS, proxy reverso, cloud pessoal, mídia, monitoramento,
localização. A questão era: um único `compose.yaml` na raiz gerenciando
tudo, ou um por serviço em diretório próprio?

## Decisão

Cada serviço ou stack tem seu próprio `compose.yaml` em diretório separado
dentro de `services/`. Todos compartilham a rede Docker `proxy` (externa,
bridge), criada uma única vez pelo `provision.sh`.

```
services/
├── adguard/
│   └── compose.yaml
├── nginx-proxy-manager/
│   └── compose.yaml
├── nextcloud/
│   └── compose.yaml
└── ...
```

## Justificativa

Compose único seria mais simples de gerenciar num primeiro momento, mas
qualquer operação (restart, update, debug) afeta todos os serviços ao mesmo
tempo. Em produção isso é inaceitável — um update do Nextcloud não deve
arriscar derrubar o AdGuard.

## Consequências

**Positivas:**
- Falha em um serviço não derruba os demais
- Updates e restarts independentes por serviço
- Git history claro — cada serviço tem seus próprios commits
- Fácil de remover um serviço sem afetar os outros
- Mais fácil de documentar e apresentar como portfólio

**Atenção:**
- A rede `proxy` precisa existir antes de qualquer stack ser iniciada —
  feito pelo `provision.sh` (`docker network create proxy`)
- Comunicação entre containers de stacks diferentes requer `container_name:`
  explícito no `compose.yaml` e ambos na rede `proxy`
