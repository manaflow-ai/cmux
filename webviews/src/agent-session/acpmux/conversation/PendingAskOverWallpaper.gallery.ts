// l10n-allow-file: sample transcript, not shipped UI.
// The pinned "Needs your input" line over a wallpaper, in the whole pane: the line paints no band,
// so the transcript behind it stays in sight (conversation/dockClear.ts holes the mask there). Leo,
// 2026-11-17, of "Worked for" cut off under that line over his wallpaper: "why do you have the
// entire row blanked out? don't ever do that. this needs your input dismiss row erases things
// behind it".
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";

const ASK =
  "GitHub-hosted runners were ruled out on 10-27.\n\n[taste] Should I allow GitHub-hosted ubuntu-24.04 for Linux CI until the fleet pool is back?";

// The agent asked, then another agent's message opened a turn of its own: the ask waits, pinned
// over the composer, while the turns that came after scroll under it.
const turns = Array.from({ length: 6 }, (_, index) => [
  row("user", 30 - index * 4, {
    text: `Pushed fix ${index + 1}; the focused checks are running.`,
    untyped: true,
    incoming: {
      kind: "message",
      message: { name: "ci-lane", text: `Pushed fix ${index + 1}.`, raw: `Pushed fix ${index + 1}.` },
    },
  } as never),
  assistant(
    `Noted. Run ${index + 1} is green on the Linux pool; the macOS lane is still queued behind the nightly. `.repeat(2),
    29 - index * 4,
  ),
  summary(29 - index * 4, { status: "completed", durationMs: 34_000 }),
]).flat();

const snapshot = chat([
  user("Why is Linux CI waiting so long?", 40),
  assistant(ASK, 38),
  summary(38, { status: "completed", durationMs: 52_000 }),
  ...turns,
]);

// The picture comes through the variant's `background` (format.ts), so the window is see-through as in the app: the
// theme's tint over the picture and the pane's inks fit for it. The stage once painted a wallpaper of its own with
// neither, which no window draws: Rose Pine Dawn's header tools and "Worked for" read 1.1-2.9:1 on its bare pinks and
// blues (control-contrast-2). The busy picture behind a dark theme, the light one behind a light theme, as the audit
// pairs them: over the busy picture Rose Pine Dawn's own text read 3.06:1 under its tint.
const OVER_PICTURE = { dark: "busy", light: "light" } as const;

/// Scrolled up `scrolledUp` px from the latest message, once the pinned line is up.
const scrolled =
  (scrolledUp: number): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-pending-ask__head"));
    const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
    if (scroller && scrolledUp > 0)
      await ctx.scroll(
        { selector: ".acpmux-scroll" },
        Math.max(0, scroller.scrollHeight - scroller.clientHeight - scrolledUp),
      );
  };

/// The same pane after a click on Dismiss: the line and its card go, and the turns that were under
/// them stay in sight, none blanked where the line sat.
const dismissed: Play = async (ctx) => {
  await scrolled(120)(ctx);
  await ctx.click({ selector: ".acpmux-pending-ask__dismiss" });
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-pending-ask__head"));
};

export default agentPaneEntry({
  id: "agent-pane.pending-ask-wallpaper",
  title: "Needs your input over a wallpaper",
  area: "Agent pane",
  height: 640,
  covers: ["agent-session/acpmux/conversation/dockClear.ts", "agent-session/acpmux/conversation/PendingAsks.tsx"],
  keywords: ["needs your input", "dismiss", "wallpaper", "mask", "pinned ask"],
  variants: {
    "at-latest": {
      note: "At the latest message: the line and its Dismiss sit on the wallpaper with no band behind them.",
      snapshot,
      background: OVER_PICTURE,
      play: scrolled(0),
    },
    "scrolled-under": {
      note: 'Scrolled up a little: the turns pass behind the line and stay in sight ("Worked for" is not cut off); only the cards hide them.',
      snapshot,
      background: OVER_PICTURE,
      play: scrolled(120),
    },
    dismissed: {
      note: "After Dismiss: the line and its card are gone, and the turns behind where they sat stay in sight.",
      snapshot,
      background: OVER_PICTURE,
      play: dismissed,
    },
  },
});
