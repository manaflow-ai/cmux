# Triage: severity, areas, and who decides

cmux has more open issues than any one person can read. Labels exist so you can
ask "what is badly broken in the terminal" and get an answer in one click
instead of scrolling. This page says what each label means, which rule assigns
it, and how to overrule that rule.

The vocabulary lives in [`.github/labels.json`](../.github/labels.json). The
rules live in [`scripts/ci/triage_rules.py`](../scripts/ci/triage_rules.py).
If this page and the code disagree, the code is what ran; fix the page.

## Contributor difficulty

Difficulty answers "how much context and coordination does a contributor need
to make a safe change?" It is separate from severity and area. A low-impact
RFC can be difficult, and a small fix can be urgent. Apply one `difficulty:1`
through `difficulty:4` label after a maintainer has checked the scope.

| Level | Use it when | Typical assignment |
|---|---|---|
| `difficulty:1` | One file or small named surface; reproduction and acceptance are explicit. | Docs, copy, a deterministic test, or a one-line configuration/UI correction. |
| `difficulty:2` | One package or feature boundary; an existing pattern explains the shape. | A regression fix, small CLI/API addition, or contained UI behavior change. |
| `difficulty:3` | Several components or a runtime lifecycle are involved; a design note is needed first. | Persistence/restore, agent hooks, remote transport, or a cross-package behavior change. |
| `difficulty:4` | Security, authority, protocol, migration, release, or broad architecture is involved. | New transport semantics, auth/permissions, durable identity, or major orchestration. |

Difficulty is not an estimate of intelligence or hours. When uncertain, choose
the higher level and state what evidence would lower it. Keep `good first issue`
for Level 1 work that names a code or document starting point and can be
verified without maintainer-only access. `help wanted` says that a patch is
welcome; it makes no promise about size.

### Contributor-ready issue brief

Before advertising an issue to a class or outside contributor, its body should
name the user outcome, owning boundary, starting point, acceptance condition,
verification command, and dependencies such as credentials, hardware, or a
pending product decision. This compact block is useful when refining an issue:

```markdown
## Contributor brief
- Difficulty: Level _
- Area: `area: ...`
- User outcome: ...
- Starting point: `path/to/file:line`, command, or test ...
- Acceptance condition: ...
- Verification: `...`
- Dependencies or maintainer decisions: ...
```

### Current starter candidates

Recheck ownership and current-main behavior before assigning any issue. These
examples show the intended mix for a course queue:

| Issue | Level | Why it is teachable |
|---|---:|---|
| [#15408](https://github.com/manaflow-ai/cmux/issues/15408) — titlebar shortcut hint alignment | 1 | A failing UI assertion gives a precise acceptance condition and narrow layout owner. |
| [#15286](https://github.com/manaflow-ai/cmux/issues/15286) — window geometry observer cleanup | 2 | A contained lifecycle bug with a clear owner and a regression seam. |
| [#15300](https://github.com/manaflow-ai/cmux/issues/15300) — Ctrl+Tab with Caps Lock | 2 | Focused input behavior with a reproducible modifier-state boundary. |
| [#15481](https://github.com/manaflow-ai/cmux/issues/15481) — SQL/Jinja preview highlighting | 2 | A deterministic file-preview/parser edge case with a suggested owner. |
| [#15611](https://github.com/manaflow-ai/cmux/issues/15611) — progressive command discovery RFC | 3 | Good small-group design work; it needs information-architecture agreement before implementation. |

Do not advertise auth, cloud infrastructure, remote transport, data migration,
or release-signing work as independent student assignments until a maintainer
has split out a bounded slice and named the required environment.

## Severity

Severity answers "what does a person lose while this is open". It is not
priority: priority also weighs how many people hit it, how hard the fix is, and
what else is in flight. A maintainer can pick up an `S3` before an `S1`.

| Label | Means | Examples |
|---|---|---|
| `S1: critical` | Work is lost, cmux will not start, or something is exposed that should not be | Reopening a session destroys the current windows; crash on launch; a token in a log |
| `S2: major` | A crash, hang, lost session state, a connection that will not come up, or something that used to work and now does not | Crash when closing the last split; `cmux ssh` cannot connect; sidebar reorder broke in 0.64.24 |
| `S3: minor` | Wrong behavior you can work around | Tab title shows the old directory until you switch tabs |
| `S4: cosmetic` | Wording or appearance, with no effect on what cmux does | A typo in Settings; a misaligned tab indicator |

Two rules about severity that keep arguments short:

- **Feature requests have no severity.** An unbuilt feature is not broken.
  Calling it `S3` turns the label into a priority claim, which a keyword rule
  has no business making. Feature requests get an area and nothing else. A
  title that starts `RFC:`, `feat:`, `Feature request:` or `Support for` is read
  as a request, and so is `Add ...`/`Allow ...` when the only thing the rules
  matched was cosmetic wording. The exception is a security title: `[RFC]
  arbitrary code execution in the ACP transport` still gets `S1`, because
  missing one of those costs more than a relabel.
- **The worst true statement wins.** A report that mentions both a crash and a
  typo is `S2`, not `S4`. With one limit: the title is read before the body, so
  a cosmetic *title* settles it even when the body mentions something worse.

## Areas

One `area:` label says which part of cmux owns the issue. Two are allowed when
a report sits exactly on a seam and both areas are named in the title
(`Command palette text input does not allow IME switching` gets
`area: command-palette` and `area: input`). More than two means nobody can act
on it, so the rules leave those alone and mark `needs-triage` instead.

`area: terminal`, `area: input`, `area: layout`, `area: sidebar`,
`area: workspaces`, `area: agents`, `area: cloud`, `area: remote`, `area: ios`,
`area: cli`, `area: settings`, `area: browser`, `area: command-palette`,
`area: appearance`, `area: notifications`, `area: updates`, `area: auth`,
`area: performance`, `area: localization`, `area: accessibility`,
`area: docs`, `area: build-and-ci`.

[`.github/labels.json`](../.github/labels.json) carries a one-line description
of each, which is what shows in the GitHub label picker.

### The dropdown on the issue form

Both issue forms ask "Which part of cmux is this about?" with the area labels as
options. An answer there is used as-is and nothing else is consulted, because
picking off a list of the real labels is better evidence than any regex over
prose. "Not sure" is a normal answer and falls through to the rules below.

This is the only way body text can decide an area. Scoring deliberately ignores
body-only evidence, so without reading the form the dropdown would have no
effect at all.

### Naming the area yourself

A title that opens with an area's own name is taken at its word, ahead of
anything scored from the rest of the line:

```
Cloud: Codex TUI garbled after restoring a workspace   ->  area: cloud
```

Without that prefix this one scores `agents` (Codex) against `workspaces` and
lands on `needs-triage`. Writing `Cloud:` settles it. Any area label's own noun
works as a prefix, so `perf:`, `iOS:`, `Docs:` and `CI:` all do what they look
like. A prefix naming two areas (`Terminal paste:`) declares neither.

A title with no prefix that simply starts with the area works too
(`Terminal jitters when toggling between tabs`), but only as a fallback when
scoring found no area in the title at all. That keeps an enumeration like
`Sidebar, splits, ssh and the iOS app all need a rethink` on `needs-triage`
rather than reading it as a sidebar issue.

Two words are deliberately not area names: `nightly` and `install`. Both name
the build channel or the feature an issue happens in far more often than they
name its area, so `NIGHTLY hangs: ...` is not `area: updates`.

`needs-triage` means the rules could not pick: the title matched nothing, or it
matched three areas at once without declaring one. About a third of the backlog
is in this state, and that is the honest number. Clearing `needs-triage` is
useful work and needs no build.

## How a new issue gets labeled

[`.github/workflows/auto-triage.yml`](../.github/workflows/auto-triage.yml)
runs [`scripts/ci/auto_triage.py`](../scripts/ci/auto_triage.py) when an issue
is opened or reopened. It applies the labels the rules propose and leaves one
comment naming the rule that fired.

It labels an issue only when that issue has no severity, `area:` or
`needs-triage` label yet, so in practice it gets one turn per issue. So:

- **To overrule it, change the labels.** They stay changed. The bot does not
  run on `edited` or `labeled`, so it cannot argue back. One gap worth knowing:
  it also fires on `reopened`, so if you overrule it by *removing* its label
  and adding nothing, a later reopen labels the issue again. Replace the label
  rather than clearing it.
- **To stop it before it starts,** label the issue while you file it. Anything
  in the triage vocabulary makes auto-triage skip the issue entirely.

The comment has no `@mentions` on purpose. Issue threads already carry enough
bot traffic.

## Reading the rules

Severity is a short ordered list of patterns; the first one that matches wins,
and titles are read before bodies. Cosmetic is title-only, because a body that
says "padding" in a reproduction step does not make a dropped-paste bug
cosmetic. The security pattern is also title-only, because a design discussion
that weighs "arbitrary code execution" is not a vulnerability report.

When no pattern matches at all, the rules still have to decide whether the
report is about something broken, and that decision is a word list too
(`BUG_WORDS`: "wrong", "slow", "does not update", and so on). A bug written
entirely around words that are not in it gets no severity, which looks like the
rules calling it a feature request. That is the most common way for the output
to be wrong, and the fix is to add the severity by hand and, if the wording is
common, add the word to the list.

Areas are scored: a title match is worth 3, a body match 1. The top area wins
if it is ahead of the runner-up, ties of two are both applied, and a body
match on its own is never enough. One passing mention of `ssh` in a
reproduction step is not an area.

The same patterns feed the [Triage Radar](https://github.com/manaflow-ai/cmux/issues/13512),
which is why they live in one module. A second copy would let the radar and the
labels tell different stories about the same report.

## `good first issue` and `help wanted`

These are applied **by a person**, never by the rules. A keyword cannot tell
whether a change is small, and a `good first issue` that turns out to need two
weeks in the layout code is worse than no label: someone new spends their first
evening on it and leaves.

`good first issue` means all of:

- The change is plausibly under a few hundred lines in one area.
- The issue names a starting point: a file, a symbol, or a command to run.
- No pending team decision. If the answer depends on what cmux should do rather
  than what it does, it is not a first issue.
- It can be verified without maintainer-only CI. See the
  [verification ladder](contributor-verification.md).

`help wanted` means nobody on the team is working on it and a patch is welcome.
It carries no promise about size or difficulty.

If you want an issue promoted to `good first issue`, say so on the issue. That
is a normal request and a fast one to answer.

## Running the tools

```sh
# Validate the manifest; then apply it (needs a token with issues:write).
python3 scripts/ci/sync_labels.py --dry-run
python3 scripts/ci/sync_labels.py

# See what the rules would do to one issue, without touching it.
GH_TOKEN=... python3 scripts/ci/auto_triage.py --issue 12345 --dry-run

# Label untriaged open issues in bulk, recording every change.
GH_TOKEN=... python3 scripts/ci/auto_triage.py --backfill --limit 200 --receipt receipt.jsonl

# Undo exactly what a recorded pass added, and nothing else.
GH_TOKEN=... python3 scripts/ci/auto_triage.py --revert receipt.jsonl
```

The backfill does not comment: a pass over the backlog that comments is a
thousand notifications. Every pass writes its receipt line by line as it goes,
so a pass that dies to a rate limit or a timeout still records what it changed.
Keep the file: it is the only thing that makes the pass reversible.

`--dry-run` writes a receipt too, marked `"dry_run": true` on every row, and
`--revert` refuses a file with any such row. A preview records what the rules
*would* do, and some of those labels may since have been applied by a person;
reverting a preview would strip their work. Receipt rows also carry the repo,
and `--revert` refuses a receipt from a different one, because issue numbers do
not mean the same thing in two repositories.

`--limit` must be 1 or more. Omit it to walk every open issue. That is
deliberate: the old spelling made `--limit 0` mean "no limit", which is one
typo away from an unbounded pass over the whole backlog.

Tests for all of this: `tests/test_triage_rules.py`.
