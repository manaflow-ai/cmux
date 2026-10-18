# Current composer visual fixture

## Mandate

- **Surface:** the current `agent-pane.new-tab` composer and its quiet recent-chat list.
- **Baseline:** latest `feat-cmux-next` at `2af116d02dda101f50b467d9131a04925dbbfe89`.
- **Target branch:** `leo/current-composer-visual-20261017`.
- **Scope:** one named visual-only gallery variant, the canonical gallery runner, and receipts for normal/narrow dark/light states.
- **Out of scope:** the `Release` workspace-switch journey, native workspace switching, product styling changes, and provider/account data.
- **Fixture contract:** `agent-pane.new-tab#current-composer`, seeded local chats only, no typed text, no network, locale `en`, fixed gallery clock, Apple System Colors dark/light, Chromium, 760x560 and 420x560.
- **Play IDs:** `current-composer-normal-dark`, `current-composer-normal-light`, `current-composer-narrow-dark`, `current-composer-narrow-light`.
- **Acceptance:** ready stage, current composer controls visible, five quiet chat rows, no `Release` journey rows, no console/page/request errors, and stable PNG receipts.
- **Managed budget:** one four-case Chromium run; warning-only performance thresholds; no PR and no merge to `feat-cmux-next`.

## Ledger

| candidate_id | owner | base_sha | head_sha | fixture_version | implemented | reviewed | tested | integrated | state | next action |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| current-composer-v1 | primary | `2af116d02dda101f50b467d9131a04925dbbfe89` | `f80bb7ca88a059692a703ef92f2091109ba58aad` | `current-composer/v1` | yes | pending | pending | no | active | run the four managed gallery plays |

## Managed receipt

- **Run:** [39089231277](https://github.com/manaflow-ai/cmux/actions/runs/39089231277)
- **Artifact:** [current-composer-3b46b53](https://github.com/manaflow-ai/cmux/actions/artifacts/12122027495)
- **Exact tested head:** `3b46b53ecf01300420a12eb0ebb120b66e73796f`
- **Runner:** `github-actions/ubuntu-24.04`, Chromium, ready stage `1` for all four states.
- **Receipt JSON SHA256:** `0125be155545ca0258df7626bbe4258a52d952fd049f226683e9bcdf7c600a6c`
- **PNG SHA256:** normal-dark `987d08fd023ff5be1ded7c571bcc900eacf5fc774cef7b04de1794475504accc`; normal-light `31747e76190f0a389ea71ee7d15fd9f740b06061c0167e4cd4bd4f48e01d4b4e`; narrow-dark `719150d5aa024043e8d0d234d94ecbda6e039e996aabfc22e38ac68e81ea416b`; narrow-light `59e62e077a529483f5518061632a598358a5841d12439795125348132add03b2`.
- **Receipt status:** all four PNG hashes rechecked locally; the visual-only fixture has no play steps by design (`play.status=none`).
- **External packet:** `/Users/leoli/Projects/briefs/current-composer-visual-20261017/managed-39089231277/managed-receipt.json`.
