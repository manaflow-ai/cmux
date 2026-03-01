---
name: ralphex-init
description: Guided setup for ralphex autonomous plan execution inside vibeshield. Creates .ralphex/config with essential settings. Use when the user wants to set up ralphex, configure plan execution, or run ralphex for the first time.
---

# ralphex Setup

Guide the user through configuring ralphex for this project.

## Prerequisites

Before starting, verify:
1. `ralphex --help` runs successfully (binary installed)
2. The project is a git repository (`git rev-parse --git-dir`)

If either fails, explain what's needed and stop.

## Instructions

### Step 1: Check for existing config

Check if `.ralphex/config` exists in the workspace root.

If it exists:
1. Show the current settings
2. Ask: "ralphex is already configured. Reconfigure or keep current setup?"
3. If keep, skip to Step 4.

### Step 2: Essential settings

Ask the user these questions:

**Question 1: External review tool**

Two authentication paths are available:

- **codex via OpenRouter (recommended)** — uses OpenAI Codex CLI with OpenRouter as the API provider. Requires `OPENROUTER_API_KEY` and `openrouter.ai` in the firewall allowlist. vibeshield's claw-wrap proxy injects the API key automatically — **no credentials stored in the container**. Works in all secrets modes (op-proxy, env-proxy, env-direct).

- **codex via direct OpenAI (env-direct only)** — uses Codex CLI with OpenAI directly. Requires `CODEX_API_KEY` or `codex login` inside the container, plus `api.openai.com` in the firewall allowlist. **WARNING: This path stores real credentials in the container (env var or auth.json on the codex volume). The claw-wrap proxy cannot protect these credentials because it cannot inject OpenAI auth headers without breaking codex's OAuth flow. Only use this in env-direct mode with a scoped API key and standard/lockdown firewall.**

- **none** — skip external review, use only Claude-based review agents

- **custom** — bring your own review script

#### If codex via OpenRouter is selected:

Warn:
> Codex via OpenRouter requires `openrouter.ai` in your firewall allowlist. Add it to `.devcontainer/network/config.local.yaml`:
> ```yaml
> additional_domains:
>   - openrouter.ai
> ```
> Then run `reload-firewall --mode standard` as root in the container.

Also verify codex has an OpenRouter provider configured. Check `~/.codex/config.toml` for:
```toml
model_provider = "openrouter"

[model_providers.openrouter]
name = "OpenRouter"
base_url = "https://openrouter.ai/api/v1"
env_key = "OPENROUTER_API_KEY"
```

If not present, offer to add it. The user should set `OPENROUTER_API_KEY` in their host environment or `.env.vibeshield`.

#### If codex via direct OpenAI is selected:

Warn:
> **Credential risk:** Direct OpenAI auth stores real credentials inside the container. The claw-wrap proxy cannot protect them. Mitigations:
> - Use a **scoped API key** with minimal permissions (not your org admin key)
> - Keep the firewall in **standard or lockdown mode** (limits exfiltration channels)
> - **Never use this with `--dangerously-skip-permissions` in open firewall mode**

Then guide:
1. Add `api.openai.com` to `.devcontainer/network/config.local.yaml` and reload the firewall
2. Inside the container, either:
   - Set `CODEX_API_KEY` in host env (forwarded automatically in env-direct mode), or
   - Run `codex login --device-auth` or `echo $KEY | codex login --with-api-key`
3. Auth persists on the codex volume across container restarts

**Question 2: Plans directory**
- Default: `docs/plans` (ralphex default)
- Let user specify a custom path if they prefer

**Question 3: Finalize step**
- Disabled (default) — plan completes after reviews
- Enabled — runs a post-review step (rebase, squash, etc.)

### Step 3: Write config

Create `.ralphex/config` with the user's choices:

```ini
# ralphex configuration for this project
# See: https://github.com/umputun/ralphex

external_review_tool = <codex|none|custom>
plans_dir = <docs/plans>
finalize_enabled = <false|true>
```

Also create the plans directory if it doesn't exist:
```bash
mkdir -p <plans_dir>
```

### Step 4: Summary

Show:
- Config file location: `.ralphex/config`
- How to create a plan: `ralphex --plan "description"` or create manually in the plans directory
- How to run: `./vibeshield --ralphex docs/plans/<plan>.md`
- How to run review-only: `./vibeshield --ralphex --review`
- Docs: https://github.com/umputun/ralphex

### Step 5: Add to .gitignore

Check if `.ralphex/progress/` is in `.gitignore`. If not, suggest adding:
```
.ralphex/progress/
```

The progress directory contains ephemeral execution logs that shouldn't be committed.
