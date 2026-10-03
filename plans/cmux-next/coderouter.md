# cmux next: CodeRouter and provider accounts

CodeRouter is cmux's hosted model router (web/services/coderouter/README.md). It holds a team's provider accounts (ChatGPT/Codex sign-ins, OpenAI and OpenRouter keys, Claude Code OAuth tokens, Anthropic keys, Bedrock keys) encrypted with AWS KMS, and serves the OpenAI Responses and Anthropic Messages APIs to cmux Cloud machines, the `cr` CLI and `crk_` API keys, failing over between the team's accounts. The control plane is `/api/coderouter/*`.

## What cmux-next has (2026-09-30)

| Piece | Where |
| --- | --- |
| Presence-only detection of local sign-ins and keys | `CmuxNextCodeRouter/Detection` |
| CodeRouter control-plane client (list, add, remove), Stack-authenticated like `/api/vm` | `CmuxNextCodeRouter/API` |
| Pasted-key Keychain store (`<bundle id>.ai-provider-keys`) | `CmuxNextCodeRouter/Keychain` |
| Row state machine (detect, re-authenticate, connect, remove) | `CmuxNextCodeRouter/Rows` |
| Accounts screen: Settings > Accounts, onboarding step body | `CmuxNextAccounts` |
| Actions: `accounts.show/refresh/reauthenticate/connect/remove` (palette, `cmux accounts …`) | `ActionCatalog+Accounts`, `AccountsHandlers` |
| Socket: `accounts.list`; the shipped CLI's `coderouter.claude_upstream.*`, `coderouter.machines`, plus `coderouter.accounts.list` | `AppControl+Accounts` |
| Bundled `coderouter` CLI (`cmux cr …`, other `cmux coderouter …` verbs) | `scripts/install-coderouter-client.sh` from `scripts/reload.sh` (unchanged) |

Not ported: the native handoff lease (`crh_` -> `crt_`). Its server half is PR 10118 and its client half PR 10194; both are open and unmerged on main. The app needs no handoff for its own calls: it talks to the control plane with the Stack session. The bundled CLI keeps its own `cr login`.

Providers CodeRouter cannot hold (Gemini, Groq, xAI, Mistral, DeepSeek, Vertex, Copilot, Ollama, LM Studio) show detection and Re-authenticate only.

## Threat model

**What cmux reads.** Detection reads, off the main actor, only on refresh: `~/.codex/auth.json` (or `$CODEX_HOME`), `~/.claude/.credentials.json` and `~/.claude.json` (or `$CLAUDE_CONFIG_DIR`), `~/.gemini/{oauth_creds,google_accounts}.json`, the section names of `~/.aws/{credentials,config}`, gcloud ADC or `$GOOGLE_APPLICATION_CREDENTIALS`, `~/.config/github-copilot/{apps,hosts}.json`, environment variable presence in the captured login-shell environment, and Keychain items `Claude Code-credentials` / `Codex Auth` by attributes only (no `kSecReturnData`, interaction not allowed, so no prompt and no secret). Ollama (`$OLLAMA_HOST` or 127.0.0.1:11434) and LM Studio (127.0.0.1:1234) get one loopback GET with an 800 ms deadline. Files that hold tokens are parsed in memory; only an email, a plan or organization name, a profile name, a credential type or a service-account email (all non-secret) leave the detector. JWT claims are decoded without verification and only for those fields.

**Where secrets live.** Provider CLIs keep their own stores. A key the user pastes goes to the macOS Keychain (one generic password per provider, `AfterFirstUnlockThisDeviceOnly`) or straight to CodeRouter; never to cmux.json, a log, analytics or the UI (secure field, cleared on close). Connect reads a secret only on an explicit click (or `cmux accounts connect`), for one HTTPS request, and drops it. Every credential type has a redacted `description`. Server error text is taken from its `message` field, which never echoes a credential. The Stack token pair is fetched per request and never cached (architecture.md 1). No action or CLI argument carries a secret; a provider that needs a pasted value opens its paste field. The legacy CLI path `cmux coderouter claude add` still sends a token over the local socket (CLI -> app -> backend), as before; the socket is the app's authenticated control socket.

**Who can use a linked account.** New accounts are added `private` (importer only). In a personal scope the importer's personal Cloud machines use it; in an organization nothing but the importer's own route tokens use it until it is shared from the dashboard ("Share with team"). Shared accounts are usable by every team member's route tokens, the team's `crk_` keys and the team's machines in the account's pool. Every team member may rename, disable, transfer and remove shared accounts.

**VM token scope.** Machine credentials get no account rights (Lawrence, 2026-10-03; cmux-next-spec `cloud-and-automations.md` and `identity-and-permissions.md` section 4): a VM-bound route token, a chatmux machine token or a `crk_` key is refused by the control plane (`resolveCoderouterControlContext`, 403 `machine_token_cannot_manage_accounts`). It cannot list for management, import, update, share or remove accounts; it only uses the accounts its VM pool grants for model requests. Accounts are added from a signed-in cmux app or the dashboard.

**Residual risks.** (1) Re-authenticate types a fixed command (`codex login`, `claude auth login`, `gemini`, `aws sso login`, `gcloud auth application-default login`, `gh auth login --web`) into a new terminal tab; the user's shell resolves the binary from PATH, so a shadowed binary runs. (2) Connecting Codex uploads the CLI's refresh token; CodeRouter then refreshes it, and the local CLI may need `codex login` again if the provider rotates the token. (3) The login-shell environment is captured once per launch; a key exported later is seen only after relaunch.
