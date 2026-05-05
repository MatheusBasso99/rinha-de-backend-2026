# Rinha de Backend 2026 — Detecção de Fraude com Busca Vetorial

Este projeto é a submissão para a **Rinha de Backend 2026** usando **Crystal lang 1.20.0**.

## Documentação canônica (sempre consultar)

- **Repositório oficial**: https://github.com/zanfranceschi/rinha-de-backend-2026
- **Docs do desafio (PT-BR)**: https://github.com/zanfranceschi/rinha-de-backend-2026/tree/main/docs/br
  - `README.md`, `API.md`, `ARQUITETURA.md`, `AVALIACAO.md`,
    `BUSCA_VETORIAL.md`, `DATASET.md`, `REGRAS_DE_DETECCAO.md`,
    `SUBMISSAO.md`, `FAQ.md`
- **Crystal lang API 1.20.1** (sempre referenciar antes de escrever código): https://crystal-lang.org/api/1.20.1/
  - Em qualquer dúvida sobre stdlib (`HTTP::Server`, `JSON`, `Channel`, `Fiber`,
    `Slice`, `Math`, `Compress::Gzip`, etc.), abrir a doc dessa versão.
  - Não inventar APIs; se houver dúvida, ler a página correspondente em
    `crystal-lang.org/api/1.20.1/`.

## Tema do desafio

Construir o módulo **`fraud-score`**: para cada transação, transformar o payload
em um vetor de **14 dimensões**, buscar os **5 vizinhos mais próximos** no
dataset de referência (3 milhões de vetores rotulados) e responder com
`approved` e `fraud_score = nº_de_fraudes / 5`. Threshold fixo: `0.6`.

## Endpoints (porta 9999)

- `GET /ready` → `2xx` quando a API está pronta.
- `POST /fraud-score` → recebe transação, devolve `{ "approved": bool, "fraud_score": number }`.

Contrato completo dos campos: `docs/br/API.md`.

## Vetorização (14 dimensões)

Ordem fixa, normalização via `clamp(x, 0.0, 1.0)` exceto índices 5 e 6 (que
podem ser `-1` quando `last_transaction == null`):

| idx | dimensão | fórmula |
|-----|----------|---------|
| 0 | `amount` | `amount / max_amount` |
| 1 | `installments` | `installments / max_installments` |
| 2 | `amount_vs_avg` | `(amount / customer.avg_amount) / amount_vs_avg_ratio` |
| 3 | `hour_of_day` | `hour(requested_at) / 23` (UTC) |
| 4 | `day_of_week` | `dow(requested_at) / 6` (seg=0, dom=6) |
| 5 | `minutes_since_last_tx` | `min / max_minutes` ou `-1` |
| 6 | `km_from_last_tx` | `km / max_km` ou `-1` |
| 7 | `km_from_home` | `km_from_home / max_km` |
| 8 | `tx_count_24h` | `tx_count_24h / max_tx_count_24h` |
| 9 | `is_online` | `1` ou `0` |
| 10 | `card_present` | `1` ou `0` |
| 11 | `unknown_merchant` | `1` se `merchant.id ∉ known_merchants` |
| 12 | `mcc_risk` | `mcc_risk[mcc]` (default `0.5`) |
| 13 | `merchant_avg_amount` | `merchant.avg_amount / max_merchant_avg_amount` |

Constantes em `resources/normalization.json`. MCCs em `resources/mcc_risk.json`.

## Dataset de referência

- `references.json.gz` — 3.000.000 vetores rotulados (`fraud` / `legit`),
  ~16 MB gzipado / ~284 MB descompactado.
- `mcc_risk.json` — risco por MCC (default `0.5`).
- `normalization.json` — constantes.

**Os arquivos não mudam entre testes.** Pré-processar no build/startup é
permitido e recomendado (formato binário, índice ANN, mmap, etc.) para tirar
custo do hot path.

## Decisão

1. Vetorizar payload (14 dims).
2. Buscar 5 vizinhos mais próximos (KNN exato, ANN — HNSW/IVF/VP-Tree —, ou
   qualquer técnica que mantenha precisão e p99 baixos).
3. `fraud_score = fraudes_entre_os_5 / 5`.
4. `approved = fraud_score < 0.6`.

## Restrições de infra

- ≥ 1 load balancer + ≥ 2 instâncias da API, **round-robin simples** (sem
  lógica de negócio no LB — não inspeciona payload, não responde, não decide).
- Submissão = `docker-compose.yml` na branch `submission`, imagens públicas,
  compatíveis com `linux/amd64`.
- Soma dos limites: **≤ 1 CPU e ≤ 350 MB RAM** entre todos os serviços.
- Network mode `bridge`. `host` e `privileged` proibidos.
- App responde em `localhost:9999`.

## Pontuação (resumo prático)

`final_score = score_p99 + score_det`, cada um em `[-3000, +3000]` →
total em `[-6000, +6000]`.

- **Latência (`score_p99`)**: `1000 · log₁₀(1000ms / max(p99, 1ms))`.
  Teto +3000 quando `p99 ≤ 1ms`. **Piso −3000 quando `p99 > 2000ms`.**
- **Detecção (`score_det`)**: `1000 · log₁₀(1/ε) − 300 · log₁₀(1 + E)`,
  onde `E = 1·FP + 3·FN + 5·Err`, `ε = E / N`.
  **Piso fixo −3000 quando `(FP+FN+Err) / N > 15%`.**

Implicações:
- Cada **10× mais rápido** vale +1000 pontos no `score_p99`. Otimizar abaixo
  de 1ms é inútil (satura).
- `Err` (HTTP ≠ 200) pesa 5 e ainda conta como falha bruta — em pânico,
  responder 200 com `{ approved: true, fraud_score: 0.0 }` é melhor que 500.
- O corte de 15% de falhas é rígido: passou disso, `score_det = −3000` e
  qualquer p99 fica anulado.
- Não usar payloads do teste (`test/test-data.json`) como dataset/lookup:
  proibido pelas regras.

## Submissão

- PR adicionando `participants/<github-user>.json` listando os repos.
- Repo precisa ser público; com branches `main` (código) e `submission`
  (apenas artefatos do compose).
- Para teste oficial: abrir issue no repo do desafio com `rinha/test [id]` na
  descrição. A engine roda, comenta resultado e fecha.

## Ambiente de teste oficial

Mac Mini Late 2014, 2.6 GHz, 8 GB RAM, Ubuntu 24.04 (`linux/amd64`).

## Diretrizes para colaboração neste projeto

- **Idioma**: PT-BR.
- **Performance é tudo**: zero-alocação no hot path, evitar GC pressure,
  pré-computar tudo que puder no startup (descomprimir e parsear o dataset
  para representação binária densa em `Slice(Float32)` ou similar).
- **Concorrência**: usar `Fiber`/`Channel` da Crystal; HTTP keep-alive;
  considerar `HTTP::Server` puro vs frameworks.
- **Memória apertada (350 MB total)**: 3M × 14 × 4 bytes ≈ 168 MB só para os
  vetores. Cuidar de overhead de objetos; preferir `Slice(Float32)` contíguo
  em vez de `Array(Array(Float64))`.
- **Decisões de algoritmo**: brute-force `O(N · D)` provavelmente não cabe no
  p99 alvo; considerar VP-Tree, HNSW, IVF ou quantização. Medir antes de
  complicar.
- **Antes de codar contra a stdlib**, abrir
  https://crystal-lang.org/api/1.20.1/ na classe/módulo correspondente.
- **Sem mocks no caminho crítico** que escondam custo real (parsing JSON,
  alocação, conversão Float).
