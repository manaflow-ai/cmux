# Triage: severity, areas, and who decides

cmux has more open issues than any one person can read. Labels exist so you can
ask "what is badly broken in the terminal" and get an answer in one click
instead of scrolling. This page says what each label means, which rule assigns
it, and how to overrule that rule.

The vocabulary lives in [`.github/labels.json`](../.github/labels.json). The
rules live in [`scripts/ci/triage_rules.py`](../scripts/ci/triage_rules.py).
If this page and the code disagree, the code is what ran; fix the page.

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
  has no business making. Feature requests get an area and nothing else.
- **The worst true statement wins.** A report that mentions both a crash and a
  typo is `S2`, not `S4`.

## Areas

One `area:` label says which part of cmux owns the issue. Two are allowed when
a report sits exactly on a seam (a command palette bug that is really about
IME input gets both). More than two means nobody can act on it, so the rules
leave those alone and mark `needs-triage` instead.

`area: terminal`, `area: input`, `area: layout`, `area: sidebar`,
`area: workspaces`, `area: agents`, `area: cloud`, `area: remote`, `area: ios`,
`area: cli`, `area: settings`, `area: browser`, `area: command-palette`,
`area: appearance`, `area: notifications`, `area: updates`, `area: auth`,
`area: performance`, `area: localization`, `area: accessibility`,
`area: docs`, `area: build-and-ci`.

[`.github/labels.json`](../.github/labels.json) carries a one-line description
of each, which is what shows in the GitHub label picker.

`needs-triage` means the rules could not pick: either the title matched nothing
or it matched three areas at once. About a third of the backlog is in this
state, and that is the honest number. Clearing `needs-triage` is useful work
and needs no build.

## How a new issue gets labeled

[`.github/workflows/auto-triage.yml`](../.github/workflows/auto-triage.yml)
runs [`scripts/ci/auto_triage.py`](../scripts/ci/auto_triage.py) when an issue
is opened or reopened. It applies the labels the rules propose and leaves one
comment naming the rule that fired.

It runs **once per issue** and only when the issue has no severity, `area:` or
`needs-triage` label yet. So:

- **To overrule it, change the labels.** They stay changed. The bot does not
  run on `edited` or `labeled`, so it cannot argue back.
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
thousand notifications. Every bulk pass writes a receipt, and the receipt is
what makes it reversible. Keep it.

Tests for all of this: `tests/test_triage_rules.py`.
