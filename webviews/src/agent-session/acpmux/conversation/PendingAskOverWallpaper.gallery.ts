// l10n-allow-file: sample transcript, not shipped UI.
// The pinned "Needs your input" line over a wallpaper, in the whole pane: the line paints no band,
// so the transcript behind it stays in sight (conversation/dockClear.ts holes the mask there). Leo,
// 2026-11-17, of "Worked for" cut off under that line over his wallpaper: "why do you have the
// entire row blanked out? don't ever do that. this needs your input dismiss row erases things
// behind it".
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import wallpaper from "../../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";
import {
  css,
  luminance,
  rgb,
  wallpaperTintOpacity,
  withAlpha,
  type ThemeRGB,
  type ThemeTokens,
} from "../../../gallery/theme/tokens";

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

/// A WebTheme `rgba(r, g, b, a)` variable as a color, or null.
const cssColor = (text: string): ThemeRGB | null => {
  const parts = text
    .match(/rgba?\(([^)]+)\)/)?.[1]
    ?.split(",")
    .map((part) => Number.parseFloat(part));
  if (!parts || parts.length < 3 || parts.some((part) => Number.isNaN(part))) return null;
  return rgb(parts[0]! / 255, parts[1]! / 255, parts[2]! / 255, parts[3] ?? 1);
};

/// The window's tint over the wallpaper, as WindowBackdrop lays it: the theme's window color at its wallpaper tint
/// opacity (ThemeTokens.wallpaperTintOpacity). The stage once painted the bare picture, which no window draws: Rose
/// Pine Dawn's header tools and Model read 1.1-2.9:1 on its raw pinks and blues (control-contrast-2).
const windowTint = (root: HTMLElement): string | null => {
  const style = getComputedStyle(root);
  const window = cssColor(style.getPropertyValue("--cmux-window-tint"));
  const text = cssColor(style.getPropertyValue("--cmux-text"));
  if (!window || !text) return null;
  const isDark = luminance(window) < luminance(text);
  const tokens = { isDark, windowBackground: withAlpha(window, 1), textPrimary: text } as ThemeTokens;
  return css(withAlpha(window, wallpaperTintOpacity(tokens)));
};

/// The wallpaper behind a see-through pane, as cmux's own wallpaper draws it: the picture, the window's tint over it.
const overWallpaper =
  (scrolledUp: number): Play =>
  async (ctx) => {
    const root = ctx.document.documentElement;
    const tint = windowTint(root);
    const picture = `url("${wallpaper}") 0 0 / 100vw 100vh no-repeat fixed`;
    root.style.setProperty(
      "background",
      tint ? `linear-gradient(${tint}, ${tint}) fixed, ${picture}` : picture,
      "important",
    );
    root.style.setProperty("--agent-page-bg", "transparent");
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-pending-ask__head"));
    const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
    if (scroller && scrolledUp > 0)
      await ctx.scroll(
        { selector: ".acpmux-scroll" },
        Math.max(0, scroller.scrollHeight - scroller.clientHeight - scrolledUp),
      );
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
      play: overWallpaper(0),
    },
    "scrolled-under": {
      note: 'Scrolled up a little: the turns pass behind the line and stay in sight ("Worked for" is not cut off); only the cards hide them.',
      snapshot,
      play: overWallpaper(120),
    },
  },
});
