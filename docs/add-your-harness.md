# Add your harness

cmux runs coding agents ("harnesses") such as Claude Code, Codex, OpenCode, Pi and Gemini CLI.
You can add any other harness, for example your company's internal agent, with one TOML file.
No cmux code changes and no restart: cmux reloads the file when it changes, and the harness
appears in the model picker.

The fastest path is to let an agent do it: open the command palette, run **Integrate a Harness
with an Agent…** (or **Integrate a harness** on the New Tab page). That starts a chat that runs
`cmux harness guide` and follows it: it writes the profile, runs the doctor and fixes what the
doctor reports. The rest of this page is the same information for people.

## Every way in

All of these run the same daemon operations, so a profile added in one place shows in all of them.

| Where | Add | Check | Remove |
| --- | --- | --- | --- |
| Settings > Agents > Agent Harnesses | **Add Agent…**: a tab for the ACP Registry (one click per agent) and a tab for a custom command | **Check** on a row: each doctor step with its fix | **Remove** on your own profiles, then **Undo** |
| Model picker | the **+** at the bottom of the harness rail opens Settings > Agents > Add | | |
| Command palette (Cmd-Shift-P) | **Add ACP Agent…**, **Add Agent from ACP Registry…** | **Check Agent…** | **Remove Agent…**, **Restore Removed Agent** |
| CLI (app actions) | `cmux agent add-harness --arg command=acme-agent` or `--arg registry=goose` | `cmux agent check-harness --arg id=acme` | `cmux agent remove-harness --arg id=acme`, `cmux agent restore-harness` |
| MCP (`cmux mcp serve`) | `app_agent_add_harness` | `app_agent_check_harness` | `app_agent_remove_harness`, `app_agent_restore_harness` |
| acpmux CLI (no app needed) | `cmux harness add`, `cmux harness add ID --registry` | `cmux harness doctor ID` | delete the file |
| Icon | Settings > Agents: **Icon…** on your profile; `cmux harness icon ID VALUE`; `_acpmux/harness/icon` | `cmux harness icon ID` | `cmux harness icon ID --clear` |

Secrets never pass through Settings or the app actions: a custom command names env keys, the
profile reads each from the Keychain item of the same name (`keychain:KEY`), and
`cmux harness secret set ID KEY` stores the value. Remove moves your profile file aside; Undo (or
`cmux agent restore-harness`) puts it back. Built-in, managed and cmux.json harnesses cannot be
removed there.

## The loop

```sh
cmux harness add acme --command acme-agent      # ACP harness: writes ~/.config/cmux/harnesses/acme.toml
cmux harness add acme --command acme --protocol terminal   # a CLI/TUI without ACP
cmux harness add --example codex                # start from a shipped example
cmux harness add acme --example anthropic-endpoint --base-url https://llm.example.com --model m1
$EDITOR ~/.config/cmux/harnesses/acme.toml
cmux harness doctor acme                        # repeat until every step passes
cmux harness list                               # every harness, its source and its problems
```

`cmux harness doctor ID` validates the file, resolves the program on your login `PATH`, resolves
env references (a missing Keychain item is named, never printed), runs the auth check, then
starts the harness in a fresh temporary folder and runs the ACP handshake: `initialize`,
`session/new` and one prompt ("Reply with the single word OK."). Each step prints PASS, WARN or
FAIL with a `fix:` line. `--no-prompt` stops before the prompt (no model call); `--timeout S`
sets the wait per step (default 120). For a `terminal` harness the doctor only checks that the
program starts. For a `claude-stdio` harness (Claude Code through acpmux's own adapter) the prompt
is one `claude -p` turn with the profile's env.

Examples ship in `cmux-tui/crates/acpmux/harnesses/`: `claude.toml`, `codex.toml`,
`opencode.toml`, `pi.toml`, `gemini.toml` and `aider.toml` (terminal).

## Where cmux looks

1. Managed folder, for companies: `/Library/Application Support/cmux/harnesses/` (macOS),
   `/etc/cmux/harnesses/` (Linux). A managed profile wins over a user file with the same id.
2. Your folder: `~/.config/cmux/harnesses/` (or `$XDG_CONFIG_HOME/cmux/harnesses/`).
   A DEV build uses `harnesses/` in its own acpmux home instead (`~/.acpmux/builds/<build>/`,
   or the old `~/.acpmux/tags/<tag>/`), so a test harness never shows in NIGHTLY, cmux NEXT or
   release. An explicit `XDG_CONFIG_HOME` still wins.
3. `~/.config/cmux/cmux.json`, key `agents.harnesses.<id>`, with the same keys as JSON.
4. A repository or workspace: `<folder>/.cmux/harnesses/<id>.toml`. Never loaded on its own;
   see [Folder profiles](#folder-profiles).

`cmux harness reload` tells the running daemon to read the files again. You rarely need it:
the daemon watches these folders and cmux.json (no polling) and reloads on a change.

## Schema (schema 1)

The file name is the id: `acme.toml` holds `id = "acme"` (lowercase letters, digits and `-`,
at most 40 characters). Unknown keys are errors, so a typo shows in the doctor with its line.
The file must be writable only by you (`chmod 600`).

```toml
schema = 1
id = "acme"
name = "Acme Agent"             # display name
description = "Acme's internal coding agent"
icon = "acme.svg"               # file next to the profile (svg/png, <= 256 KB), one emoji ("🦊"),
                                # an SF Symbol ("hammer.fill"; "sf:NAME" forces one), an agent
                                # mark (claude, openai, gemini, goose, amp, ...), terminal or generic
protocol = "acp"                # acp (default) | terminal | claude-stdio
command = "acme-agent"          # program on PATH, or an absolute path (no spaces, no arguments)
args = ["acp", "--model", "${model}"]   # ${model} = the chosen model, ${cwd} = the chat folder
family = "acme"                 # optional; groups profiles for `-m acme`
fallback = "acme-backup"        # optional; the profile to move to on a usage limit
hooks = "claude"                # optional; a hook-capable agent whose status hooks to use

[env]
ACME_REGION = "us-east-1"                                       # plain value
ACME_API_KEY = { keychain = "cmux-harness/acme/ACME_API_KEY" }  # Keychain item
ACME_HOME = { env = "ACME_HOME" }                               # from your login environment

[defaults]
model = "acme-large"
effort = "medium"               # none minimal low medium high xhigh max
policy = "ask"                  # ask approve-reads approve-edits approve-all deny-all

[capabilities]                  # what the picker offers; the live ACP options still win
effort = ["low", "medium", "high"]
fast = false
permission_modes = true
resume = true

[models]                        # a static list ...
list = [
  { id = "acme-large", name = "Acme Large", short_name = "Large", family = "Acme", efforts = ["low", "medium", "high"], default_effort = "medium", fast = false, context_window = 200000 },
  "acme-small",
]
# command = ["acme-agent", "models", "--json"]   # ... or a command that prints them

[auth]                          # shown by the doctor and the picker; never secrets
login = "acme-agent login"
docs = "https://acme.example/agent/setup"
check = ["acme-agent", "whoami"]   # exit 0 = logged in

[sessions]                      # where its chats are, for the cmux Chats list
adapter = "jsonl"               # jsonl | json | sqlite, or a built-in:
                                # claude-code codex opencode pi gemini cursor-agent amp aider
roots = ["${ACME_HOME:-~/.acme}/sessions"]
files = "*/*.jsonl"
[sessions.fields]
id = "file.stem"
title = ["last:/title", "first:/message/content"]
cwd = "first:/cwd"
updated = "file.mtime"
[sessions.resume]
argv = ["acme-agent", "--resume", "{id}"]
cwd = "{cwd}"
```

Each `{ ... }` model entry stays on one line (TOML inline tables).

## Icons

Every harness has an icon in the model picker, New Tab, Home, subagent rows, Settings, its chats'
tabs and its workspaces' sidebar rows.
Set your own from the CLI or from Settings > Agents (**Icon…** on your profile's row: type a value,
choose or drop a PNG or SVG, or **Automatic**):

```sh
cmux harness icon acme 🦊                 # one emoji
cmux harness icon acme hammer.fill        # an SF Symbol
cmux harness icon acme goose              # an agent's mark
cmux harness icon acme ~/Pictures/acme.svg   # copied next to the profile as acme.svg
cmux harness icon acme --clear            # back to automatic
cmux harness icon acme                    # what cmux shows now, and why
cmux harness add acme --command acme-agent --icon 🦊
```

Without an `icon` line cmux picks one: the mark of the agent the harness runs, read from its id
(`claude-work`), its program (`codex-acp`), the package a runner starts (`npx -y
@google/gemini-cli` is Gemini; also `bunx`, `pnpm dlx`, `uvx`, `pipx run`) or its family; else
`terminal` for a terminal harness; else a monogram of its name (`Zeta Bot` is `ZB`) on a color fixed
by its id, so it never changes between launches or devices. A missing or broken icon file is a
doctor error, never a blank icon. An SVG may not hold scripts or event handlers. Clients draw the
daemon's one answer, `iconSpec` on each `_acpmux/harnesses` entry: `{kind: brand|glyph|emoji|symbol|
image|monogram, ..., source: profile|id|command|family|default}`. The app draws an SF Symbol for its pages (`harness.symbol` on the agent page,
`agents.run {action: "symbol"}` in Settings) and natively in the tab strip and sidebar; a name the
Mac cannot draw shows the symbol's monogram (`text`, `hue`).

## Secrets

Never put a secret (API key, token, password) in a profile file. Store it in the system secret
store and reference it:

```sh
cmux harness secret set acme ACME_API_KEY       # hidden prompt, or the value on stdin
```

This stores the value in the Keychain (macOS) or with `secret-tool` (Linux) under
`cmux-harness/acme/ACME_API_KEY`, and writes `ACME_API_KEY = { keychain =
"cmux-harness/acme/ACME_API_KEY" }` into your profile. The value is read only when the harness
starts. A literal value under a secret-looking key (`KEY`, `TOKEN`, `SECRET`,
`PASSWORD`, `PASSWD`, `CREDENTIAL`, `AUTH`, `COOKIE` in the name) is a warning in your own file and an error in managed and
folder files. The doctor and every diagnostic show env key names and their source kind, never
values; harness output that the doctor prints has every resolved env value masked.

## Your own model endpoint

An Anthropic-compatible or OpenAI-compatible endpoint (a company gateway, your team's inference
server, a hosted provider, a model server on your Mac) becomes a harness from Settings or with one
command. A Chief can then use it as its backend.

### From Settings

Settings › Agents › Add Agent… › **Endpoint**:

1. Pick a preset. Each fills the URL it can and says whether a key is needed:

   | Preset | Base URL | Key |
   |---|---|---|
   | Model server on this Mac (port 11434) | `http://127.0.0.1:11434/v1` | none |
   | Desktop model app (port 1234) | `http://127.0.0.1:1234/v1` | none |
   | Your team's inference server | its OpenAI-compatible URL, usually ending in `/v1` | optional |
   | Hosted OpenAI-compatible provider | the provider's URL, usually ending in `/v1` | required |
   | Anthropic-compatible gateway (runs Claude Code) | the URL before `/v1/messages` | required |

2. Type the model ids, separated by commas (the first is the default), or press **Fetch Models**:
   acpmux asks the endpoint for `<base URL>/models` (10 s at most; https, or plain http only to
   this Mac) and fills the list. Remove the ones you don't want. Fetch Models already adds the
   endpoint with every model it lists; Check and Add writes it again with the models you kept. If
   you close the form before a check passes, the endpoint Fetch Models added is removed again.
3. Press **Check and Add**. The key goes to your Keychain in the same call, the profile is
   written, and one real prompt is sent. If it fails, the form stays open and shows the failing
   step with its message and fix (the key, the base URL or the model); change the field and press
   Check and Add again, which writes the same endpoint again. A key you already typed stays in your
   Keychain: leave the field empty to keep it, or type a new one. When it answers, the panel closes
   and the new harness is in the model picker with each of its models.
4. Each endpoint gets its own id, made from its name (ASCII letters and digits; a name without
   any, as in Japanese, Chinese or Korean, takes the preset's id, such as `local-models`), with
   `-2`, `-3` and so on when the id is taken. A form only ever writes over the endpoint it added
   itself; an id another harness already has is refused before any key is stored.

### From the CLI

```sh
cmux harness add acme --example anthropic-endpoint --base-url https://llm.example.com \
    --model acme-large,acme-medium,acme-small [--keychain-item ITEM] [--name "Acme"]
cmux harness add local --example openai-endpoint --base-url http://127.0.0.1:11434/v1 \
    --model '*' [--keychain-item ITEM]
cmux harness secret set acme ANTHROPIC_AUTH_TOKEN     # openai-endpoint: CMUX_BYO_API_KEY
cmux harness doctor acme                              # one real hello turn
```

- `--model` takes one id, several separated by commas, or the flag repeated; the first is the
  default and every one is in the model picker. `'*'` adds every model the endpoint lists at
  `<base URL>/models` (the key is read from the Keychain item; without one the list is asked for
  without a key, as a model server on your Mac expects).
- `anthropic-endpoint` writes a `claude-stdio` profile (acpmux's own Claude Code adapter,
  command `claude`) with `ANTHROPIC_BASE_URL` (the URL before `/v1/messages`), `ANTHROPIC_MODEL`
  (the first model), Claude Code's model slots and `ANTHROPIC_AUTH_TOKEN = { keychain = ITEM }`
  (sent as `Authorization: Bearer`). List models largest first: `ANTHROPIC_DEFAULT_OPUS_MODEL` is
  the first, `ANTHROPIC_DEFAULT_SONNET_MODEL` the second and `ANTHROPIC_DEFAULT_HAIKU_MODEL` (and
  `ANTHROPIC_SMALL_FAST_MODEL`) the third; a slot without a model of its own takes the one before
  it, so a subagent never asks the endpoint for a model it does not serve. Every other
  `ANTHROPIC_*` and Claude provider switch from your login shell or the daemon
  (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_USE_BEDROCK`, ...) is removed
  from its environment, so your own Claude login never redirects it.
- `openai-endpoint` writes an `opencode acp` profile with `OPENCODE_CONFIG_CONTENT` (OpenCode's
  inline config, which wins over your global and project config): provider `byo` on
  `@ai-sdk/openai-compatible` with `options.baseURL` (the URL before `/chat/completions`, usually
  ending in `/v1`), `options.apiKey = "{env:CMUX_BYO_API_KEY}"` and every model, and
  `"model": "byo/<first model>"`; `CMUX_BYO_API_KEY = { keychain = ITEM }`. A chat starts on any of
  the models.
- The base URL is https; plain http only to `localhost`, `127.0.0.1` or `::1`. A URL with a user,
  password or key, a Keychain item name that looks like a key, and a key passed as a parameter are
  refused: the key goes only into the Keychain.
- Without `--keychain-item` the profile names `cmux-harness/<id>/<KEY>` only when a key is already
  stored there; otherwise it names no key at all, so a keyless server's env always resolves.
  `cmux harness secret set ID KEY` stores the key there later and points the profile at it. With
  `--keychain-item`, the profile reads the item you name (`service` or `service/account`).
- A family or global route binding never rewrites an endpoint harness; a chat's or
  workspace's route still does.
- `cmux harness doctor ID` (and `_acpmux/harness/doctor {id, prompt: true}`) sends one real prompt:
  `claude -p` with the profile's env for `anthropic-endpoint` (at least 60 s), the ACP prompt for
  `openai-endpoint`. A failure names the fix: **check the key**, **check the base URL** or
  **model not found**. Env values are masked in everything it prints.

From the app (the unix socket): `_acpmux/harness/add {example: "anthropic-endpoint" |
"openai-endpoint", id, displayName, baseUrl, model (one id, several comma separated, or `*`),
models?, apiKey? | keychainItem?, replace?}` answers with `secret: {key, keychainItem}`. It is one
step, taken one add at a time: an id that already has a profile (in your folder or any other
source) is refused (`harness.exists`) before any key is stored, unless `replace` is true. Then the
profile is written and `apiKey`, if given, is stored in that profile's own item
(`cmux-harness/<id>/<KEY>`, through `security -i` on stdin; never echoed, never in the file). If
the key cannot be stored, the profile is put back as it was. Without `apiKey`, a `replace` keeps
the item the old profile named, and a new endpoint names none. `*` is read with the key given, or
the one stored. `_acpmux/harness/secret/set {id, key, value}` stores a key for a harness on its own.
The app's `cmux.chief.backend.add {id?, replace?, apiKey?, ...}` passes these on: the page sends
`replace` only for its own earlier add. Then `_acpmux/harness/doctor {id, prompt: true}`. The
Settings form and the Chief editor reach these through the app's `cmux.chief.backend.add|doctor`.

## Terminal harnesses (no ACP)

`protocol = "terminal"` is for a CLI or TUI that does not speak ACP. It shows in the picker but
does not open as a chat. Run it in a terminal tab instead:

```sh
cmux harness run acme                  # in this terminal, with the profile's env, in this folder
cmux harness run acme --tab            # in a new cmux tab
cmux harness run acme --cwd ~/src/app --model acme-large
```

The env is passed to the program directly; no secret appears on a command line. If the vendor
has an ACP adapter, prefer it: chats get streaming, tool calls, permission prompts and model
switching.

## Folder profiles

A profile in a repository (`<folder>/.cmux/harnesses/<id>.toml`) can be changed by anybody who
can change the repository, and it runs a program with your rights. So cmux never loads it on its
own. A chat may use it only when all of these hold:

1. The folder has your Trust answer `trusted` (the question cmux asks before the first prompt
   in a folder). A damaged trust record counts as no answer.
2. You confirmed **Enable harness** for exactly these bytes:

   ```sh
   cmux harness list --folder ~/src/app        # folder profiles and their state
   cmux harness enable acme --folder ~/src/app # shows the command, then asks y/N
   cmux harness disable acme --folder ~/src/app
   ```

   The confirmation (CLI, or the app's sheet) shows the file, the exact command line, the
   program it resolves to, each env key with its source (plain values are shown, Keychain items
   and login variables are named), the files it checks and the hash. Without a terminal,
   `enable` needs `--yes`.
3. The chat's folder is inside that folder, and the chat is not from a remote (Web) or peer
   connection.
4. The id is not already a harness or family (a folder profile never replaces one).

The confirmation is recorded with a sha256 of the profile file and its icon. When the program
or an argument resolves to a file inside the folder (for example `./scripts/agent.js` or a
binary in `bin/`), that file's path and contents are part of the hash too. Any change to any of
these asks again. Two things are not checked again, and the confirmation warns about them:
launchers that download code at each start (`npx pkg@latest`, `bunx`, `pnpm dlx`, `uvx`,
`pipx run`), and env keys that change which code a program loads (`PATH`, `NODE_OPTIONS`,
`PYTHONPATH`, `DYLD_*`, `LD_*` and similar). A folder file may not be a symlink, may not use a
relative program path, keeps its icon next to it, and may not hold a literal secret.

## Write an ACP adapter (for vendors)

If your agent has no ACP mode, an adapter gives it the full chat experience in cmux and in every
other ACP client. The [Agent Client Protocol](https://agentclientprotocol.com) is JSON-RPC 2.0
over the agent's stdin and stdout. The minimum:

- `initialize`: reply with `protocolVersion`, `agentCapabilities` (set `loadSession` if you
  support it) and `agentInfo`.
- `session/new {cwd, mcpServers}`: create a session, reply with `sessionId`; list models and
  modes in `models` / `modes` or `configOptions` when you have them.
- `session/prompt {sessionId, prompt}`: stream `session/update` notifications
  (`agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`, `plan`), then
  reply with a `stopReason` (`end_turn`, `cancelled`, ...).
- `session/request_permission`: ask the client before a tool runs; honor the answer.
- `session/cancel`: stop the turn.
- Optional: `session/load` (resume), `session/set_model`, `session/set_mode`,
  `session/set_config_option` (effort and similar).

Write logs to stderr, never to stdout. Start from an existing adapter (`codex-acp`, `pi-acp`,
`gemini --experimental-acp`) and the examples above, then check it with
`cmux harness doctor <id>`.

## Troubleshooting

Run `cmux harness doctor <id>` and do what each `fix:` line says. Common results:

- **command not found**: the program is not on your login `PATH`. Use an absolute path or fix
  `PATH` in your shell profile.
- **no file at PATH**: the absolute `command` points at nothing. Install the program there or fix
  the path in the profile file the fix line names.
- **PATH is not executable**: a script without its execute bit. Run the `chmod +x PATH` that the
  fix line prints.
- **missing Keychain item**: run `cmux harness secret set <id> <KEY>`.
- **auth check failed**: run the `[auth].login` command once.
- **initialize timed out**: the program did not speak ACP on stdout. Check its ACP flag, and that
  it logs to stderr.
- **unknown key**: a typo in the file; the diagnostic names the line and the likely key.
- A folder profile shows `needs-trust` or `needs-enable` in `cmux harness list --folder DIR`: answer
  the folder's Trust question, then run `cmux harness enable`.
