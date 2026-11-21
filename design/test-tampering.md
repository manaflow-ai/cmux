# Test tampering alarm

The alarm is a turn-level state transition drawn beside the turn prompt:

`no finding → compact red disclosure → expanded evidence → restored or restore failed`.

The compact state keeps the transcript geometry stable and names the count of suspicious test
changes. Expanding the disclosure reveals the exact path, line, reason, and old/new hunk text. The
actions restore the matching hunk through a person-authorized acpmux request referencing durable edit evidence and ask the agent for its
reason through the normal turn send path. Restore is disabled while in flight and reports a
terminal success or failure inline. No timer or per-token detector work is used; evidence is deduplicated
once per edited turn and only rendered for visible rows.

The chosen variant is the compact disclosure: it uses the existing edited-files card's vertical
rhythm, a single status mark, and a one-line expansion affordance. The gallery also keeps an
expanded evidence variant and a multi-file variant for review.

Restore is available on authenticated local app connections on Linux and Apple hosts. Unproved remote
connections keep the evidence and Ask why action. Missing context, changed files, ambiguous
matching blocks, and paths escaping the session folder are refused without writing.
At commit, Restore atomically exchanges the file with its replacement and retains the displaced
inode beside it as `.cmux-test-restore-<id>`. The RPC returns that recovery path. A writer racing
the final check, including one with an open descriptor, keeps its data in that recovery file.
There is one retained file per successful Restore, normally bounded by the 4 MiB input limit;
an external writer can still grow its own inode. There is no automatic deletion of recovery files.

The transcript adds one stable alarm row outside folded tool groups as soon as an edit reports
a finding. It keeps that row identity when the turn ends and is independent of edited-file
card visibility and session aggregation settings. It introduces no animation.
