// l10n-allow-file: gallery sample transcript, not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";

const reveal =
  (look: "inline" | "trailing" | "separated"): Play =>
  async (ctx) => {
    const style = ctx.document.documentElement.style;
    style.setProperty("--cv-worked-label-track", look === "trailing" ? "1fr" : "max-content");
    style.setProperty(
      "--cv-worked-footer-gap",
      look === "separated" ? "var(--ds-space-4)" : "var(--cv-footer-time-gap)",
    );
    await ctx.hover({ selector: ".cv-worked" });
  };

const snapshot = () => {
  const state = chat([
    user("Check the tests", 4),
    activity(
      Array.from({ length: 6 }, () =>
        tool("Run tests", "execute", "completed", { command: "bun test", output: "Passed" }),
      ),
      3,
    ),
    summary(2, { status: "completed", durationMs: 46_000, toolCount: 6 }),
    user("What changed?", 1),
    assistant("The tests pass.", 0.5),
    summary(0.4, { status: "completed", durationMs: 20_000 }),
  ]);
  return { ...state, summary: { ...state.summary!, family: "claude" } };
};

export default agentPaneEntry({
  id: "agent-pane.hover-time-placement",
  title: "Hover time beside row content",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 360, normal: 760 },
  covers: ["agent-session/acpmux/conversation/TurnRows.tsx", "agent-session/acpmux/conversation/MessageActions.tsx"],
  variants: {
    inline: {
      snapshot: snapshot(),
      play: reveal("inline"),
      note: "Chosen: the time follows the row's content in its own space.",
    },
    trailing: {
      snapshot: snapshot(),
      play: reveal("trailing"),
      note: "The time at the trailing edge: clear, but distant from the work it dates.",
    },
    separated: {
      snapshot: snapshot(),
      play: reveal("separated"),
      note: "A larger gap after the content: safe, but takes more of a narrow row.",
    },
  },
});
