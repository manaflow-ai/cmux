# Cloud secrets

Variables and secrets are input for a Cloud chat's machine, not for its agent. You set them; cmux seals them and
writes them to the machine when it starts. Agents learn names, never values, and no agent can set one. Anything
running on the machine can read a value written there, so give agents scoped, revocable credentials, and prefer a
routed secret (sent only to its hosts by the network, never on the machine) for API keys.

## Scopes

| Scope | Where | Applies to | Wins over |
|---|---|---|---|
| Shared | a team Cloud environment's variables and secrets | every chat on that environment | nothing |
| Personal | your own environments, and your personal values on any environment | chats you start | shared |
| Chat | one chat's values | that chat's machine and its subagents | both |

A repository picks its environment through its default (yours, then your team's, then the Default).

Personal and chat values are write-only: the app and API list names, never values. Shared and personal changes
apply when a machine next starts; a chat value reaches the running machine at once. Processes already running
keep their environment until they restart. Chat values are deleted with the machine.

The API (cmux-platform `docs/cloud-secrets.md`):

```
GET|PATCH /v1/cloud-environments/{id}/personal-values   {"set":[{"name":"DATABASE_URL","value":"..."}],"remove":["OLD"]}
GET|PATCH /v1/workspaces/{workspace}/machine/values      same body; answers "delivered": true when written now
```

## Claude setup token

`claude setup-token` prints a long-lived Claude Code token. Keep it on your Mac:

```
claude setup-token          # sign in, copy the token it prints
cmux cloud secret set CLAUDE_CODE_OAUTH_TOKEN   # paste it at the hidden prompt
```

It goes into this Mac's Keychain. `cmux cloud deliver-secrets --target machine:<id>` (also a step of `cmux vm ready`)
seals it to the machine's daemon key and writes it to `~/.config/cmux/machine-secrets.env` there, whether or
not the machine's `.cmux/machine.toml` declares it, so Claude Code on the machine is signed in as you. cmux never
stores it on its servers: the platform refuses `CLAUDE_CODE_OAUTH_TOKEN` as a personal or chat value. Remove it
with `cmux cloud secret rm CLAUDE_CODE_OAUTH_TOKEN`.

## Encryption

Each value has its own AES-256-GCM data key, bound to its team, scope and name. A key-encryption provider wraps
the data key: the deployment keyring today, Azure Key Vault once configured, a public stub in local development.
Records sealed with the keyring keep opening after a move to Azure.
