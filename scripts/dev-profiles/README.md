# dev-profiles

Data-driven environment presets for the turnkey dev-build flow (P3). A profile
provisions a realistic test environment in a **tagged** dev cmux instance so a
given feature has live state to test against, picked by what you're testing.

Profiles are replayed by `scripts/dev-setup.sh --profile <name>` after the app
is built, launched, and paired. Every step runs through
`scripts/cmux-debug-cli.sh`, which refuses without `CMUX_TAG` and targets
`/tmp/cmux-debug-<slug>.sock` only, never the user's stable app. Profiles are
dev-only tooling and must contain no secrets.

## Usage

```bash
# Build + launch + pair, then seed a live agent for composer testing:
scripts/dev-setup.sh --tag grid --profile composer

# Compose several presets (applied in order):
scripts/dev-setup.sh --tag grid --profile composer,browser

# List the available profiles:
scripts/dev-profiles/replay-cli.mjs --list

# Dry-run: print the resolved `cmux` arg vectors without touching a socket:
scripts/dev-profiles/replay-cli.mjs --dry-run --cwd "$PWD" --profile groups

# Apply directly to an already-running tagged build (no rebuild):
scripts/dev-profiles/replay-cli.mjs --tag grid --profile notif --cwd "$PWD"
```

An unknown profile name fails fast (before any build) and lists the available
profiles.

## Adding a profile = adding a file

Drop a `<name>.json` file in this directory. No code change is needed; the name
becomes available automatically. Format:

```json
{
  "description": "Human summary of what this preset provisions.",
  "steps": [
    {
      "args": ["--id-format", "uuids", "workspace", "create", "--name", "Composer",
               "--cwd", "${cwd}", "--command", "claude", "--json"],
      "capture": { "ws": "workspace_id" }
    },
    {
      "args": ["send", "--workspace", "${ws}", "echo hi\\n"]
    }
  ]
}
```

- **`steps`** (required): an ordered list. Each step is one `cmux` invocation.
- **`args`** (required): the exact `cmux` argument vector for the step, with the
  leading `cmux` omitted. These are passed verbatim to `cmux-debug-cli.sh`.
- **`${name}`** placeholders are substituted from earlier `capture`s plus the
  built-in `${cwd}` (the directory dev-setup ran in, i.e. the repo worktree).
- **`capture`** (optional): maps a local variable name to a dotted JSON path
  read out of that step's stdout. The step must pass `--json`. Later steps
  reference the value as `${name}`. Use this to chain "create a thing, then act
  on the thing" (e.g. capture `workspace_id`, then `send` to it). Captured
  values are cmux refs/ids, never secrets.

Only use `cmux` verbs that actually exist (see
`skills/cmux-workspace/references/commands.md` and the `cmux-groups` skill).
Prefer the canonical noun forms (`cmux workspace create`,
`cmux workspace group create`) which honor `--json`. Use `--focus false` on
creation steps so replay does not yank the dev window around.

The capture key name depends on the id format, because cmux renames id fields
in `--json` output: with the default `refs` format a created workspace prints
`workspace_ref` (a positional `workspace:N`), but with `--id-format uuids` it
prints `workspace_id` (a stable UUID). The shipped profiles prepend
`--id-format uuids` to creation steps and capture `workspace_id` / `group.id`
so the captured value is a UUID that stays valid regardless of window numbering.
Captured UUIDs are accepted anywhere a `--workspace` / group id is expected.

## Shipped profiles

| Profile | What it provisions |
| --- | --- |
| `composer` | A workspace at the repo cwd with a live `claude` agent in its first surface, so composer / dictation / paste flows have something to type into. |
| `notif` | A dedicated workspace with a notification posted to it and an attention flash triggered, for testing notification mirror / dismiss-sync. |
| `browser` | A workspace with a browser pane open to `https://example.com` (always reachable, no local server needed). |
| `groups` | A named sidebar group (anchor) with two extra member workspaces, for testing workspace groups and groups-on-mobile. |
| `multi-mac` | **Partial.** Seeds the *current* Mac with two clearly-named workspaces. The host switcher lists Macs the phone has actually paired with (iOS-side state) and no socket verb can fabricate a second Mac, so seeding the *switch itself* requires pairing a second real Mac. See note below. |

### multi-mac gap

The multi-Mac host switcher renders the set of Macs a phone has paired with,
which lives in iOS-side `MobilePairedMacStore` state, not in any Mac socket.
There is no debug-CLI verb to inject a fake paired Mac, so this profile can only
seed the local Mac with realistic content. To exercise the actual switch, run
`scripts/dev-setup.sh --tag <other>` on a second physical Mac and pair the phone
to both.

## How it works

- `replay.mjs` — the engine. `resolveSteps(profile, context)` is a pure,
  I/O-free function (parse + substitute + JSON-path capture) that the unit test
  and `--dry-run` both use. `ProfileReplayer` wraps it with execution: it shells
  out to `cmux-debug-cli.sh` with `CMUX_TAG` set, so the tagged-socket safety
  contract is enforced by the helper, not re-implemented.
- `replay-cli.mjs` — the thin CLI `dev-setup.sh` calls (`--list`, `--dry-run`,
  `--tag`, comma-list `--profile`).
- `replay.test.mjs` — `node --test` coverage of the construction half (no live
  socket required).

```bash
node --test scripts/dev-profiles/replay.test.mjs
```
