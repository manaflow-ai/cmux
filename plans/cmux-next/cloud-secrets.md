# Cloud secrets (Capy-style scopes) for cmux Cloud NEXT

Goal: repo and environment variables and secrets with shared, personal and per-chat scopes, injected into a
Cloud chat's machine at boot, values never shown to the agent, Claude setup tokens supported, and encryption
behind a provider interface with Azure Key Vault as the production KMS. Reference: https://docs.capy.ai/secrets.

## What existed

- cmux-platform Cloud environments (`/v1/cloud-environments`): personal and team environments with plain
  variables and **routed secrets** (the egress proxy puts the value in headers toward its hosts; the machine never
  holds it), per-repo project defaults, values sealed with a Worker-secret keyring, boot injection into
  `~/.config/cmux/machine.env`, and no agent token may set a secret.
- cmux: `cmux cloud secret set NAME` keeps values in this Mac's Keychain; `cmux cloud deliver-secrets` seals the
  names a machine's `.cmux/machine.toml` declares with HPKE to the machine's daemon key.
- A standing rule: cmux keeps no Claude or ChatGPT subscription login on its servers
  (cmux-platform `test/node/no-harness-logins.test.ts`).

## Design

| Capy | cmux Cloud NEXT |
|---|---|
| Shared (project) | team environment variables and routed secrets; repo picks its environment by project default |
| Personal | personal environments, plus **personal values** over any environment (new) |
| Thread | **chat values** for one chat's machine and its subagents (new), delivered to the running machine at once |
| Encrypted at rest | envelope per value; data key wrapped by a `KeyEncryptionProvider`: keyring, dev stub, Azure Key Vault (new) |
| Agent sees names only | values are write-only on every route; names and times only; person tokens only |
| Protected file sourced by shells | `~/.config/cmux/machine.env` (0600), written over exec stdin; digest skips unchanged writes |
| Setup tokens | `CLAUDE_CODE_OAUTH_TOKEN` stays in the Mac Keychain and goes to every Cloud machine (new); the server refuses it |

Precedence, low to high: environment variables, the machine creator's personal values, the chat's values.

## Work

1. cmux-platform ([manaflow-ai/cmux-platform#1529](https://github.com/manaflow-ai/cmux-platform/pull/1529)):
   `crypto/KeyProvider.ts` (interface, keyring, dev stub, Azure Key Vault), `SecretSealer` on the provider,
   `environments/ScopedValues.ts` (store, sealing, layering, name rules), routes
   `/v1/cloud-environments/{id}/personal-values` and `/v1/workspaces/{workspace}/machine/values`, inject() layering,
   chat values dropped with the machine, `docs/cloud-secrets.md` with the Azure resources and credentials.
   Done; tests pass; not merged.
2. cmux (this branch): the Claude setup token is always delivered to the person's Cloud machines when the Mac
   holds a global `CLAUDE_CODE_OAUTH_TOKEN` (`CloudMachineSecrets.alwaysDelivered`), CLI help, and
   `docs/cmux-next/cloud-secrets.md`. Done; not merged.
3. After (1) lands and `cmux-cloud-client/openapi.json` is synced (`scripts/update-spec.sh`): `cmux cloud values
   personal|chat set|ls|rm` on the generated client (a hand-written route fails `hand_written_routes.rs`), the
   Settings page's Personal tab per environment, and the composer's "Environment variables" dialog for chat values.
4. Azure (needs the person): the Key Vault, key, service principals and role assignments listed in
   cmux-platform `docs/cloud-secrets.md#azure-key-vault`, then `SECRETS_KEY_PROVIDER=azure-key-vault` and the
   `AZURE_*` settings per deployment, development first.

## Not doing

- Revealing a value in the UI (Capy's eye toggle): any route that answers a value is a route an agent's token
  could reach; names only until a person-only, re-authenticated reveal exists.
- Output masking on the machine: like Capy, a command that prints a value puts it in the transcript.
