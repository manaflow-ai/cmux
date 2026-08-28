# cmux-tui current state

## Wave 92 authoritative snapshot

Snapshot: 2026-08-28T14:10:26Z. Current `main`: `87e71b229ca8337f86d0c67e5761413abacc6a34`.

Merged TUI work:

| PR | Source head | Merge commit | Merged at |
| --- | --- | --- | --- |
| [#11030](https://github.com/manaflow-ai/cmux/pull/11030) | `4295e446dcdc2b0c52e0084dd5a1ec31c35d0f25` | `0ba31a2883577f1dea06957627c0c753955d0e8d` | 2026-08-28T02:55:15Z |
| [#11055](https://github.com/manaflow-ai/cmux/pull/11055) | `9487a6cc5ac141b270cf2235a9638b750baf0124` | `6dc9dea996585cde55bdba8209146e0908ce8526` | 2026-08-28T11:38:07Z |
| [#11025](https://github.com/manaflow-ai/cmux/pull/11025) | `478a6f96084738e699d94afabbd96041beee4778` | `e45af147e9677e844c611e83b1a32cbda7711ebd` | 2026-08-28T12:11:04Z |
| [#11113](https://github.com/manaflow-ai/cmux/pull/11113) | `ba9a5581cf8a57dae070531ac27a151b7b780c38` | `495477e5716bfda23acfb424867cfd4d2ff7e863` | 2026-08-28T12:54:21Z |
| [#11028](https://github.com/manaflow-ai/cmux/pull/11028) | `a703004f4eb714f7a9ecdda774bf54beb1304c0c` | `b91d338727659adc55465b989babd076cdaa3baf` | 2026-08-28T13:36:34Z |
| [#10993](https://github.com/manaflow-ai/cmux/pull/10993) | `87974b03cf311c481a37b5ce41f32cb2f24abfb0` | `87e71b229ca8337f86d0c67e5761413abacc6a34` | 2026-08-28T14:04:34Z |

Current candidate heads and deferred work are listed in `PR-INTENT-BOARD.md`. Session total is `unknown`. This snapshot uses sanitized evidence IDs; local receipt details are intentionally omitted.

Rollback rule: run `git rev-list --parents -n 1 <sha>` first. One parent uses `git revert <sha>`; two parents use `git revert -m 1 <sha>`. Run focused checks before merging the revert.
