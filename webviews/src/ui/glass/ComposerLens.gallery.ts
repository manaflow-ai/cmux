// l10n-allow-file: gallery fixtures (sample prompts and agent answers), not shipped UI.
// The composer's refraction lens over a dense chat, beside today's plain frost (composerLens.ts; Leo,
// 2026-11-20: "Like looking at like your composer, I'm like scrolling up and down. Like, why not offer
// the option? I think it looks neat. I like the refraction. I think it's pretty darn close."). The
// lens is an option, never a replacement: it draws only under the host's Liquid Glass mode Lens
// (Debug Settings > Glass and Overlays > Liquid Glass, `data-glass="lens"`), and only in Chromium,
// which runs an SVG backdrop filter (WebKit shows the plain frost in every variant). Each stage is
// the whole pane with the chat scrolled up a little, so its text runs under the composer.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { Play } from "../../gallery/play";

const ANSWERS = [
  "I traced the stutter to the transcript's scroll handler: every wheel event read the composer's height, which forced a layout right after the virtualizer moved its rows. The fix reads it once per frame from the ResizeObserver entry instead.",
  "```ts\nexport function retry<T>(run: () => Promise<T>, attempts = 5): Promise<T> {\n  return run().catch((error) => (attempts > 1 ? wait(backoff(attempts)).then(() => retry(run, attempts - 1)) : Promise.reject(error)));\n}\n```\nThe helper now backs off before each attempt, capped at eight seconds.",
  "- The fetch tests cover a server that fails twice and then answers.\n- A timeout counts as one failed attempt.\n- The last error is the one the caller sees, with every attempt's status in its cause.",
  "The bench moved from 14.2 ms to 6.8 ms a frame at p95 with 2,000 messages, and the long-task count during a fast scroll dropped from 31 to 2.",
];

const rows = Array.from({ length: 16 }, (_, index) => {
  const turn = 16 - index;
  return [
    user(`Step ${index + 1}: keep going on the scroll fix`, turn * 3 + 2),
    assistant(ANSWERS[index % ANSWERS.length]!, turn * 3 + 1),
    summary(turn * 3 + 1, { status: "completed", durationMs: 18_000 }),
  ];
}).flat();

/// Scrolls the chat up from its latest message so its text runs under the composer, and, for the
/// stronger-floor variant, raises the lens's tint.
const underComposer =
  (tint?: string): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-row"));
    if (tint) ctx.document.documentElement.style.setProperty("--composer-lens-tint", tint);
    const scroller = ctx.find({ selector: ".acpmux-scroll" }) as HTMLElement;
    await ctx.scroll({ selector: ".acpmux-scroll" }, "bottom");
    await ctx.scroll({ selector: ".acpmux-scroll" }, Math.max(0, scroller.scrollTop - 90));
  };

export default agentPaneEntry({
  id: "ui.glass-composer-lens",
  title: "Composer refraction lens over the chat",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  covers: ["ui/glass/composerLens.ts#attachComposerLens", "agent-session/acpmux/ComposerBox.tsx"],
  variants: {
    plain: {
      note: "Plain (today, the default): the chat under the composer is frosted evenly to the edge.",
      snapshot: chat(rows),
      play: underComposer(),
    },
    lens: {
      note: "Lens: the composer's rim bends the chat under it (a convex bezel, refraction index 1.5, up to about 8 px in), lightly frosted under a clearer tint. The map is built once per box size; a scroll only re-samples it.",
      snapshot: chat(rows),
      documentAttributes: { glass: "lens" },
      play: underComposer(),
    },
    "lens-strong-tint": {
      note: "Lens with a stronger tint floor: the same bend under the composer's opaque-window tint raised to 82%, so the prompt reads over any chat.",
      snapshot: chat(rows),
      documentAttributes: { glass: "lens" },
      play: underComposer("color-mix(in srgb, var(--acpmux-composer-solid) 82%, transparent)"),
    },
  },
});
