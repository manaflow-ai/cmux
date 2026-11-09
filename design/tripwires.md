# Plan tripwires

The plan approval menu offers **Write tripwires first**. Its detail says that it starts a new
worktree and writes checks before building. Approve plan and the other build choices keep their
existing behavior. The new child receives the approved plan and an instruction to write a few real
test files, declare their paths, and run those paths explicitly as it implements the plan.

The declaration is bounded to eight checks and stays fixed. The chat header displays one small
marker and an abbreviated name per check. Grey means no matching run in the current turn, green
means the latest trustworthy matching test command exited successfully, and red means it failed.
Names and positions stay fixed when evidence changes; only color and the accessible description
change. The strip has no animation, observer, or timer, including under Reduce Motion.

The closing recap repeats that turn's checks, including failed and unrun checks. Historical recaps
retain their own results when a later turn runs. A new turn clears passing evidence: a run before
further edits does not certify the next turn. Selecting a result opens its recorded tool call when
the transcript has it. This first version shows evidence; it does not prevent the agent from
writing “done” or ending a turn.

## Reference and variants

Private reference: `cmux-design-references/apps/claude/live/transcript-tool-rows-and-task-list.png`,
indexed by `cmux-design-references/index.json`; surface guidance:
`leo-workspace/design/chat-transcript.md` and `design/claim-checks.md`.
The design uses small circular markers, quiet text, and existing transcript spacing.

`agent-pane.tripwire-status` contains three looks: dots (selected for the header), underlines,
and rows (selected for the recap), with all-green, one-red, and never-run fixtures. Dots use the
least space in the header. Rows expose the test paths in the recap without hiding unresolved work.

## Evidence boundary

The daemon reuses the claim-checker's observed terminal calls and shell-safety classification.
It matches a declared path in a test command, not output prose, the agent's success claim, or a
general command that never names the file. A passing command is evidence about that invocation,
not proof that the test exhaustively captures intent. Unsafe shell shapes never manufacture a
green result. Matching and rendering work is bounded by eight declarations and the claim-checker's
existing bounded run history, and happens at turn boundaries rather than on streamed tokens.

Detectors: Rust tripwire fixtures exercise success, failure, missing evidence, exact path matching,
and latest-run precedence; web replay fixtures exercise historical recap and header isolation.
