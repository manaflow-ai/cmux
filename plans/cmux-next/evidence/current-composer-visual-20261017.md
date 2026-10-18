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
