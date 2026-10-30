// l10n-allow-file: gallery fixtures (sample prompt, thought, commands), not shipped UI.
// The chat menu's Transcript view (conversation/transcriptView.ts; Leo, 2026-10-29: "i like these
// kinds of settings from claude code desktop..."): the submenu open, then one finished turn in each
// view, each picked through the real menu. Normal is today's compact transcript; Thinking opens the
// thought; Verbose also opens the commands and their output.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play, PlayContext } from "../../../gallery/play";
import { activity, assistant, chat, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";

const snapshot = chat([
  user("Why does the retry test fail on CI?", 6, { id: "transcript-view-user" }),
  activity(
    [
      thought(
        "The test waits on real timers. On a loaded runner the second retry lands after the assertion, so check how the helper schedules its delay before touching the test.",
        { startedAt: 0, endedAt: 9_000 },
      ),
      tool("Read src/net/retry.ts", "read", "completed", { locations: [{ path: "src/net/retry.ts" }] }),
      tool("bun test src/net/retry.test.ts", "execute", "failed", {
        command: "bun test src/net/retry.test.ts",
        exitCode: 1,
        output: "retry.test.ts:\n✗ backs off between attempts [212ms]\n  Expected: 2 calls\n  Received: 1 call\n\n0 pass\n1 fail",
      }),
      tool("rg -n setTimeout src/net", "execute", "completed", {
        command: "rg -n setTimeout src/net",
        output: "src/net/retry.ts:41:    await new Promise((done) => setTimeout(done, delay));",
      }),
    ],
    5.8,
    { id: "transcript-view-work" },
  ),
  assistant(
    "The test races real timers: the helper sleeps with `setTimeout`, and on a busy runner the second attempt lands after the assertion. Using fake timers in the test makes it deterministic.",
    5,
    { id: "transcript-view-answer" },
  ),
  summary(5, { id: "transcript-view-summary", status: "completed", toolCount: 3, durationMs: 48_000 }),
]);

/// Opens the chat menu and its Transcript view submenu.
async function openSubmenu(ctx: PlayContext): Promise<void> {
  await ctx.click({ role: "button", name: "Chat actions" });
  await ctx.click({ role: "menuitem", name: "Transcript view" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menuitemradio"][aria-checked="true"]'));
}

/// Picks `name` in the submenu; the menu closes and `drawn` shows.
const pick =
  (name: string, drawn: string): Play =>
  async (ctx) => {
    await openSubmenu(ctx);
    await ctx.click({ role: "menuitemradio", name });
    await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
    await ctx.waitFor(() => ctx.document.querySelector(drawn));
  };

export default agentPaneEntry({
  id: "agent-pane.transcript-view",
  title: "Transcript view: Normal, Thinking, Verbose",
  area: "Agent pane",
  height: 620,
  covers: [
    "agent-session/acpmux/conversation/transcriptView.ts",
    "agent-session/acpmux/header/transcriptViewRow.ts#transcriptViewRow",
  ],
  variants: {
    "menu-open": {
      note: "Chosen: the chat menu's Transcript view submenu, as Claude Code desktop's: Normal, Thinking, Verbose with a check on this chat's view, then Make Normal the default (off while the chat shows the default).",
      snapshot,
      play: openSubmenu,
    },
    normal: {
      note: "Normal (the default): the thought and the commands fold, one line each.",
      snapshot,
    },
    thinking: {
      note: "Play: Thinking from the menu. The thought opens; the commands stay folded.",
      snapshot,
      play: pick("Thinking", '.cv-thought[aria-expanded="true"]'),
    },
    verbose: {
      note: "Play: Verbose from the menu. The thought, the command group and each command's output open.",
      snapshot,
      play: pick("Verbose", '.cv-command[aria-expanded="true"]'),
    },
    "default-verbose": {
      note: "The setting agentPane.display.transcriptView is Verbose: a chat without a view of its own opens in Verbose.",
      snapshot,
      display: { "agentPane.display.transcriptView": "verbose" },
    },
  },
});
