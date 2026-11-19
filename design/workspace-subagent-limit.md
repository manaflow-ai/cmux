# Workspace subagent count

Leo: "i wanna be able to have cmux next be able to ad hoc increase/decrease subagent amounts"
and "right click edit subagent count" (ask-5941df09c0).

The workspace row's More > Options > Subagent Limit… uses the existing chat-limit
dialog: one labelled count field, Cancel, Use Default and Set. The palette exposes
Workspace Subagent Limit…. It uses the standard dialog spacing, typography and
buttons. No additional animation or custom chrome is introduced. Reference:
`manaflow-ai/cmux-design-references/apps/claude/live/browser-tab-context-menu.png`
and the existing chat Subagent Limit dialog from #24061.

The field starts with the workspace override, or an empty value with the global
default as its placeholder. The caption says it applies to each local chat and
that a chat's own limit takes precedence. Set changes the workspace's saved
`maxRunning`; Use Default clears it. The daemon wakes queued sub-sessions when
capacity increases. Reducing it lets running work finish. The UI never changes
the global setting.

This first slice exposes the existing daemon operation for local workspaces.
The number field matches the chat control; a slider is not part of this slice.
Remote workspaces do not show this action: their chat creation does not carry a
local workspace ID. Existing chats without workspace metadata remain outside
the workspace override. The earlier 50-open-child cap was raised in #30231;
this change does not alter admission or the current numeric range.

The original menu was removed from #24061 because new chats lacked workspace
metadata. #24306 added that metadata but the menu was never restored. Regression
detectors: `SubagentLimitTests.workspaceReadSetAndClearUseTheWorkspaceScope`,
`unsetWorkspaceShowsTheGlobalDefault`, and `onlyAPersonOpensTheDialog`.
The existing workspace-stamping and daemon scheduling tests cover the other
ends of the connection. Capture through `debug.dialog open` with
`subagentWorkspaceDefault`, `subagentWorkspaceCustom`, and `subagentWorkspaceOne`.
