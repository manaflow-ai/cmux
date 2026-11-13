---
name: work-tracking
description: "Agent Board: keep a ledger of what you build in this session (each capability, every major decision with the options you rejected, every permutation of the UI or service you built, and the evidence that proves each one) so the engineer can review it on the Agent Board in cmux. Use whenever you finish a capability, make a decision a reviewer would want to question, verify a state, or capture a screenshot, video, test run or build."
---

# Work tracking (Agent Board)

The engineer running you also runs many other agents. They cannot read every
transcript, so they review your work on the **Agent Board** in cmux. The board
shows only what you write to your ledger. Something you built but did not record
is invisible to them; a claim without evidence shows as **unverified**.

This skill is on only because the person turned on Agent Board
(`agents.board.enabled` in `~/.config/cmux/cmux-next.json`). It costs them
tokens, so record what a reviewer needs and nothing else.

## The ledger

One JSON object per line, appended to one file per task. Each tool call runs in a new
shell, so every append computes the path itself; never keep it in a variable across calls:

```bash
d="${CMUX_AGENT_BOARD_DIR:-$HOME/.cmux/agent-board}"; mkdir -p "$d"
cat >> "$d/${CMUX_AGENT_SESSION:-$(basename "$PWD")}.jsonl" <<'EOF'
{"kind":"capability","id":"cap-onboarding","title":"Agent Board onboarding","summary":"Off-by-default card that explains the token cost and turns the board on.","area":"Settings","status":"done","files":["webviews/src/prototypes/agent-board/Onboarding.tsx"]}
EOF
```

cmux sets `CMUX_AGENT_SESSION` for every agent it starts. The quoted heredoc keeps the
shell away from the JSON. Batch the lines of one step into one append; never rewrite or
delete earlier lines. A later line with the same `kind` and `id` replaces that record
(status changes, added evidence) and keeps its place in the list. If your sandbox refuses
writes outside the workspace, set `CMUX_AGENT_BOARD_DIR` to a folder inside it.

Every line has `kind` and `id` (lower kebab case, unique per kind within the ledger).
The board orders records by when they first appear. Field types are checked: a line with an
unknown `status` or `type`, or a list that is not a list of strings, shows as an error row.

| kind | when | fields |
| --- | --- | --- |
| `task` | once, first | `title`, `goal` (the person's ask, one sentence), `branch`, `pr` (URL, when there is one) |
| `capability` | you finish (or drop) a thing the person can use | `title`, `summary`, `area`, `status` (`building`, `done`, `dropped`), `files` |
| `decision` | you pick between real options a reviewer could question | `title`, `chosen`, `why`, `rejected` (`[{ "option", "why" }]`), `for` (capability ids), `needsHuman` (`true` when only the person should decide) |
| `permutation` | each state you built: a mode, platform, size, empty, loading, error or edge case | `for` (capability id), `axes` (`{"theme":"dark","platform":"iOS","state":"empty"}`), `status` (`verified`, `unverified`, `broken`), `evidence` (evidence ids), `note` |
| `evidence` | you capture proof | `type` (`screenshot`, `video`, `test`, `build`, `log`, `link`), `path` or `url`, `caption`, `sha` (the commit it proves), `for` (ids it proves) |

Paths are absolute local paths or URLs. Keep media where it already is (your
scratch folder, the PR, the artifact); the board links to it and does not copy it.

## What to record

- **Capabilities**: what the person can now do, in their words, not your file list.
- **Decisions**: only forks a reviewer would want to see: a design direction, a
  data model, a dependency, a trade-off in scope, a default. Not naming or
  formatting. Always list what you rejected and why; a decision with no
  alternatives is not a decision.
- **Permutations**: every state the change has. Light and dark, Mac and iPhone,
  each size, empty, loading, error, long text, offline. If you did not build or
  check one, record it as `unverified` with a `note` saying why. A missing
  permutation is worse than an unverified one.
- **Evidence**: the screenshot, video, test command and result, build job, or
  link that proves a permutation. Name the full 40-character commit SHA it was taken at. Evidence
  from an older commit is still useful but the board flags it as stale.

## Keep it cheap

- Write at the end of each step, not after every tool call. One append per step.
- Do not paste screenshots back into your context to describe them; record the
  path and a one-line caption.
- Do not re-read the ledger to check your own writes. A malformed line shows on
  the board as an error row, which the person can see.
- Do not record secrets, tokens, emails or private user content in any field.

## Before you say you are done

1. Every `capability` you built has `status` `done` or `dropped`.
2. Every capability has at least one `permutation`, and each permutation is
   `verified` with evidence, or `unverified`/`broken` with a note.
3. Every `decision` with `needsHuman: true` is also named in your final message.
