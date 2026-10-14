# Re-check F1: composer Send submits to Codex on the first try

Phone: Demo build of feat-cnx-ios-codexqa at origin/feat-cnx-ios 224d15e9 (merge of design-terminal 60f6a531,
"composer submits as one paste, then Return"), new iOS 26.5 iPhone 17 Pro simulator, dev account.
Mac: the pass-1 rig app (origin/feat-cnx-ios-mactry 1d56a3d7, tag cnx-e2e-1d56a3d7, mactry cnx-hostd, rig pairing).
Codex: codex-cli 0.162.1, real model calls. Recordings: `~/cnx-ios-e2e/codexqa-raw/r*.mp4` (not committed).

| Check | Result | Evidence |
| --- | --- | --- |
| Shell: composer `echo hi` + Send | **Pass**: ran on the first Send, `hi` printed | `artifacts/shots/r1-shell-draft.jpg`, `r1-shell-after.jpg` |
| Shell: composer keyboard return (`echo hello again` + return) | **Pass**: ran at once | `artifacts/shots/r1-shell-after.jpg` |
| vim insert mode: composer Send, then composer return | **Pass**: the file holds `first line from composer\nsecond line\n`; Esc and `:wq` work after | `artifacts/shots/r2-vim-insert.jpg`, `od -c` of the file |
| Codex: single line + Send | **Pass**: `Working` 1.27 s after the tap (first Send); answer streamed | `artifacts/shots/r3-single-draft.jpg`, `r3-single-done.jpg` |
| Codex: composer keyboard return key | **Pass**: `Working` 1.26 s after return (first try) | `artifacts/shots/r4-return-draft.jpg`, `r4-return-done.jpg` |
| Codex: multi-line draft (3 lines pasted into the composer field) + Send | **Pass**: arrived as ONE prompt (3 lines under one `›`), submitted on the first Send (`Working` at 2.69 s) | `artifacts/shots/r5-multiline-draft.jpg`, `r5-multiline-done.jpg` |
| Codex: draft with an image attachment + Send | **Fail against "first try" (by design today)**: Send uploads the photo and types `'<Mac path>.jpeg' describe this image in five words` into Codex's input WITHOUT Return; a second, empty Send submits (`Working` 1.32 s later) and Codex views the image (`Misty waterfall between lush cliffs.`) | `artifacts/shots/r6-attach-draft.jpg`, `r6-after-first-send.jpg`, `r6-attach-done.jpg` |

## Verdict
F1 is fixed for every text send: shell, vim insert mode, and Codex single line, multi-line and return key all
submit on the first try. Multi-line drafts reach Codex as one prompt.

Still open: Send with an attachment never presses Return (`TerminalModel.sendAttachments()` types
`commandLine(paths:text:)` with `pressReturn: false`, documented as "the person finishes the command line").
In Codex that reads as a Send that did nothing visible beyond filling the input. Suggest: when the draft has
text, finish with `ComposerSubmit` (paste, then Return); keep the no-Return behavior only for an attachment
with no text (a path dropped into a command line).

Load (1-min) during the run: 17.8-49.7. These are pass/fail checks, not timings; the shell check ran at 49.7.
Rig note: a second rig (tag cnx-e2e-604fc689, another session) was running at 12:29; this run waited until it
had quit (12:30) before launching, so the two never shared the dev account.
