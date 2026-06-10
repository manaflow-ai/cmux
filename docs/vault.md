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

`iconAssetName` is optional. When omitted, Vault uses a neutral system icon for
registered agents instead of reusing another agent's brand mark.

## Extra Claude session roots and remote↔local path mappings

By default the Vault scans Claude transcripts under `CLAUDE_CONFIG_DIR`,
`~/.codex-accounts/claude/*`, and `~/.claude`. If you run Claude Code inside a
Docker dev container (or another machine) whose filesystem is mounted or synced
onto your Mac, you can point the Vault at the extra `~/.claude` and teach the
"this folder only" filter how the container paths map onto your local paths.

```jsonc
{
  "vault": {
    // Extra Claude config directories. Each must contain a `projects/`
    // subdirectory, exactly like ~/.claude.
    "claudeSessionRoots": ["~/mnt/devcontainer/.claude"],

    // Remote↔local path equivalences. A transcript whose cwd is
    // "/workspace/p/x" then matches the local workspace folder
    // "/Users/me/p/x" in the "this folder only" filter.
    "claudePathMappings": [
      { "remote": "/workspace", "local": "/Users/me" }
    ]
  }
}
```

Notes:

- `claudeSessionRoots` entries are scanned like the built-in roots, so their
  sessions show up in listing and search even when no symlink hack is applied.
- `claudePathMappings` is bidirectional and applied to both the project-dir
  slug lookup and the per-transcript cwd comparison, so the folder filter works
  in either direction. Mappings only substitute whole leading path segments
  (`/work` does not match `/workspace`).
- Resume across the mapping boundary is out of scope: a mounted remote session
  lists and searches, but resuming it from the Mac may not work because the
  remote runtime isn't present locally. Local sessions are unaffected.
