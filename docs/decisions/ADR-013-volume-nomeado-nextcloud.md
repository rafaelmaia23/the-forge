# ADR-013 — Volume nomeado para o código do Nextcloud

**Status:** Aceito
**Data:** 2026-07-28

---

## Contexto

O `compose.yaml` do Nextcloud declarava quatro bind mounts (`config`, `apps`,
`custom_apps`, `userdata`) — todos apontando para `/mnt/data/nextcloud` — mas
**não** declarava nada para `/var/www/html`, onde mora o código da aplicação.

A imagem `nextcloud:33-apache` tem `VOLUME /var/www/html` no seu `Dockerfile`.
Quando um caminho declarado como `VOLUME` não tem volume correspondente no
compose, o Docker cria um **volume anônimo** — atrelado àquele container
específico, com nome gerado (64 caracteres hexadecimais).

Em 2026-07-28, durante a recriação da rede `proxy` (ADR-011), a stack `cloud`
passou por `docker compose down` + `up -d`. O container novo recebeu um volume
anônimo **novo e vazio**. A partir daí:

1. O entrypoint verificou `/var/www/html/version.php` — ausente — e concluiu
   `New nextcloud instance`
2. Copiou o código de `/usr/src/nextcloud` para o volume
3. Rodou `php occ maintenance:install`
4. O `occ` respondeu **`Command "maintenance:install" is not defined`** — porque
   o `config.php` (bind mount, preservado) mostra a instância como já instalada,
   e o comando de instalação só existe em instâncias novas
5. O entrypoint entrou em loop: `Retrying install...`, indefinidamente

Resultado: Nextcloud fora do ar, com **todos os dados íntegros** — banco,
`config.php`, `userdata`, apps. Só o código não estava onde o entrypoint
esperava. O NPM devolvia `502`.

A recuperação na hora foi um `docker restart`: na segunda subida o volume já
estava populado (passo 2), o entrypoint enxergou a instalação existente e subiu
o Apache normalmente.

## Decisão

Declarar um volume **nomeado** para `/var/www/html`:

```yaml
services:
  nextcloud:
    volumes:
      - nextcloud_html:/var/www/html
      - /mnt/data/nextcloud/config:/var/www/html/config
      - /mnt/data/nextcloud/apps:/var/www/html/apps
      - /mnt/data/nextcloud/custom_apps:/var/www/html/custom_apps
      - /mnt/data/nextcloud/userdata:/var/www/html/data

volumes:
  nextcloud_html:
```

Volumes nomeados sobrevivem a `docker compose down` e são reatados na recriação
do container, ao contrário dos anônimos.

## Justificativa

**Por que um volume e não um bind mount:**
Só código da imagem vive nesse caminho — nada que precise ser inspecionado ou
versionado do lado do host. Um volume nomeado é gerenciado pelo Docker, é
recriável a partir da imagem, e mantém a distinção clara: `/mnt/data/nextcloud`
é *dado*, o volume é *código*.

**Por que os bind mounts aninhados continuam funcionando:**
O Docker ordena montagens por profundidade de caminho — `/var/www/html` é
montado primeiro, e `config`, `apps`, `custom_apps` e `data` são montados por
cima. A ordem no YAML é irrelevante.

**Por que não deixar como estava, já que reboot não quebra:**
Reboot de fato não dispara o bug — containers são *reiniciados*, não recriados,
e o volume anônimo persiste. Mas `docker compose down` é operação de rotina
(recriar rede, mudar compose, migrar host), e o modo de falha é péssimo: o
serviço fica fora do ar tentando **instalar por cima de uma instância
existente**, com uma mensagem de erro (`maintenance:install is not defined`) que
não sugere nem de longe a causa real.

**Por que o `nextcloud-notify-push` não recebeu o mesmo tratamento:**
Ele roda a mesma imagem, mas seu entrypoint é o binário
`custom_apps/notify_push/bin/aarch64/notify_push` — nunca o
`docker-entrypoint.sh`. Não faz verificação de instalação e não lê nada de
`/var/www/html` fora dos bind mounts de `config` e `custom_apps`. O volume
anônimo dele é inerte.

## Consequências

**Positivas:**
- `docker compose down` na stack `cloud` deixou de ser uma operação de risco
- Validado com `docker compose up -d --force-recreate nextcloud`: zero
  ocorrências de `New nextcloud instance`, volume preservado, HTTP 200

**Atenção:**
- Na primeira aplicação, o volume nomeado nasce vazio e o bug se manifestaria
  uma última vez. Para evitar, pré-popule a partir da imagem antes de recriar:
  ```bash
  docker volume create cloud_nextcloud_html
  docker run --rm -v cloud_nextcloud_html:/dest nextcloud:33-apache \
      sh -c 'cp -a /usr/src/nextcloud/. /dest/'
  ```
- Os volumes anônimos antigos continuam no disco como `dangling`. Não rode
  `docker volume prune` sem revisar: outros serviços podem usar volumes
  anônimos com dados.
- Ao atualizar a versão maior do Nextcloud, o entrypoint faz o upgrade do código
  dentro deste volume normalmente — o comportamento não muda.
