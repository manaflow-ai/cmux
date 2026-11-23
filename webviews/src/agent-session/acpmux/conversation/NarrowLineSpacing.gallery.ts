// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// One-line rows, then a reply, in a narrow pane (Leo, 2026-11-22, on a pane about 270 px wide: the gap
// after "Background task / Webview round... / Sent a message" before the reply was much bigger than
// between the rows above: "maybe it's cuz the folding and tool calling and spacing got fucked up").
// A finished turn, then a turn the agent ran on its own after a background task ended: its command
// lines, the "New since you looked" line between two of them, and its reply. Every one-line row stands
// flush on the 22 pitch and the reply 16 under the last line, at 280 px as at 720 px
// (test/chat-sim-narrow-browser.test.ts holds the rule for every simulated chat).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { SINCE_DIVIDER, type AcpmuxRow } from "../model";

const BG = "bgturn-gallery";
const MARK = "gallery-session:narrow";

const rows = (since: boolean): AcpmuxRow[] => [
  user("Measure the webview round trip before and after the change.", 20, { id: "nl-prompt" }),
  activity([tool("Webview round-trip for Rust draft attachments", "execute", "completed")], 19.8, { id: "nl-run" }),
  assistant("Both measurements are running; I'll report when the after job finishes.", 19.5, { id: "nl-reply" }),
  summary(19.5, { id: "nl-footer", status: "completed", durationMs: 31_000 }),
  activity([tool("acpmux send helper-timing 'post the numbers'", "execute", "completed")], 6, {
    id: "nl-bg-1",
    inBackground: BG,
  }),
  activity([tool("git status --short", "execute", "completed")], 5.9, { id: "nl-bg-2", inBackground: BG }),
  ...(since ? [row(SINCE_DIVIDER, 5.85, { id: SINCE_DIVIDER, since: { key: MARK, seq: 41, turns: 1 } })] : []),
  activity([tool("Read the helper's timing table", "read", "completed")], 5.8, { id: "nl-bg-3", inBackground: BG }),
  assistant(
    "A helper's timing table is in: the round trip went from 41 ms to 12 ms. I've sent the helper the numbers to land it. Nothing you need to do.",
    5.5,
    { id: "nl-bg-reply", inBackground: BG },
  ),
];

export default agentPaneEntry({
  id: "agent-pane.narrow-line-spacing",
  title: "One-line rows then a reply, narrow and wide",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 280, normal: 720 },
  covers: [
    "agent-session/acpmux/conversation/messageRuns.ts",
    "agent-session/acpmux/conversation/SinceDivider.tsx",
    "agent-session/acpmux/transcriptGrid.ts",
  ],
  keywords: ["spacing", "narrow", "one-line rows", "new since", "background turn"],
  variants: {
    lines: {
      note: "A turn the agent ran on its own: its command lines flush on the 22 pitch, its reply 16 under them, at every width.",
      snapshot: chat(rows(false)),
    },
    "lines-new": {
      note: "The New line between two of its command lines: on the boundary, New on the line at its end; no row moves.",
      snapshot: chat(rows(true), { sinceKey: MARK }),
    },
  },
});
