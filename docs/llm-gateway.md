# Using cmux with an LLM gateway (LiteLLM, Helicone, OpenRouter, …)

> Status: documentation + workaround for [#3317](https://github.com/manaflow-ai/cmux/issues/3317). The native `env_passthrough` feature is proposed there and not yet implemented; this page describes the **current** state and a **shell-wrapper** workaround that works today.

A growing number of cmux users front their LLM traffic with a local proxy/gateway like [LiteLLM](https://github.com/BerriAI/litellm), [Helicone](https://www.helicone.ai/), or [OpenRouter](https://openrouter.ai/) (used as a gateway). The gateway typically provides:

- Multi-provider failover (Anthropic → OpenRouter → Gemini → local Ollama)
- Auto-injected prompt caching (~90% savings on repeated system prompts)
- Centralized budget caps and rate limiting (often Redis-backed, surviving restarts)
- One key to rotate instead of N provider keys
- Unified observability (e.g. Langfuse) with per-call tags

The coding agents that cmux launches (Claude Code, Codex CLI, Gemini CLI) all support pointing at a custom base URL via env vars:

| Agent | Base URL env var | API key env var |
|---|---|---|
| Claude Code | `ANTHROPIC_BASE_URL` | `ANTHROPIC_API_KEY` |
| Codex CLI | `OPENAI_BASE_URL` | `OPENAI_API_KEY` |
| Gemini CLI | `GOOGLE_GENERATIVE_AI_BASE_URL` | `GEMINI_API_KEY` |

If the gateway is reachable from the agent process, all the gateway features above flow through transparently — the agent itself is unchanged.

## The current friction with cmux

cmux launches agents via internal launchers (`claudeTeams`, `codex`, `gemini`, …). Today these launchers do not have an explicit "preserve these env vars" mechanism, and cmux's wrapper logic can interact with parent-shell env in ways that prevent gateway vars from reaching the child reliably across all paths (split panes, restored sessions, claude-teams sub-agents).

The clean fix is the opt-in `env_passthrough` config proposed in [#3317](https://github.com/manaflow-ai/cmux/issues/3317). Until that lands, the workaround below works today.

## Workaround: shell wrapper

A small shell wrapper is shipped at `scripts/cmux-with-gateway.sh`. It reads gateway config from a single env file (default: `~/.cmux/gateway.env`), exports the variables, then `exec`s the real `cmux` binary so cmux inherits the gateway env from its parent process.

### 1. Drop your gateway config in `~/.cmux/gateway.env`

```bash
# ~/.cmux/gateway.env
ANTHROPIC_BASE_URL=http://localhost:4000
ANTHROPIC_API_KEY=sk-litellm-...

OPENAI_BASE_URL=http://localhost:4000/v1
OPENAI_API_KEY=sk-litellm-...

GOOGLE_GENERATIVE_AI_BASE_URL=http://localhost:4000
GEMINI_API_KEY=sk-litellm-...
```

Permissions: this file holds your gateway master key. `chmod 600 ~/.cmux/gateway.env`.

### 2. Use the wrapper instead of `cmux` directly

```bash
./scripts/cmux-with-gateway.sh                    # launches cmux normally
./scripts/cmux-with-gateway.sh sessions list      # forwards args
./scripts/cmux-with-gateway.sh claude-teams ...   # works for any subcommand
```

Optionally alias it:

```bash
alias cmux=$HOME/path/to/cmux/scripts/cmux-with-gateway.sh
```

### 3. Verify

Inside a fresh cmux pane:

```bash
echo "$ANTHROPIC_BASE_URL"
# → http://localhost:4000
```

If you get an empty line, your wrapper isn't being used or the file isn't being sourced — `./scripts/cmux-with-gateway.sh --debug` prints what it loaded.

## What this workaround does *not* fix

- **Sub-agent / claude-teams paths** that re-spawn the agent through cmux's internal wrapper logic may still drop gateway env vars depending on how the spawn chain looks. The native fix in [#3317](https://github.com/manaflow-ai/cmux/issues/3317) is required for this to be robust end-to-end.
- **`NODE_OPTIONS` interaction** — if your gateway client also injects `NODE_OPTIONS` (some do, some don't), see [#2841](https://github.com/manaflow-ai/cmux/issues/2841).
- **Per-launcher exclusion** — the wrapper exports the env globally; you can't say "Codex yes, Claude no" with this approach. The native config in #3317 supports per-launcher granularity.

## Recommended companion features

These are tracked in the same proposal series and complement gateway routing:

- **Per-session caps** ([#3318](https://github.com/manaflow-ai/cmux/issues/3318)) — kill runaway sessions before they burn the gateway's monthly budget.
- **Auto-tagging** ([#3319](https://github.com/manaflow-ai/cmux/issues/3319)) — surface cmux project/workspace/tab as gateway tags so cost dashboards segment correctly.
- **Model-tier policy** ([#3326](https://github.com/manaflow-ai/cmux/issues/3326)) — declarative per-project model assignment, ideal once gateway aliases (`fast`, `code`, `cheap`) are in play.

## See also

- [#3317](https://github.com/manaflow-ai/cmux/issues/3317) — native `env_passthrough` proposal (this doc is the workaround until it lands).
- [#2841](https://github.com/manaflow-ai/cmux/issues/2841) — `NODE_OPTIONS` preservation.
- [LiteLLM proxy quick-start](https://docs.litellm.ai/docs/proxy/quick_start)
- [Anthropic SDK base URL override](https://docs.anthropic.com/en/api/getting-started)
