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
