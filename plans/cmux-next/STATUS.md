# cmux-next readiness status

**Checked:** 2026-10-15 13:07 UTC

This page records the live branch and nightly evidence. A published artifact is
listed separately from a branch or workflow that has only been queued or checked.

## Branch and merged work

`feat-cmux-next` is at [`e728f7c5339d`](https://github.com/manaflow-ai/cmux/commit/e728f7c5339db2df43f6e5c4366610dafeec413b). The most recent successful
`nightly-next` decision used [`5925e7e86da5`](https://github.com/manaflow-ai/cmux/commit/5925e7e86da5a54183d55881a035ec45271df6c2), so the branch has advanced by
35 first-parent commits since that check. Recent merged PRs in the current head
include:

| PR | Merged change |
| --- | --- |
| [#21022](https://github.com/manaflow-ai/cmux/pull/21022) | Preserve terminal font zoom across daemon reconnects |
| [#21014](https://github.com/manaflow-ai/cmux/pull/21014) | Exercise sandbox probes with paths containing spaces |
| [#21013](https://github.com/manaflow-ai/cmux/pull/21013) | Preserve a font change made before tab records arrive |
| [#21006](https://github.com/manaflow-ai/cmux/pull/21006) | Answer XTVERSION and terminal size/terminfo queries |
| [#20995](https://github.com/manaflow-ai/cmux/pull/20995) | Use the renamed Computer menu in the composer gallery |
| [#20992](https://github.com/manaflow-ai/cmux/pull/20992) | Load What's New notes within the first-paint hold |
| [#20990](https://github.com/manaflow-ai/cmux/pull/20990) | Give a new tab its final size on the first frame |
| [#20989](https://github.com/manaflow-ai/cmux/pull/20989) | Isolate the cmux-tui daemon test promote-time pool |
| [#20988](https://github.com/manaflow-ai/cmux/pull/20988) | Fit permission-ask answers in a narrow agent pane |
| [#20987](https://github.com/manaflow-ai/cmux/pull/20987) | Record per-turn model, token, cost, and session totals |
| [#20986](https://github.com/manaflow-ai/cmux/pull/20986) | Make an already-published recovered nightly a no-op |
| [#20984](https://github.com/manaflow-ai/cmux/pull/20984) | Add debug-gated composer top-strip variants |

## Nightly evidence

### Published

- The published `nightly` release is [`0.65.1-nightly.3850749966902`](https://github.com/manaflow-ai/cmux/releases/tag/nightly). Its Sparkle feed was published at 2026-10-14 05:01 UTC and points to the universal DMG [in the appcast](https://github.com/manaflow-ai/cmux/releases/download/nightly/appcast.xml).
- The release metadata targets `main`, not `feat-cmux-next`. This proves the public nightly artifact and feed, but does not prove that the current `feat-cmux-next` head is in that artifact.

### Unverified for the current head

- [`cmux-next` run 38738915569](https://github.com/manaflow-ai/cmux/actions/runs/38738915569) for `e728f7c5339d` was still **in progress** at this check; [`run 38738814162`](https://github.com/manaflow-ai/cmux/actions/runs/38738814162) was **pending**.
- [`nightly-next` run 38733028105](https://github.com/manaflow-ai/cmux/actions/runs/38733028105) completed successfully for `5925e7e86da5`, but its build, signing, notarization, and publication jobs were skipped. It is a successful decision/check, not a published `feat-cmux-next` artifact.

Until the current-head `cmux-next` checks complete and a release/feed points at
that head, treat `feat-cmux-next` nightly readiness as **unverified**.

