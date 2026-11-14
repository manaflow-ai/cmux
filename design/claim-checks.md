# Claim checks

A reply often ends with a claim someone can check: "all tests pass", "the build succeeds", "lint is
clean", "typecheck passes", "I ran `X`". acpmux checks those claims against the turn's own command
runs once, when the turn ends (`cmux-tui/crates/acpmux/src/hub/claim_check.rs`). It logs one
`claim_checks` record before `turn_end`, so a pane that attaches later reads the result with the
turn and never rescans history.

A claim has one of three verdicts:

- **backed**: the newest run in the turn that matches the claim exited 0.
- **failed**: the newest matching run did not exit 0.
- **none**: no run in the turn matches the claim.

A claim the matcher can't classify gets no mark at all. That covers a hedged or negated sentence
("should pass", "don't pass yet"), a kind no pattern knows, and a phrase inside code. It also covers
a run whose exit status doesn't speak for the command: one that pipes, chains with `;` or `||`, or
runs in the background. A mark is never a guess.

## Look

The shipped treatment colors the phrase's underline: success green when backed, danger red when
failed, and a dashed danger underline when nothing ran. Hovering shows what backs the claim ("Backed:
cargo test passed in this turn"). A click shows the run's row and opens the turn's "Worked for" fold
if the row is inside it (`showCall`, the waterfall's jump). The mark is an inline link, never a button
(a button is an atomic box that would pull a wrapped phrase onto one line). It adds no width and no
height, so nothing on the reply's lines moves when a turn's checks arrive. It draws only on a finished reply,
never on text that is still revealing, and it has no animation, timer or observer, with or without
Reduce Motion.

References in `cmux-design-references/index.json`:

- `cmux/live/transcript-tab-switch-layout-shift`: a transcript must not shift under the reader.
  This is why the mark is an underline and not an inserted badge.
- `cmux/live/transcript-pr-reference-autolink`: inline marks in prose stay quiet, and the transcript
  decorates only what it knows. This is why an unclassified claim gets nothing.
- `claude/live/transcript-markdown-rendering`: inline chips in a reply sit at body size and use
  existing tokens.

## Gallery

`agent-pane.claim-checks` puts three looks side by side across the four fixture turns (a true claim,
a false claim, a claim with no run, and a claim whose last run failed):

- **underline** (selected): colored underline only. It causes no reflow.
- **glyph**: a small check or cross after the phrase. It is easier to scan, but each glyph widens its
  line when the checks arrive.
- **chip**: a pill after the phrase that names the command. It carries the most information, but it
  is loud and wraps lines in a narrow pane.

## Limits

The matcher reads only the turn's last reply, from the text acpmux already keeps for it (64 KiB at
most). A longer reply gets no checks. Runs are matched by command shape (`cargo test`, `bun run
lint`, `tsc`, `pytest` and so on), not by reading their output.
