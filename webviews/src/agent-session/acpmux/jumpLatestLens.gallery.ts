// l10n-allow-file: sample transcript and comparison labels, not shipped UI.
// Jump to latest as a fisheye lens (ui/glass/Fisheye.tsx, glass.css FISHEYE). Leo, 2026-10-21:
// "I want, like glassier stuff. I want it to be like a fucking glass, like a lens thing, like a
// fisheye. I want more fisheye!" Then, 2026-11-03: "this is a little too transparent maybe don't we
// inherit off the macos glass levels?" (the level-* variants). Each variant parks the reader mid-chat, lifts the button into the
// prose so words sit under it, then sets one strength; medium is the one that ships.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import { fisheyeFilterId, type FisheyeStrength } from "../../ui/glass/Fisheye";

const snapshot = chat(
  Array.from({ length: 24 }, (_, index) => [
    user(`Check retry case ${index + 1}`, 50 - index * 2),
    assistant(
      `Case ${index + 1} passes. The client retries a temporary transport failure, keeps the original request id, and stops after the last attempt. The next check verifies that the same response reaches the caller exactly once, and that it inserts nothing between the retries. `.repeat(
        4,
      ),
      49 - index * 2,
    ),
    summary(49 - index * 2, { status: "completed" }),
  ]).flat(),
);

/** How far each variant lifts the button over the prose (the app keeps it 12 px over the composer). */
const LIFT_PX = 150;

/** A glass level for the disc (glass.css FISHEYE): its tint and what runs after the bend. Leo,
 * 2026-11-03: "this is a little too transparent maybe don't we inherit off the macos glass levels?" */
type Level = { tint: string; frost: string };
const LEVELS = {
  /** cmux#32577 as it shipped: a 14% tint and a quarter-pixel blur; the words read through. */
  clear: { tint: "color-mix(in srgb, var(--glass-surface) 14%, transparent)", frost: "saturate(1.15)" },
  /** The composer card's glass (composerStates.css): its surface at 70% under a 24px blur. */
  composer: {
    tint: "color-mix(in srgb, var(--acpmux-composer-solid) 70%, transparent)",
    frost: "blur(24px) saturate(1.25)",
  },
  /** The native tooltip material the host sends (WebTheme --cmux-tooltip-tint, TooltipSurface.swift):
   * the least alpha that keeps text 4.5:1 over black and white, under its 24px blur. */
  system: { tint: "var(--tooltip-tint)", frost: "var(--tooltip-blur)" },
  /** The liquid glass's lens level (--ds-glass-lens-tint 40%, --ds-glass-lens-blur 6px). */
  lens: {
    tint: "color-mix(in srgb, var(--glass-surface) var(--ds-glass-lens-tint), transparent)",
    frost: "var(--ds-glass-lens-blur)",
  },
  /** A stronger frost that keeps the bend: the surface at 50% over a 2.5px blur. Ships (desktop.css
   * --ds-glass-fisheye-*): the words under the disc frost to soft magnified shapes, the bend shows. */
  frost: {
    tint: "color-mix(in srgb, var(--glass-surface) var(--ds-glass-fisheye-tint), transparent)",
    frost: "var(--ds-glass-fisheye-frost)",
  },
} satisfies Record<string, Level>;

const park =
  (strength?: FisheyeStrength, level?: Level): Play =>
  async (ctx) => {
    await ctx.waitFor(() => (ctx.document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollHeight ?? 0) > 1_000);
    await ctx.scroll({ selector: ".acpmux-scroll" }, 1_200);
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-latest[data-shown]"));
    const button = ctx.document.querySelector<HTMLElement>(".acpmux-jump-latest");
    // Lifted off the composer's soft edge into the prose, so the lens has words to bend.
    button?.style.setProperty("bottom", `calc(12px + var(--acpmux-dock-space, 0px) + ${LIFT_PX}px)`);
    if (strength) button?.style.setProperty("--glass-fisheye", `url(#${fisheyeFilterId(strength)})`);
    if (level) {
      button?.style.setProperty("--glass-fisheye-tint", level.tint);
      button?.style.setProperty("--glass-fisheye-frost", level.frost);
    }
  };

export default agentPaneEntry({
  id: "agent-pane.jump-latest-lens",
  title: "Jump to latest fisheye lens",
  area: "Agent pane",
  height: 700,
  covers: ["ui/glass/Fisheye.tsx", "agent-session/acpmux/App.tsx#VirtualTranscript"],
  checks: {
    anchorMovePx: { value: 0, reason: "The lens bends only what the button draws; no row or composer moves." },
  },
  variants: {
    soft: {
      note: "Soft: 1.4x in the middle; the words under the disc grow a little and bend at the rim.",
      snapshot,
      play: park("soft"),
    },
    medium: {
      note: "Selected strength (ships): 1.8x in the middle, at the shipped glass level (level-frost).",
      snapshot,
      play: park(),
    },
    "level-clear": {
      note: "Before (cmux#32577): a 14% tint and almost no blur; the words under the disc read through.",
      snapshot,
      play: park(undefined, LEVELS.clear),
    },
    "level-composer": {
      note: "The composer card's glass: its surface at 70% under a 24px blur.",
      snapshot,
      play: park(undefined, LEVELS.composer),
    },
    "level-system": {
      note: "The native tooltip material the host sends (--cmux-tooltip-tint) under its 24px blur.",
      snapshot,
      play: park(undefined, LEVELS.system),
    },
    "level-lens": {
      note: "The liquid glass's lens level: the surface at 40% under a 6px blur.",
      snapshot,
      play: park(undefined, LEVELS.lens),
    },
    "level-frost": {
      note: "Selected (ships): a stronger frost that keeps the bend, the surface at 50% under a 2.5px blur.",
      snapshot,
      play: park(undefined, LEVELS.frost),
    },
    strong: {
      note: "Strong: 2.5x in the middle; a letter or two fills the disc and the arrow fights the text.",
      snapshot,
      play: park("strong"),
    },
  },
});
