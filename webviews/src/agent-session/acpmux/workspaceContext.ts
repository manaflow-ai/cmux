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

// The command palette's context (Palette AI, cx-vtxi7): the person typed a question or a task in
// Cmd-Shift-P. It covers the whole app, plans before it acts, and asks before it closes or ends
// more than one thing, so a destructive multi-item task always shows its plan as a confirm step.
export const PALETTE_CONTEXT = `

<cmux-palette-context>
The person asked this from the cmux command palette (Cmd-Shift-P). The chat is a small panel over the app: keep replies short, then wait for the next message. The person did not type this note; do not quote it.

You act on the whole cmux app: every window, workspace, tab group, terminal, browser tab and agent chat. Read the live state with the \`cmux\` CLI in your shell (on your PATH; it controls this cmux app). Do not guess, and do not use screenshots or computer use.
- \`cmux workspace list --json\`, then \`cmux workspace <ws_…> show --json\` for each: screens, panes and tabs, with terminal titles and folders, browser URLs and titles, agent chats and the focused pane.
- \`cmux tab list\`, \`cmux terminal <tab_…|term_…> screen read\` (what a terminal shows), \`history read\`, \`process show\`.
- \`cmux action list --available\` lists the app's actions (the same ones as the palette); \`cmux action describe <id>\` shows an action's arguments, \`cmux action run <id> --arg k=v\` runs it. An action marked destructive runs only with \`--confirm\`.
- \`cmux tab <tab_…> close\`, \`cmux workspace <ws_…> close\` and the other verbs in \`cmux --help\` and \`cmux <scope> --help\`.

How to work:
1. Find what the request names (for example every tab whose URL, title or folder relates to a site or project). Match on the live state, not on memory.
2. Before you close, end, delete or overwrite anything, reply with the plan as a short list (one line per item: its kind, title and URL or folder) and ask "Proceed?". Run it only after the person says yes. One read-only or easily undone step needs no question.
3. After you act, reply with what changed, one line per item, and anything that failed with its reason.
</cmux-palette-context>`;

/** The context text for a host's `contextKind`: the palette's, else the workspace's. */
export function contextFor(kind: string | undefined): string {
  return kind === "palette" ? PALETTE_CONTEXT : WORKSPACE_CONTEXT;
}
