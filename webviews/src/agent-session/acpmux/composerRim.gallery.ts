// l10n-allow-file: gallery fixtures (a sample chat) and comparison notes, not shipped UI.
// The composer's rim at rest and with the prompt focused (Leo 2026-11-07: "the frame, the border on
// the composer, like it being this, like super duper prominent glass, I feel like is sort of
// strange"; earlier, 2026-10-21: "a subtle hairline border that brightens slightly on focus").
// The rim is two layers: the hairline ring (--acpmux-composer-edge at rest, --acpmux-composer-edge-
// focus with the prompt focused) and the glass material's top-lit light (glass.css "GLASS
// MATERIAL", scaled on the card by --acpmux-composer-glint, composerStates.css). Each level is a
// variant pair, at rest and focused; render them with `--themes pair --backgrounds none,busy` for
// dark and light over an opaque window and over art. The levels are gallery-only CSS over the
// shipped one, so "before" keeps today's look on any head.
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";

const snapshot = chat([
  user("Fix the merge verdict name mismatch.", 4),
  assistant(
    "Renamed the verdict field to `verdict_name` in the router and in the merge check, so the two read the same key. The check's test now covers a receipt written by the router.",
    3,
  ),
]);

type Level = { rest: number; focus: number; glint: number };
/// rest and focus: percent of the text color in the hairline; glint: the scale on the glass
/// material's top-lit rim, its return and its sheen in a dark theme (1 = the shared material as it
/// was; a light theme keeps the full light).
const LEVELS = {
  before: { rest: 18, focus: 28, glint: 1 },
  "quiet-16-22": { rest: 16, focus: 22, glint: 0.5 },
  "quiet-14-20": { rest: 14, focus: 20, glint: 0.5 },
  "quiet-18-22": { rest: 18, focus: 22, glint: 0.5 },
} as const satisfies Record<string, Level>;
type LevelId = keyof typeof LEVELS;

const mix = (percent: number) =>
  `color-mix(in srgb, var(--agent-text) ${percent}%, var(--agent-page-bg, var(--acpmux-base)))`;

const PROMPT = ".acpmux-composer > .acpmux-composer-box [contenteditable='true']";
const BOX = ".acpmux-composer > .acpmux-composer-box";

/// Each level's CSS beats the shipped rule it replaces on the same element: the glint one outranks
/// composerStates.css's `.acpmux-composer > .acpmux-composer-box.ui-glass-material` (0,3,0) by the
/// `html` type selector, so `before` really draws the full light (composer-rim-gallery.test.ts reads
/// the computed value back). The pane focuses the prompt when it mounts, so a resting stage blurs it
/// and waits until no field in the card is focused; a focused stage focuses it from the keyboard's
/// side (a text field always matches :focus-visible) and waits until the card matches
/// `:has(:focus-visible)`, the rule that lifts the rim. A stage that cannot reach its state times out
/// instead of capturing the wrong one.
async function stage(ctx: PlayContext, id: LevelId, focused: boolean) {
  const { rest, focus, glint } = LEVELS[id];
  ctx.document.getElementById("composer-rim-gallery")?.remove();
  const style = ctx.document.createElement("style");
  style.id = "composer-rim-gallery";
  style.textContent = `
    html .acpmux-shell { --acpmux-composer-edge: ${mix(rest)}; }
    html :is(.acpmux-composer, .nt-composer, .nt-box) { --acpmux-composer-edge-focus: ${mix(focus)}; }
    html .acpmux-composer > .acpmux-composer-box.ui-glass-material { --acpmux-composer-glint: ${glint}; }
  `;
  ctx.document.head.append(style);
  await ctx.waitFor(() => ctx.document.querySelector(PROMPT));
  const box = ctx.document.querySelector<HTMLElement>(BOX)!;
  if (focused) {
    await ctx.focus({ selector: PROMPT });
    await ctx.waitFor(() => box.matches(":has(:focus-visible)"));
  } else {
    // The mount's own focus can land after the first frame: blur until the card holds none.
    await ctx.waitFor(() => {
      if (box.matches(":focus-within")) (ctx.document.activeElement as HTMLElement | null)?.blur();
      return !box.matches(":focus-within");
    });
  }
  ctx.document.documentElement.dataset.composerRimState = focused ? "focused" : "rest";
}

const NOTES: Record<LevelId, string> = {
  before:
    "Before: an 18% hairline that steps to 28% on focus, under the full material light (a 48% white top line in dark, its blurred band and a 16% bottom return).",
  "quiet-16-22": "A 16% hairline, 22% focused; the material light at half in a dark theme.",
  "quiet-14-20": "A 14% hairline, 20% focused; the material light at half in a dark theme.",
  "quiet-18-22":
    "Selected: the resting 18% hairline as it was, a 22% focused step, and the material light at half in a dark theme, so focus is a subtle brighten rather than a bright glass frame.",
};

const variants = Object.fromEntries(
  (Object.keys(LEVELS) as LevelId[]).flatMap((id) => [
    [`${id}-rest`, { note: `${NOTES[id]} At rest.`, snapshot, play: (ctx: PlayContext) => stage(ctx, id, false) }],
    [
      `${id}-focused`,
      { note: `${NOTES[id]} The prompt focused.`, snapshot, play: (ctx: PlayContext) => stage(ctx, id, true) },
    ],
  ]),
);

export default agentPaneEntry({
  id: "agent-pane.composer-rim",
  title: "Composer rim at rest and focused",
  area: "Agent pane",
  height: 360,
  covers: ["agent-session/acpmux/ComposerBox.tsx#ComposerBox"],
  variants,
});
