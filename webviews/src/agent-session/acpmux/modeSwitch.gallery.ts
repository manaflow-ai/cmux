// l10n-allow-file: gallery fixtures (sample chats and permission modes), not shipped UI.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, CWD, summary, user } from "../../gallery/fixtures/acpmux";

const finished = [
  user("Add retries with backoff to the fetch helper", 10),
  assistant("Done: GETs retry, POSTs only with a policy.", 9),
  summary(9, { status: "completed" }),
];

export default agentPaneEntry({
  id: "agent-pane.mode-switch",
  title: "Mode switch",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 760 },
  anchors: [{ selector: ".acpmux-scroll" }, { selector: ".acpmux-composer-box" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Picking a permission mode closes only the menu and keeps the transcript and composer geometry stable.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "The optimistic mode label fits the existing access control without reflowing the composer.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Opening and picking a mode should stay within one display frame on the gallery host.",
    },
  },
  covers: ["agent-session/acpmux/ComposerPickers.tsx#ComposerPickers"],
  variants: {
    "full-access": {
      note: "Play: open the lock menu, choose Full access, and see the lock label update immediately with no confirmation dialog.",
      snapshot: chat(finished, {
        summary: {
          sessionId: "gallery-mode-switch",
          harness: "claude",
          model: "claude-opus-5-5",
          effort: "high",
          cwd: CWD,
          host: "This Mac",
          hostKind: "local",
          branch: "main",
          turnCount: 1,
          modes: {
            currentModeId: "ask",
            availableModes: [
              { id: "ask", name: "Ask for approval", description: "Always ask" },
              { id: "full-access", name: "Full access" },
            ],
          },
        },
      }),
      play: async (ctx) => {
        await ctx.click({ selector: '[aria-label="Mode"]' });
        await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] [role="menuitemradio"]'));
        await ctx.click({ selector: '[role="menuitemradio"]:last-child' });
        await ctx.waitFor(
          () => ctx.document.querySelector('[aria-label="Mode"]')?.textContent?.includes("Full access") ?? false,
        );
      },
    },
  },
});
