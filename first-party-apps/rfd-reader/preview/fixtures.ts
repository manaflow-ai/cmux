// Made-up RFDs and review comments for the preview page and the tests: the GitHub answers the
// gateway would give for a small docs/rfd folder, one RFD on an open pull request.
export const REPO = "manaflow-ai/cmuxterm-hq"

const rfd = (front: string, body: string) => `---\n${front.trim()}\n---\n\n${body.trim()}\n`

export const FILES: Record<string, { text: string; sha: string; date: string }> = {
  "docs/rfd/0001-rfd-process.md": {
    sha: "1111111111111111111111111111111111111111",
    date: "2026-11-10T18:00:00Z",
    text: rfd(
      `state: published
authors:
  - leo
  - claude
links:
  - https://github.com/manaflow-ai/cmuxterm-hq/pull/12001`,
      `# RFD 0001: Requests for Discussion

## Why

Design questions used to live in issues. Issues are fine for bugs and poor for a decision that needs
a long argument, a record of what was decided and a place to come back to. An RFD is a Markdown file
in \`docs/rfd/\`, discussed in its pull request, merged when it is published.

## States

| State | Means |
|---|---|
| prediscussion | a draft its authors are still shaping |
| ideation | an idea worth writing down, not ready to argue |
| discussion | open for comments in its pull request |
| published | merged: the decision as made |
| committed | built and shipped |
| abandoned | not pursued; kept for the record |

## Format

Each file starts with front matter:

\`\`\`yaml
state: discussion
authors:
  - your-name
links:
  - https://github.com/OWNER/REPO/pull/N
\`\`\`

Then \`# RFD NNNN: Title\` and the text. Name other RFDs as RFD 2 or link their file, like
[the earned-access ladder](0002-agent-access-ladder.md); the reader previews them on hover.`,
    ),
  },
  "docs/rfd/0003-session-row-density.md": {
    sha: "3333333333333333333333333333333333333333",
    date: "2026-11-14T09:30:00Z",
    text: rfd(
      `state: ideation
authors:
  - codex
last_updated: 2026-11-14`,
      `# RFD 0003: Session row density

## Problem

Session rows show the agent, its machine, its state and its pull requests. With twenty sessions the
sidebar scrolls. RFD 1 says ideation is the place for this kind of half-formed idea.
[Our note on session pools](../reading/2026-11-16-session-pools.md) has the numbers behind it.

## Options

1. Two lines per row, as today.
2. One line, the pull requests as a count.
3. One line, and the second line only on hover.

## Open questions

- Does the count lose the check state people glance at?`,
    ),
  },
  "docs/rfd/0004-offline-drafts.md": {
    sha: "4444444444444444444444444444444444444444",
    date: "2026-11-02T12:00:00Z",
    text: rfd(
      `state: abandoned
authors:
  - claude`,
      `# RFD 0004: Offline drafts for chat messages

Drafts already survive a restart; a separate offline store added nothing. Kept for the record.`,
    ),
  },
}

/** RFD 0002 lives on an open pull request (state discussion). */
export const PR_FILE = {
  path: "docs/rfd/0002-agent-access-ladder.md",
  sha: "2222222222222222222222222222222222222222",
  text: rfd(
    `state: discussion
authors:
  - claude (access lane)
last_updated: 2026-11-17
access: internal
links:
  - https://github.com/manaflow-ai/cmuxterm-hq/pull/12392
  - https://example.com/recordings/access-ladder.mp4
  - 0001-rfd-process.md`,
    `# RFD 0002: An access ladder for agents

## Problem and context

Every chat gets a permission policy, set by hand. A new agent and one that has landed fifty clean
pull requests start the same way, so people either approve too much too early or click Allow all day.

## Options

1. **Earned rungs**: an agent widens as it builds a record.
2. **Per-project policy**: one policy per repository, set once.

Not under consideration:

- **Allow all by default**: it removes the review the ladder exists for.

## Goals

1. A new agent asks before it edits.
2. A proven agent stops asking for what it has done well before.

## The options against the goals

### Earned rungs

| Rung | Allows |
|---|---|
| review | read-only shell |
| approve-reads | reads without asking |
| approve-edits | edits without asking |
| approve-all | everything below the person's own ceiling |

A promotion needs a record: pull requests landed green, no reverts, no refusals. A demotion takes one
click on the session row. This builds on the process in RFD 0001.

\`\`\`rust
enum PolicySource { Set, Cleared, VmHost, Earned }
\`\`\`

### Per-project policy

Meets the first goal and misses the second: a proven agent asks as often as a new one.

## Determination

Earned rungs, within the person's ceiling. Open: should a promotion wait for a click?`,
  ),
}

export const PULLS = [
  {
    number: 12392,
    title: "RFD 0002: an access ladder for agents (discussion)",
    body: "Adds docs/rfd/0002-agent-access-ladder.md.",
    html_url: `https://github.com/${REPO}/pull/12392`,
    updated_at: "2026-11-17T08:12:00Z",
    head: { ref: "lane/access-ladder", sha: "abcabcabcabcabcabcabcabcabcabcabcabcabca" },
  },
  {
    number: 12400,
    title: "Fleet: retry a lost runner",
    body: "Unrelated to RFDs.",
    html_url: `https://github.com/${REPO}/pull/12400`,
    updated_at: "2026-11-17T09:00:00Z",
    head: { ref: "lane/runner", sha: "def0def0def0def0def0def0def0def0def0def0" },
  },
]

/** Review comments on the RFD 0002 pull request: file lines, front matter included. */
export const COMMENTS = [
  {
    id: 1,
    path: PR_FILE.path,
    line: 18,
    start_line: 17,
    body: "Is 'fifty clean pull requests' the bar we want, or just an example? A number here will be read as the rule.",
    user: { login: "leo" },
    html_url: `https://github.com/${REPO}/pull/12392#discussion_r1`,
    created_at: "2026-11-17T08:20:00Z",
  },
  {
    id: 2,
    in_reply_to_id: 1,
    path: PR_FILE.path,
    line: 18,
    body: "An example. The proposal section has the real rule; I'll drop the number.",
    user: { login: "claude" },
    html_url: `https://github.com/${REPO}/pull/12392#discussion_r2`,
    created_at: "2026-11-17T08:31:00Z",
  },
  {
    id: 3,
    path: PR_FILE.path,
    line: 43,
    body: "approve-all should still never reach an elevated scope. Worth saying here, not only in the guard section.",
    user: { login: "codex" },
    html_url: `https://github.com/${REPO}/pull/12392#discussion_r3`,
    created_at: "2026-11-17T09:02:00Z",
  },
  {
    id: 4,
    path: PR_FILE.path,
    line: null,
    original_line: 9,
    body: "Outdated: this line changed.",
    user: { login: "leo" },
    html_url: `https://github.com/${REPO}/pull/12392#discussion_r4`,
    created_at: "2026-11-16T22:00:00Z",
  },
]

const b64 = (s: string) => {
  const bytes = new TextEncoder().encode(s)
  let bin = ""
  for (const b of bytes) bin += String.fromCharCode(b)
  return btoa(bin)
}

/** The gateway's answer for one path, or a thrown not-found. */
export function answer(path: string): unknown {
  const p = path.replace(`/repos/${REPO}/`, "")
  if (path === "/user") return { login: "leo" }
  if (p.startsWith("contents/docs/rfd")) return [{ name: "0000-template.md", path: TEMPLATE.path, sha: TEMPLATE.sha, type: "file" }, ...Object.keys(FILES).map((f) => ({ name: f.split("/").pop(), path: f, sha: FILES[f].sha, type: "file" }))].concat([{ name: "0002-agent-access-ladder", path: "docs/rfd/0002-agent-access-ladder", sha: "f".repeat(40), type: "dir" }] as never)
  if (p.startsWith("contents/docs/reading")) return [NOTE_README, NOTE_TEMPLATE, ...Object.entries(NOTE_FILES).map(([path, f]) => ({ path, sha: f.sha }))].map((f) => ({ name: f.path.split("/").pop(), path: f.path, sha: f.sha, type: "file" }))
  if (p.startsWith("pulls?")) return [...PULLS, NOTE_PULL]
  if (p.startsWith("pulls/12392/files")) return [{ filename: PR_FILE.path, sha: PR_FILE.sha, status: "added" }]
  if (p.startsWith("pulls/12392/comments")) return COMMENTS
  if (p.startsWith("pulls/12410/files")) return [{ filename: NOTE_PR_FILE.path, sha: NOTE_PR_FILE.sha, status: "added" }]
  if (p.startsWith("pulls/12410/comments")) return NOTE_COMMENTS
  if (/^pulls\/(12001|13172|13150)\/comments/.test(p)) return []
  if (/^pulls\/\d+\/files/.test(p)) return []
  const blob = /^git\/blobs\/([0-9a-f]{40})$/.exec(p)
  if (blob) {
    const notes = [NOTE_README, NOTE_TEMPLATE, NOTE_PR_FILE, ...Object.values(NOTE_FILES)]
    const text = blob[1] === PR_FILE.sha ? PR_FILE.text : blob[1] === TEMPLATE.sha ? TEMPLATE.text : (Object.values(FILES).find((f) => f.sha === blob[1])?.text ?? notes.find((f) => f.sha === blob[1])?.text)
    if (text !== undefined) return { content: b64(text), encoding: "base64" }
  }
  if (p.startsWith("commits?")) {
    const file = decodeURIComponent(/path=([^&]+)/.exec(p)?.[1] ?? "")
    const f = FILES[file]
    if (NOTE_FILES[file]) return [{ commit: { committer: { date: "2026-11-18T09:00:00Z" }, message: NOTE_FILES[file].message } }]
    return f ? [{ commit: { committer: { date: f.date } } }] : []
  }
  throw Object.assign(new Error(`not.found: ${path}`), { code: "not.found" })
}

/** RFD 0000, the repository's template: not listed; a new RFD starts from its body. */
export const TEMPLATE = {
  path: "docs/rfd/0000-template.md",
  sha: "0000000000000000000000000000000000000000",
  text: rfd(
    `state: prediscussion
authors:
  - your-name
access: internal
links:
  - https://github.com/manaflow-ai/cmuxterm-hq/pull/NNNN`,
    `# RFD NNNN: Title

## Problem and context

## Options

Not under consideration:

## Goals

## The options against the goals

## Determination`,
  ),
}

// ---- Reading notes (docs/reading/) ----------------------------------------------------------

const note = (front: string, body: string) => rfd(front, body)

/** Made-up notes on the base branch, plus the folder's index and template (not notes). */
export const NOTE_FILES: Record<string, { text: string; sha: string; message: string }> = {
  "docs/reading/2026-11-18-lazy-checkouts.md": {
    sha: "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",
    message: "docs/reading: notes on four posts (#13172)",
    text: note(
      `state: acting
source: https://example.com/blog/lazy-git-checkouts
source_author: The build team (Example Co)
published: 2026-11-17
read: 2026-11-18
read_by: desktop-leo (for Leo)
shared_by: Leo
ask: "hey this came out recently"
access: internal
tags: [git, ci, projection]
links:
  - https://github.com/manaflow-ai/cmuxterm-hq/pull/13166`,
      `# Lazy git checkouts with content-checked caching

## What it says

- Files appear at once and their bytes arrive on first read.
- A build step's cached result is used only after the files it read are checked again.

## What we already do

- [The access ladder](../rfd/0002-agent-access-ladder.md) already assumes a lane VM per agent; RFD 1
  has the process for writing a design like this down.

## What we take from it

1. Check what a step read, not timestamps.

## What we did

- Prior-art survey started (#13166).`,
    ),
  },
  "docs/reading/2026-11-16-session-pools.md": {
    sha: "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2",
    message: "docs/reading: session pools (#13150)",
    text: note(
      `state: adopted
source: https://example.org/agents-are-sessions
source_author: Pat Doe (Example Cloud)
published: 2026-11-15
read: 2026-11-16
read_by: cloud lane (for Leo)
shared_by: Leo
ask: "this too!"
access: internal
tags: [cloud, cost]
links: []`,
      `# Agent sessions are long and mostly idle

## What it says

- A session waits on its person most of the day; park it after two minutes.

## What we already do

- Cloud machines pause after 120 s idle.

## What we take from it

1. Size the warm pool for the busiest hour.

## What we did

- Adopted: the pool follows the busiest hour.`,
    ),
  },
  "docs/reading/2026-11-10-old-browser-post.md": {
    sha: "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3",
    message: "docs/reading: an older post",
    text: note(
      `state: stale
source: https://example.net/browser
source_author: Sam Roe
published: 2025-10-30
read: 2026-11-10
read_by: browser lane
shared_by: Leo
ask: "old news atp"
access: internal
tags: [browser, startup]
links: []`,
      `# A browser out of process

## What it says

- The engine runs in its own process; the app is a thin client.

## What we take from it

The takeaway no longer holds: we do this already.`,
    ),
  },
}

export const NOTE_README = {
  path: "docs/reading/README.md",
  sha: "d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4",
  text: `# Reading notes

## Index

Newest first.

| Read | Note | Source | State | Tags |
| --- | --- | --- | --- | --- |
| 2026-11-18 | [Lazy git checkouts](2026-11-18-lazy-checkouts.md) | Example Co | acting | git, ci, projection |
`,
}

export const NOTE_TEMPLATE = {
  path: "docs/reading/_template.md",
  sha: "e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5",
  text: note(
    `state: read
source: https://example.com/the-article
read: YYYY-MM-DD
tags: [cloud, ci, perf]
links:
  - https://github.com/manaflow-ai/cmuxterm-hq/pull/NNNN`,
    `# Title of the article, in a few words

<!--
How to write one. Delete this comment.
-->

## What it says

The claims and numbers that matter to us.

## What we already do

## What we take from it

## What we did`,
  ),
}

/** A note on an open pull request that has not added its index row yet. */
export const NOTE_PR_FILE = {
  path: "docs/reading/2026-11-17-verification.md",
  sha: "f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6",
  text: note(
    `state: read
source: https://example.com/how-we-verify
source_author: Alex Kim (Example Labs)
published: 2026-11-16
read: 2026-11-17
read_by: review lane (for Leo)
shared_by: Leo
ask: "what do u think ab this"
access: internal
tags: [review, ci]
links: []`,
    `# How one team verifies agent-written code

## What it says

- End-to-end tests that drive the real app are the hardest to fool.
- A check still failing after three rounds brings in a person.

## What we take from it

1. Stamp every commit with how it was verified.`,
  ),
}

export const NOTE_PULL = {
  number: 12410,
  title: "Create 2026-11-17-verification.md",
  body: "",
  html_url: `https://github.com/${REPO}/pull/12410`,
  updated_at: "2026-11-17T10:00:00Z",
  head: { ref: "leo-patch-1", sha: "1234123412341234123412341234123412341234" },
}

export const NOTE_COMMENTS = [
  {
    id: 11,
    path: NOTE_PR_FILE.path,
    line: 18,
    body: "Which of these do we already run on every PR? Worth a line in What we already do.",
    user: { login: "leo" },
    html_url: `https://github.com/${REPO}/pull/12410#discussion_r11`,
    created_at: "2026-11-17T10:05:00Z",
  },
]

/** The real files (preview/dist/real.json, written by shoot.ts from a cmuxterm-hq checkout), when present. */
export interface RealFiles {
  files: Record<string, { text: string; sha: string; date: string; message: string }>
}

/** The gateway's answer from real files: both folders, no open pull requests, no comments. */
export function realAnswer(path: string, real: RealFiles): unknown {
  const p = path.replace(`/repos/${REPO}/`, "")
  if (path === "/user") return { login: "leo" }
  const contents = /^contents\/([^?]+)/.exec(p)
  if (contents) {
    const dir = contents[1]
    const entries = Object.entries(real.files).filter(([f]) => f.slice(0, f.lastIndexOf("/")) === dir)
    if (!entries.length) throw Object.assign(new Error(`not.found: ${path}`), { code: "not.found" })
    return entries.map(([f, v]) => ({ name: f.split("/").pop(), path: f, sha: v.sha, type: "file" }))
  }
  if (p.startsWith("pulls?")) return []
  if (/^pulls\/\d+\/(comments|files)/.test(p)) return []
  const blob = /^git\/blobs\/([0-9a-f]{40})$/.exec(p)
  if (blob) {
    const f = Object.values(real.files).find((v) => v.sha === blob[1])
    if (f) return { content: b64(f.text), encoding: "base64" }
  }
  if (p.startsWith("commits?")) {
    const f = real.files[decodeURIComponent(/path=([^&]+)/.exec(p)?.[1] ?? "")]
    return f ? [{ commit: { committer: { date: f.date }, message: f.message } }] : []
  }
  throw Object.assign(new Error(`not.found: ${path}`), { code: "not.found" })
}
