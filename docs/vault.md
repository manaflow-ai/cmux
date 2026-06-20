# Vault agent registration

Vault restores built-in agent sessions and can also read custom agent registrations from
`cmux.json`. Registrations define how cmux detects a running terminal process, where the
agent's native session id comes from, and which command resumes that session.

Pi Coding Agent and OMP are registered by default:

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
        "forkCommand": "{{executable}} --session {{sessionId}} --fork",
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
        "forkCommand": "{{executable}} --session {{sessionId}} --fork",
        "cwd": "preserve",
        "sessionDirectory": "~/.omp/agent/sessions"
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

`resumeCommand` must include either `{{sessionId}}` or `{{sessionPath}}`, for
example `pi --session {{sessionId}}`.

`forkCommand` is optional and uses the same placeholders as `resumeCommand`. It
is the argv template for forking (branching) a session into a new copy, for
example `{{executable}} --session {{sessionId}} --fork`. Provide it only when the
agent supports forking; when omitted, the right-click **Fork Conversation** item
stays hidden for that agent (resume still works via `resumeCommand`). Pi and OMP
ship with `{{executable}} --session {{sessionId}} --fork`.

`iconAssetName` is optional. When omitted, Vault uses a neutral system icon for
registered agents instead of reusing another agent's brand mark.
