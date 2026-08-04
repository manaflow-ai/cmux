# cmux-vault

`cmux-vault` discovers local coding-agent session transcripts and syncs them to
cmux Vault cloud storage. Round 1 supports Claude Code, Codex, and pi.

## Install

```bash
go build ./cmd/cmux-vault
```

## Commands

```bash
cmux-vault login
cmux-vault scan
cmux-vault sync
cmux-vault resume <session-id>
cmux-vault status
cmux-vault logout
```

`login` starts a device-code flow, prints a verification URL and user code, and
stores Stack Auth tokens in `~/.config/cmux-vault/auth.json` with mode `0600`.
`sync` uploads changed transcripts directly to S3-compatible object storage via
presigned URLs. `resume` restores a missing transcript from cloud storage and
prints the command the agent expects.

Useful flags:

```bash
cmux-vault --json scan
cmux-vault sync --agent codex --dry-run
cmux-vault sync --limit 25
cmux-vault resume --agent claude <session-id>
cmux-vault resume --force <session-id>
```

## Environment

- `CMUX_VAULT_API_BASE`: web API base URL. Defaults to `https://cmux.com`.
- `CMUX_VAULT_CONFIG_DIR`: override the auth token directory.
- `CMUX_VAULT_STATE_DIR`: override the sync state directory.
- `CLAUDE_CONFIG_DIR`: override Claude Code config discovery.
- `CODEX_HOME`: override Codex discovery.

Default local state lives in `~/.local/state/cmux-vault/state.json`.
