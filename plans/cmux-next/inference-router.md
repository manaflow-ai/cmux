# cmux inference router: providers, allowlist, our own billing (2026-10-28)

User 2026-10-28: Vercel AI Gateway is funded and goes first. Use DeepSeek only for now: the 10/17
build, with image input. Support Vercel, OpenRouter, Cloudflare, Azure, OpenAI and our own
endpoint. Use OIDC for Vercel. Bill through our own records.

## Shape

One OpenAI-compatible endpoint in the cmux API Worker (`backend/apps/api/src/inference`):
`POST /v1/inference/chat/completions` and `GET /v1/inference/models`. It has the same request shape
as Cloudflare AI Gateway's unified `/compat/chat/completions`. The Worker owns auth, the model
allowlist, caps, failover and metering. Providers are adapters (`providers.ts`):

| Provider | How | Secret |
| --- | --- | --- |
| `vercel` | Through the dashboard's OIDC relay (`POST /api/ai-gateway/chat/completions` on console[-staging].cmux.dev). The relay calls AI Gateway with the call's Vercel OIDC token. A static gateway key is the fallback. | `INFERENCE_VERCEL_RELAY_KEY` (Worker and dashboard) |
| `openrouter` | Direct, `usage.include`, `data_collection: deny`, `max_price` = card | `INFERENCE_OPENROUTER_KEY` |
| `workers-ai` | AI binding through Cloudflare AI Gateway `cmux-ai-proxy` (`INFERENCE_CF_GATEWAY_ID`) | none |
| `azure` | Azure AI Foundry Models v1 endpoint, `api-key` header, deployment `deepseek-v4.1-flash` | `INFERENCE_AZURE_KEY` |
| `openai` | api.openai.com. `max_tokens` is sent as `max_completion_tokens`. | `INFERENCE_OPENAI_KEY` |
| `custom` | Our own OpenAI-compatible URL | `INFERENCE_CUSTOM_URL`/`_KEY` |

- Order: `INFERENCE_PRIMARY_PROVIDER` (staging and production: `vercel`) comes first, then the
  cheapest list price. The router fails over to the next provider only before the first byte.
- Allowlist: `INFERENCE_MODEL_ALLOWLIST` (staging and production:
  `deepseek/deepseek-v4.1-flash-1017`). Any other model gets 403 `model.not_allowed`, and the
  error names the allowed ids. `/models` lists only the allowlisted ids.
- Images: `image_url` parts are accepted only for models with `vision`. The limit is 8 per
  request. Before usage is known, each image is reserved at 4,096 tokens, so the hold stays an
  upper bound. The free tier accepts text only.
- Request checks: `chat-request.ts`, one Effect program with a typed `ChatRefused` error.
- Billing: our own records. The flow is unchanged: a team plan or prepaid credits are held per
  request on UsageMeterDO. The hold is settled at the provider's reported cost, or at the card
  price when the provider reports no cost. SpendGuardDO enforces the per-provider daily caps
  (fail closed). Provider billing is never the source of truth.

## Model ids (DeepSeek V4.1 Flash, 10/17 build, vision)

| Provider | Id |
| --- | --- |
| Vercel AI Gateway | `deepseek/deepseek-v4.1-flash-1017` |
| OpenRouter | `deepseek/deepseek-v4.1-flash-1017` |
| Cloudflare Workers AI | `@cf/deepseek-ai/deepseek-v4.1-flash-1017` |
| Azure AI Foundry | no 1017 build; `DeepSeek-V4.1-Flash` 2026-09-10 is the newest (route is last) |

## Azure

Azure AI Foundry Models is Azure's closest match to OpenRouter: many vendors' models (DeepSeek,
Llama, Mistral, OpenAI) behind one endpoint and one bill, paid per token. Azure API Management's AI
gateway is only a policy proxy (keys, token quotas, logging) that sits in front of Foundry or Azure
OpenAI. It would repeat what this Worker already does, and it adds a fixed monthly cost. So the
router calls Foundry directly.

## Staging results (commit d6623d8, staging e2e account, one red-PNG image request and one SSE request per provider, pinned with `x-cmux-provider`)

| Provider | Image (answer "Red") | ms | tokens in/out | SSE | ms |
| --- | --- | --- | --- | --- | --- |
| auto (Vercel first) | 200 via vercel | 3636 | 224/50 | 200, 19 chunks | 1596 |
| Vercel (OIDC relay) | 200 | 3605 | 224/170 | 200, 22 chunks | 2129 |
| OpenRouter | 200 | 2023 | 198/203 | 200, 21 chunks | 1612 |
| Workers AI via CF AI Gateway | 200 | 2043 | 224/28 | 200, 4 chunks | 3811 |
| Azure AI Foundry | 200 | 2112 | 198/2 | 200, 5 chunks | 1569 |

`openai/gpt-oss-120b` gets 403 `model.not_allowed`. `/models` lists only the 1017 model
(`vision: true`). The relay log shows the Vercel calls. The prepaid ledger charged them.
