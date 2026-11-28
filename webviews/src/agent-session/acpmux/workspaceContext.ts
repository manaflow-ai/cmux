// The workspace context of a chat opened for its workspace (Cmd-I's chat dock, cx-ihyx2): the
// first prompt carries it as `_meta.acpmux.context`. acpmux sends it to the agent after the
// person's text and keeps it out of the transcript, the chat list preview and the title, so the
// person's own words are the only visible message. It names no ids: the agent reads the live
// workspace through the cmux CLI, which finds this chat's workspace from the agent's session
// (`CMUX_AGENT_SESSION`, `cmux app identify`), so nothing in it goes stale.
//
// l10n-allow-file: it is text for the agent, not the person, so it is not localized.

// It starts on its own line: a harness that joins it to the person's text with no break (Codex)
// still keeps the person's words alone on the first line, where titles come from.
export const WORKSPACE_CONTEXT = `

<cmux-workspace-context>
This chat is docked on the left of a cmux workspace. The person opened it with Cmd-I to work on what that workspace shows: its terminals, browser tabs and project files. The person did not type this note; do not quote it.

Read the workspace's live state with the \`cmux\` CLI in your shell (on your PATH; it controls this cmux app) before you answer about it. Do not guess, and do not use screenshots or computer use for this: the CLI reads a terminal's text directly.
- \`cmux app identify --json\`: where this chat is. \`caller.workspace\` is this workspace (ws_…); \`beside\` is the column right of this chat, where tabs you open appear.
- \`cmux workspace <ws_…> show --json\`: its screens, panes and tabs, with terminal titles and folders, browser URLs and the focused pane.
- \`cmux terminal <tab_…|term_…> screen read\`: what a terminal shows now. \`history read\` gives its scrollback, \`process show\` its running command.
- \`cmux terminal <tab_…|term_…> write --text '…'\` types into a terminal and \`keys ctrl+c\` sends keys. Ask first before you type into a terminal the person uses.
- \`cmux pane <pane_…> run -- <argv…>\` runs a command in a new terminal tab of that pane.
- \`cmux --help\` and \`cmux <scope> --help\` list the rest. The cmux-browser skill drives browser pages.
</cmux-workspace-context>`;
