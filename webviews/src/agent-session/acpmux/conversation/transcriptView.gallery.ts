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
      // Long enough to fold in Normal (ThoughtRow folds a thought taller than the fold threshold),
      // so Thinking visibly opens it.
      thought(
        [
          "The test waits on real timers. On a loaded runner the second retry lands after the assertion, so check how the helper schedules its delay before touching the test.",
          "The helper computes the delay from the attempt number, doubles it each time, and adds jitter from Math.random, so two runs never wait the same amount.",
          "The test asserts two calls after advancing nothing: it relies on the first delay being shorter than the test's own await, which only holds on an idle machine.",
          "On CI the runner is shared, so a 200 ms sleep can stretch past the assertion. The failure output shows exactly one call, which matches the second attempt not having started yet.",
          "Options: inject the clock into the helper, or switch the test to fake timers and advance them explicitly. Fake timers keep the helper unchanged and make the test deterministic.",
          "Before changing anything, confirm the helper has no other caller that depends on real timing, and that the jitter can be seeded or stubbed in the test.",
        ].join("\n\n"),
        { startedAt: 0, endedAt: 9_000 },
      ),
      tool("Read src/net/retry.ts", "read", "completed", { locations: [{ path: "src/net/retry.ts" }] }),
      tool("bun test src/net/retry.test.ts", "execute", "failed", {
        command: "bun test src/net/retry.test.ts",
        exitCode: 1,
        output:
          "retry.test.ts:\n✗ backs off between attempts [212ms]\n  Expected: 2 calls\n  Received: 1 call\n\n0 pass\n1 fail",
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

/// The open chat menu shows Archive without a scroll: a row added to the full-height menu pushes it
/// out of view (the review of #28782 at 7f8dfad8).
function archiveInView(ctx: PlayContext): void {
  const popup = ctx.document.querySelector<HTMLElement>(".acpmux-chat-menu-popover");
  const archive = [...(popup?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])].find((row) =>
    row.textContent?.trim().startsWith("Archive"),
  );
  if (!popup || !archive) throw new Error("the chat menu has no Archive row");
  const shown = popup.getBoundingClientRect();
  const row = archive.getBoundingClientRect();
  const height = ctx.document.defaultView?.innerHeight ?? 0;
  const items = [...popup.children].map((n) => `${(n.textContent ?? "").trim().slice(0, 18)}:${Math.round(n.getBoundingClientRect().height)}`).join(",");
  const cs = ctx.document.defaultView!.getComputedStyle(popup);
  const DIAG = ` DIAG top ${Math.round(shown.top)} h ${Math.round(shown.height)} sh ${popup.scrollHeight} maxh ${cs.maxHeight} pad ${cs.paddingTop}/${cs.paddingBottom} items ${items}`;
  if (popup.scrollTop !== 0 || row.bottom > shown.bottom + 0.5 || row.bottom > height)
    throw new Error(
      `Archive is out of view: row ${Math.round(row.top)}-${Math.round(row.bottom)}, menu to ${Math.round(shown.bottom)}, window ${height}${DIAG}`,
    );
}

/// Picks `name` in the submenu; the menu closes and `drawn` shows.
const pick =
  (name: string, drawn: string): Play =>
  async (ctx) => {
    await openSubmenu(ctx);
    await ctx.click({ role: "menuitemradio", name });
    await ctx
      .waitFor(() => !ctx.document.querySelector('[role="menu"]'))
      .catch(() => {
        throw new Error(`the menu stayed open after ${name}`);
      });
    await ctx
      .waitFor(() => ctx.document.querySelector(drawn))
      .catch(() => {
        const shown = [...ctx.document.querySelectorAll(".cv-thought, .cv-command")]
          .map((node) => `${node.className}:${node.getAttribute("aria-expanded")}`)
          .join(" | ");
        const stage = ctx.document.querySelector(".acpmux-stage") ?? ctx.document.body;
        const cls = [...stage.querySelectorAll("[class]")].map((n) => `${n.className}${n.getAttribute("aria-expanded") ? `(${n.getAttribute("aria-expanded")})` : ""}`).filter((c) => /cv-|acpmux-row/.test(c)).slice(0, 60).join(" | ");
        throw new Error(`${name} did not draw ${drawn}; rows: ${shown}; DIAG ${cls}`);
      });
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
    "chat-menu": {
      note: "The chat's ··· menu open: the Transcript view row takes Text & Width's place, so the menu grows by no row and Archive stays on screen.",
      snapshot,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Chat actions" });
        await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
        archiveInView(ctx);
      },
    },
    "menu-open": {
      note: "Chosen: the chat menu's Transcript view submenu, as Claude Code desktop's: Normal, Thinking, Verbose with a check on this chat's view, then Make Normal the default (off while the chat shows the default), then Text & Width….",
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
      play: pick("Thinking", '.cv-thought.is-toggle[aria-expanded="true"]'),
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
