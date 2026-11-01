# Vault agent registration and session filtering

Vault restores built-in agent sessions and can also read custom agent registrations from
`cmux.json`. Registrations define how cmux detects a running terminal process, where the
agent's native session id comes from, and which command resumes that session.

Vault can omit non-interactive Claude Code Agent SDK transcripts and other sessions
with filters in the same `vault` section. `hideClaudeSDKSessions` hides Claude
transcripts whose `entrypoint` begins with `sdk-`. Each `exclude` rule is an AND
of the fields it contains; multiple rules are ORed. Agent ids, folders, and
entrypoints accept `*` and `?` wildcards; `*` also matches `/`, so `*/scratch/*`
covers every folder below a `scratch` directory but not the directory itself.
Codex sessions use their launch source (`cli`, `exec`, `vscode`, ...) as the
entrypoint. `labelPattern` (or its shorter `pattern` alias) matches the whole
session label with those wildcards; prefix it with `re:` for a case-insensitive
regular expression that may match anywhere in the label.

Filters in the global config apply everywhere. Filters in a project's
`cmux.json` add to the global filters in folder views, folder-scoped agent tabs,
and folder-scoped search for that project; the combined recent-session list uses
only the global filters. A project can turn `hideClaudeSDKSessions` on but not
off. Filters only change what Vault lists; a `vault.*` socket call that names a
session by id still finds it.

```jsonc
{
  "vault": {
    "hideClaudeSDKSessions": true,
    "exclude": [
      { "agent": "claude", "entrypoint": "sdk-*" },
      { "folder": "*/scratch" },
      { "folder": "*/scratch/*" },
      { "labelPattern": "re:^(Review|Audit) this change" }
    ]
  }
}
```

Pi, OMP, Campfire, Amp, Antigravity, Grok, Kimi Code, and Hermes Agent are
registered by default. The following partial example shows the Pi, OMP, and Campfire
registrations:

```jsonc
{
  "vault": {
    "agents": [
      {
        "id": "pi",
        "name": "Pi",
        "detect": {
          "processName": "pi",
          "argvContains": "pi"
        },
        "sessionIdSource": { "type": "piSessionFile" },
        "resumeCommand": "{{executable}} --session {{sessionId}}",
        "forkCommand": "{{executable}} --fork {{sessionId}}",
        "cwd": "preserve",
        "sessionDirectory": "~/.pi/agent/sessions"
      },
      {
        "id": "omp",
        "name": "OMP",
        "detect": {
          "processName": "omp"
        },
        "sessionIdSource": { "type": "piSessionFile" },
        "resumeCommand": "{{executable}} --session {{sessionId}}",
        "forkCommand": "{{executable}} --fork {{sessionId}}",
        "cwd": "preserve",
        "sessionDirectory": "~/.omp/agent/sessions"
      },
      {
        "id": "campfire",
        "name": "Campfire",
        "detect": {
          "processName": "campfire"
        },
        "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
        "resumeCommand": "{{executable}} --session {{sessionId}}",
        "cwd": "preserve",
        "sessionDirectory": "~/.campfire/agent/sessions"
      }
    ]
  }
}
```

For a generic agent that exposes the current session as an argv option:

```jsonc
{
  "vault": {
    "agents": [
      {
        "id": "my-agent",
        "name": "My Agent",
        "iconAssetName": "AgentIcons/MyAgent",
        "detect": {
          "processName": "my-agent"
        },
        "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
        "resumeCommand": "my-agent --session {{sessionId}}",
        "forkCommand": "my-agent --session {{sessionId}} --fork",
        "cwd": "preserve",
        "sessionDirectory": "~/.my-agent/sessions"
      }
    ]
  }
}
```

Supported `resumeCommand` placeholders are `{{sessionId}}`, `{{sessionPath}}`,
`{{executable}}`, `{{cwd}}`, and `{{sessionDir}}`. Pi uses `pi --session <id-or-path>`
instead of `pi --continue` so Vault reopens the exact saved session.
OMP accepts `--session`, `--resume`, and `-r` for existing sessions; Vault emits `omp --session <id-or-path>` so relaunch reopens the exact saved OMP session.

Campfire resumes with `campfire --session <id>`; only the driver's host session is restorable (joiners are ephemeral views), and resuming restores the conversation in a fresh collaborative session with a new invite link.

`resumeCommand` must include either `{{sessionId}}` or `{{sessionPath}}`, for
example `pi --session {{sessionId}}`.

`forkCommand` is optional and uses the same placeholders as `resumeCommand`. It
is the argv template for forking (branching) a session into a new copy, for
example `{{executable}} --session {{sessionId}} --fork`. Provide it only when the
agent supports forking; when omitted, the right-click **Fork Conversation** item
stays hidden for that agent (resume still works via `resumeCommand`). Of the built-in
agents, only Pi and OMP ship with `{{executable}} --fork {{sessionId}}`.

`iconAssetName` is optional. When omitted, Vault uses a neutral system icon for
registered agents instead of reusing another agent's brand mark.
