# Rinha de Backend 2026 — `rinha_de_backend`

Submissão para a [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026) escrita em **Crystal 1.20.0**.

## O que é

Implementa o módulo `fraud-score`: vetoriza cada transação em **14 dimensões**, busca os **5 vizinhos mais próximos** sobre 3 milhões de referências rotuladas e responde com `approved` e `fraud_score = frauds_in_top5 / 5`. Ver [`CLAUDE.md`](./CLAUDE.md) para o contrato completo e as decisões de projeto.

## Stack

- **Linguagem**: Crystal 1.20.0 (binário estático Alpine, `linux/amd64`)
- **HTTP**: `TCPServer` cru + parser HTTP 100% Crystal (sem framework, sem `picohttpparser`)
- **Busca vetorial**: índice IVF (`k=1024`, `nprobe=16`) com quantização Int16, mmap sobre `references.bin`
- **Load balancer**: nginx 1.27 alpine (round-robin puro, sem lógica de negócio)
- **Topologia**: 1 LB + 2 instâncias da API, totalizando **1 CPU / 350 MB**

## Endpoints (porta 9999)

- `GET /ready` — `2xx` quando a API está pronta.
- `POST /fraud-score` — recebe a transação, devolve `{ "approved": bool, "fraud_score": number }`.

Ver [docs/en/API.md](https://github.com/zanfranceschi/rinha-de-backend-2026/blob/main/docs/en/API.md) para o contrato dos campos.

## Como rodar

### Local (sem Docker)

```sh
# Pré-processa references.json.gz → references.bin (uma vez, vários minutos)
crystal run --release src/preprocess.cr -- resources/references.json.gz resources/references.bin

# Sobe a API isolada na porta 9999
make release
./rinha_de_backend
```

### Stack completa (LB + 2 APIs, igual à oficial)

```sh
docker compose up --build
curl -s http://localhost:9999/ready
```

O build do Docker já roda o `preprocess` se `resources/references.bin` não estiver no contexto.

## Testes

```sh
make spec
```

Specs cobrem o parser HTTP/JSON, vetorizer, KNN/IVF e referências.

## Layout

```
src/
  main.cr            entrypoint
  http_server.cr     TCPServer + keep-alive
  http_parser.cr     parser HTTP via memchr
  json_parser.cr     parser JSON zero-alloc
  vectorizer.cr      payload → Slice(Float32) de 14 dims
  ivf.cr / knn.cr    índice IVF + busca dos top-5
  preprocess.cr      gz → references.bin
resources/
  normalization.json constantes
  mcc_risk.json      risco por MCC
  references.bin     dataset binário (gerado, gitignored)
spec/                testes
tools/               validações offline (recall, quantização, pruning)
```

## Estrutura do repositório (Rinha)

- `main` — código-fonte (esta branch).
- `submission` — apenas `docker-compose.yml` apontando para imagem pública, `nginx.conf` e `info.json`.

## Licença

MIT — ver [`LICENSE`](./LICENSE).
