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
  if (p.startsWith("pulls?")) return PULLS
  if (p.startsWith("pulls/12392/files")) return [{ filename: PR_FILE.path, sha: PR_FILE.sha, status: "added" }]
  if (p.startsWith("pulls/12392/comments")) return COMMENTS
  if (p.startsWith("pulls/12001/comments")) return []
  if (/^pulls\/\d+\/files/.test(p)) return []
  const blob = /^git\/blobs\/([0-9a-f]{40})$/.exec(p)
  if (blob) {
    const text = blob[1] === PR_FILE.sha ? PR_FILE.text : blob[1] === TEMPLATE.sha ? TEMPLATE.text : Object.values(FILES).find((f) => f.sha === blob[1])?.text
    if (text !== undefined) return { content: b64(text), encoding: "base64" }
  }
  if (p.startsWith("commits?")) {
    const file = decodeURIComponent(/path=([^&]+)/.exec(p)?.[1] ?? "")
    const f = FILES[file]
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
