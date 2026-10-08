# Add your harness

cmux runs coding agents ("harnesses") such as Claude Code, Codex, OpenCode, Pi and Gemini CLI.
You can add any other harness, for example your company's internal agent, with one TOML file.
No cmux code changes and no restart: cmux reloads the file when it changes, and the harness
appears in the model picker.

The fastest path is to let an agent do it: open the command palette, run **Add Harness…**
(or **Integrate a harness** on the New Tab page). That starts a chat that runs
`cmux harness guide` and follows it: it writes the profile, runs the doctor and fixes what the
doctor reports. The rest of this page is the same information for people.

## The loop

```sh
cmux harness add acme --command acme-agent      # ACP harness: writes ~/.config/cmux/harnesses/acme.toml
cmux harness add acme --command acme --protocol terminal   # a CLI/TUI without ACP
cmux harness add --example codex                # start from a shipped example
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
program starts.

Examples ship in `cmux-tui/crates/acpmux/harnesses/`: `claude.toml`, `codex.toml`,
`opencode.toml`, `pi.toml`, `gemini.toml` and `aider.toml` (terminal).

## Where cmux looks

1. Managed folder, for companies: `/Library/Application Support/cmux/harnesses/` (macOS),
   `/etc/cmux/harnesses/` (Linux). A managed profile wins over a user file with the same id.
2. Your folder: `~/.config/cmux/harnesses/` (or `$XDG_CONFIG_HOME/cmux/harnesses/`).
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
icon = "acme.svg"               # file next to the profile (svg/png, <= 256 KB), or a built-in:
                                # claude, openai, codex, opencode, pi, gemini, terminal, generic
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
- **missing Keychain item**: run `cmux harness secret set <id> <KEY>`.
- **auth check failed**: run the `[auth].login` command once.
- **initialize timed out**: the program did not speak ACP on stdout. Check its ACP flag, and that
  it logs to stderr.
- **unknown key**: a typo in the file; the diagnostic names the line and the likely key.
- A folder profile shows `needs-trust` or `needs-enable` in `cmux harness list --folder DIR`: answer
  the folder's Trust question, then run `cmux harness enable`.
