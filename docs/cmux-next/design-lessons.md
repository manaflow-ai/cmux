# Design lessons from cmux's fixes

We labelled every fix, revert and base-red commit on `main` and `feat-cmux-next` since January 2026 (6,333 of them)
by what caused it. These are the classes that keep coming back. Each one gives the rule that prevents it, examples, what
catches it, and what it has cost so far. Read this before you design a change, fix a bug or write a test.

Leo, 2026-11-07: "this was a good design from the start because it can evolve ... because, oh, this is able to rapidly
invalidate things."

## 1. Run the check before you merge, on the merged tree

**Class:** a check that already existed went red on `feat-cmux-next` after a change merged. It might have been a test
still asserting the old behavior, a ratchet or lint, a compile error, or two changes that were each green alone.

**Rule:** before merging, run every check `feat-cmux-next` runs over the files you touch, against your change merged
with the current tip. A guard says which inputs it reads, so routing by paths can't skip it.

**Examples:** [#36502](https://github.com/manaflow-ai/cmux/pull/36502) (arch ratchet, red 6.6 h after the merge),
[#35987](https://github.com/manaflow-ai/cmux/pull/35987) (the determinism check was routed by changed files and never
ran on the change), [#32348](https://github.com/manaflow-ai/cmux/pull/32348) (#32244 moved a type that #32271 and
#32300 still imported from the old module).

**Cost:** 571 of 669 base reds (85%). The median is 1.5 to 7.4 hours from culprit to fix, depending on the kind of check,
and every PR touching the area stays red in the meantime. Pull requests broke the base about as often per landing as
direct pushes did.

## 2. Tests pin what a person sees

**Class:** a deliberate behavior change left a test asserting the old markup, offset or element.

**Rule:** a test states the behavior the surface's design spec describes, not today's class names or pixel offsets.
When the design changes, the spec and its test change in the same PR.

**Examples:** [#32264](https://github.com/manaflow-ai/cmux/pull/32264) (spinners were removed; two tests still
asserted one), [#33614](https://github.com/manaflow-ai/cmux/pull/33614) (four transcript tests followed four changes
to one line), [#32828](https://github.com/manaflow-ai/cmux/pull/32828) (a markup scan read a code comment as markup).

**Cost:** 51 base reds, 35 of them in `webviews`. Median 7.4 hours to fix, the slowest kind.

## 3. A test takes a clock

**Class:** a test slept and then asserted, or measured wall time on a busy machine.

**Rule:** inject the clock and await the event. No real sleeps and no wall-clock assertions.

**Examples:** [#35987](https://github.com/manaflow-ai/cmux/pull/35987) (a 2 s sleep, then an assert on elapsed time),
[#35999](https://github.com/manaflow-ai/cmux/pull/35999), [#26883](https://github.com/manaflow-ai/cmux/pull/26883)
("wait for their event, not a wall-clock limit").

**Cost:** 141 fixes, 35 of them base reds.

## 4. One source of truth; anything derived regenerates itself

**Class:** two copies of one fact drifted apart, or a generated, bundled or lock file wasn't rebuilt with its source.

**Rule:** derive instead of copying. Find tests by their attribute, not from a hand-kept list. Where a copy has to
exist, the base autofix regenerates it, and a check fails when a committed copy has no generator.

**Examples:** [#22877](https://github.com/manaflow-ai/cmux/pull/22877) (a stylesheet changed but the committed page
wasn't rebuilt), [#36580](https://github.com/manaflow-ai/cmux/pull/36580) (a hand list of display tests missed a new
one), [#10518](https://github.com/manaflow-ai/cmux/pull/10518) (keyboard pinning rebuilt on one geometry authority).
The right shape: [#36957](https://github.com/manaflow-ai/cmux/pull/36957), where the autofix now syncs the bundled
copies itself.

**Cost:** 72 generated-file fixes and 160 fixes where two copies drifted.

## 5. Cost stays constant as things grow

**Class:** work grew with the number of workspaces, panes or messages, or ran with no bound.

**Rule:** every loop, timer and observer has a bound and a stop condition. Work scales with what's visible, not with
the total.

**Examples:** [#7182](https://github.com/manaflow-ai/cmux/pull/7182) (O(hosted panes) work on every run-loop tick froze
the main thread), `9660608040d5` (`NSOpenPanel()` built on the main thread blocked it for 40 s when its service didn't
answer).

**Cost:** 503 fixes.

**Guards:** in webviews, the dev-server `dom-breadth`, `live-intervals` and `long-frame` budgets (pages the dev server serves; built bundles
carry none) and the `layout-thrash-in-loop` lint ([modding-kit.md](modding-kit.md)); in cmux-tui, clippy's `await_holding_lock`.

## 6. A visible change is one state transition

**Class:** flicker, a jump, pop-in, a blink, or a layout that moved after the animation finished.

**Rule:** give each visible state one owner. Name the start and end states, and move every affected element between
them together. Nothing gets laid out after the animation ends.

**Examples:** [#11530](https://github.com/manaflow-ai/cmux/pull/11530) (terminal text bled outside its pane during a
live resize), [#24902](https://github.com/manaflow-ai/cmux/pull/24902) (reply fades now follow the host's motion),
[#10518](https://github.com/manaflow-ai/cmux/pull/10518).

**Cost:** 597 fixes, the largest product class. The sidebar and the browser have the most.

**Guards:** in webviews, the dev-server `layout-shift` and `react-commit` budgets ([modding-kit.md](modding-kit.md));
the no-flicker browser tests. Native UI has none yet beyond tests.

## 7. Lifecycle edges are the normal case

**Class:** a start, close, resume or reconnect raced work in flight, or a cached value outlived its source.

**Rule:** derive state from its source, or carry the version it was read at. Every async step says what happens if
its owner goes away partway through.

**Examples:** `cf41b36eb088` (Close Other Tabs left live browser tabs out of its batch, so one close became many
Reopen steps), `f9c0d5145216` (removing someone from a team left their route tokens valid until a cache expired).

**Cost:** 470 lifecycle fixes and 555 stale-state fixes.

## When you fix a base red or revert

- Name the culprit in the title, `base red: ... (from #N)`. That's how repeat areas show up.
- Say why in a revert, and what would show it's safe to bring back
  ([#25826](https://github.com/manaflow-ai/cmux/pull/25826) does this). 60% of reverts say only "This reverts commit X".
- A failing test written first proves something only if it fails for the right reason. Read the failure before you
  write the fix ([#32065](https://github.com/manaflow-ai/cmux/pull/32065) fixed a test that never passed).
