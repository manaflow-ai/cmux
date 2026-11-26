// l10n-allow-file: gallery fixtures (a sample chat) and comparison notes, not shipped UI.
// The composer at rest, with the pointer over it, and with the prompt focused (Leo 2026-10-20: "on
// hover, the Claude desktop, like that gives you the focus ring ... it's the glass type focus ring.
// So it's not just one hard bar"). Hover draws --acpmux-composer-halo, a soft band of spread-only
// rings in the glass edge's color (composerStates.css); focus keeps the quiet hairline step
// (composerRim.gallery.ts) and eases into it. The hover stage needs the matrix runner's real pointer:
// synthetic events do not match CSS :hover.
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";

const snapshot = chat([
  user("Fix the merge verdict name mismatch.", 4),
  assistant(
    "Renamed the verdict field to `verdict_name` in the router and in the merge check, so the two read the same key.",
    3,
  ),
]);

const BOX = ".acpmux-composer > .acpmux-composer-box";
const PROMPT = `${BOX} [contenteditable='true']`;

type State = "rest" | "hover" | "focused";

/// The pane focuses the prompt when it mounts, so the rest and hover stages blur it and wait until
/// no field in the card holds focus; the focused stage focuses it from the keyboard's side and waits
/// for the card's `data-focused` (ComposerBox.tsx). A stage that cannot reach its state times out instead of capturing
/// the wrong one.
async function stage(ctx: PlayContext, state: State) {
  await ctx.waitFor(() => ctx.document.querySelector(PROMPT));
  const box = ctx.document.querySelector<HTMLElement>(BOX)!;
  if (state === "focused") {
    await ctx.focus({ selector: PROMPT });
    await ctx.waitFor(() => box.hasAttribute("data-focused"));
    return;
  }
  await ctx.waitFor(() => {
    if (box.matches(":focus-within")) (ctx.document.activeElement as HTMLElement | null)?.blur();
    return !box.matches(":focus-within");
  });
  if (state === "hover") {
    await ctx.hover({ selector: BOX });
    await ctx.waitFor(() => box.matches(":hover"));
  }
}

export default agentPaneEntry({
  id: "agent-pane.composer-hover",
  title: "Composer at rest, hovered and focused",
  area: "Agent pane",
  height: 360,
  covers: ["agent-session/acpmux/ComposerBox.tsx#ComposerBox"],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "The hover band is box-shadow only: it must not move the card or the transcript.",
    },
  },
  variants: {
    rest: {
      note: "At rest: the resting hairline; the hover band draws transparent.",
      snapshot,
      play: (ctx: PlayContext) => stage(ctx, "rest"),
    },
    hover: {
      note: "Selected: the pointer over the card adds a soft glass band, two spread-only rings in the glass edge's color, weaker going out; no border, no layout change.",
      snapshot,
      play: (ctx: PlayContext) => stage(ctx, "hover"),
    },
    focused: {
      note: "The prompt focused: the quiet hairline step, eased with the motion tokens; no glass band, so hover stays the softer cue.",
      snapshot,
      play: (ctx: PlayContext) => stage(ctx, "focused"),
    },
  },
});
