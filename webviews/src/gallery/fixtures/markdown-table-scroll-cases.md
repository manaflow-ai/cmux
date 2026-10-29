# Markdown table scrolling test

Each table below is wider or taller than the pane. Scroll each one sideways
(trackpad swipe, Shift+wheel) and check that the page itself doesn't scroll.

## 1. Wide table (20 columns)

| #   | Agent | Title              | Group            | Branch         | Status  | Started          | Updated          | Commits | Tests | Fleet run    | Host    | CPU | Memory | Disk | Owner | Priority | Notes                            | Link             | Verified |
| --- | ----- | ------------------ | ---------------- | -------------- | ------- | ---------------- | ---------------- | ------- | ----- | ------------ | ------- | --- | ------ | ---- | ----- | -------- | -------------------------------- | ---------------- | -------- |
| 1   | a207  | Sidebar scroll lag | Performance      | feat-cmux-next | running | 2026-10-20 04:10 | 2026-10-20 04:55 | 3       | 12/12 | 7239a6431560 | mini-10 | 42% | 1.2 GB | 81%  | Chief | high     | measuring 10/100/500 workspaces  | example.com/a207 | no       |
| 2   | a208  | Inspect Element    | Browser & parity | feat-cmux-next | running | 2026-10-20 04:20 | 2026-10-20 04:58 | 1       | 4/6   | 5ea63eb78f91 | mini-11 | 18% | 900 MB | 92%  | Chief | medium   | DevTools commands in Cmd+Shift+P | example.com/a208 | no       |
| 3   | a210  | Tab min width      | Sidebar & tabs   | feat-cmux-next | queued  | 2026-10-20 04:30 | 2026-10-20 04:31 | 0       | 0/0   | —            | mini-20 | 3%  | 200 MB | 40%  | Chief | low      | first-principles minimum width   | example.com/a210 | no       |

## 2. One very long cell

| Key   | Value                                                                                                                                                                                  |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| short | ok                                                                                                                                                                                     |
| long  | ThisIsOneVeryLongUnbrokenTokenWithNoSpacesThatShouldForceHorizontalScrollingInsteadOfWrappingOrOverflowingThePaneEdge_0123456789_ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz |
| url   | https://github.com/manaflow-ai/cmux/blob/feat-cmux-next/plans/cmux-next/a-very-long-path/that/keeps/going/and/going/markdown-omnibar-DESIGN.md                                         |

## 3. Code inside cells

| Command | Example                                                                                                       | Output                                  |
| ------- | ------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| split   | `cmux pane pane_0f51b2b2017235ef8af3822f4fd6093b split --right --viewport-width 0.5 --focus false`            | `pane_ae19a2f5ce2be31d6ed6fd8527179a13` |
| tab     | `cmux tab create browser --pane pane_0f51b2b2017235ef8af3822f4fd6093b --url http://127.0.0.1:8766/index.html` | `tab_a85e8fa1d64d23f8e85a40e7107346bc`  |

## 4. Tall table (40 rows)

| Row | A     | B     | C       | D     |
| --- | ----- | ----- | ------- | ----- |
| 1   | alpha | bravo | charlie | delta |
| 2   | alpha | bravo | charlie | delta |
| 3   | alpha | bravo | charlie | delta |
| 4   | alpha | bravo | charlie | delta |
| 5   | alpha | bravo | charlie | delta |
| 6   | alpha | bravo | charlie | delta |
| 7   | alpha | bravo | charlie | delta |
| 8   | alpha | bravo | charlie | delta |
| 9   | alpha | bravo | charlie | delta |
| 10  | alpha | bravo | charlie | delta |
| 11  | alpha | bravo | charlie | delta |
| 12  | alpha | bravo | charlie | delta |
| 13  | alpha | bravo | charlie | delta |
| 14  | alpha | bravo | charlie | delta |
| 15  | alpha | bravo | charlie | delta |
| 16  | alpha | bravo | charlie | delta |
| 17  | alpha | bravo | charlie | delta |
| 18  | alpha | bravo | charlie | delta |
| 19  | alpha | bravo | charlie | delta |
| 20  | alpha | bravo | charlie | delta |
| 21  | alpha | bravo | charlie | delta |
| 22  | alpha | bravo | charlie | delta |
| 23  | alpha | bravo | charlie | delta |
| 24  | alpha | bravo | charlie | delta |
| 25  | alpha | bravo | charlie | delta |
| 26  | alpha | bravo | charlie | delta |
| 27  | alpha | bravo | charlie | delta |
| 28  | alpha | bravo | charlie | delta |
| 29  | alpha | bravo | charlie | delta |
| 30  | alpha | bravo | charlie | delta |
| 31  | alpha | bravo | charlie | delta |
| 32  | alpha | bravo | charlie | delta |
| 33  | alpha | bravo | charlie | delta |
| 34  | alpha | bravo | charlie | delta |
| 35  | alpha | bravo | charlie | delta |
| 36  | alpha | bravo | charlie | delta |
| 37  | alpha | bravo | charlie | delta |
| 38  | alpha | bravo | charlie | delta |
| 39  | alpha | bravo | charlie | delta |
| 40  | alpha | bravo | charlie | delta |

## 5. Alignment and a table that fits

| Left        | Center |  Right |
| :---------- | :----: | -----: |
| a           |   b    |   1.00 |
| longer text |  mid   | 123.45 |

This one should not scroll at all.
