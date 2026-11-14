// l10n-allow-file: gallery labels, not shipped UI.
// The composer's send slot turning between Send and Stop (composer/SendSlotGlyph.tsx; Leo,
// 2026-11-07: "At the very least, like the Enter to the Stop button, I like. I think it would be
// cool. You know, a fast animation that's just like, oh well, how delightful, you know."). Each
// variant is one arm of experiment `send-stop-morph`, held at rest and at fixed points of its
// 180 ms run, in Claude's look (↵ and Stop as plain glyphs) and Codex's (↑ and Stop on the disc).
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { SendStopMorphArm } from "./sendStopMorph.experiment";
import type { SlotGlyph } from "./sendSlotGlyphModel";

type Props = { arm: SendStopMorphArm };

const POINTS = [0, 0.25, 0.5, 0.75, 1] as const;

/// Every held frame keeps the button's 28 × 28 box.
const boxesFixed: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-send").length >= 20);
  for (const button of ctx.document.querySelectorAll<HTMLElement>(".acpmux-send")) {
    const box = button.getBoundingClientRect();
    if (box.width !== 28 || box.height !== 28)
      throw new Error(`a held send slot is ${box.width}×${box.height}, not 28×28`);
  }
};

export default componentEntry<Props>({
  id: "agent-pane.composer-send-stop-morph",
  title: "Composer Send and Stop morph",
  area: "Composer",
  pane: true,
  height: 400,
  widths: { normal: 560, narrow: 400 },
  keywords: ["send", "stop", "morph", "transition", "animation"],
  covers: ["agent-session/acpmux/composer/SendSlotGlyph.tsx#SendSlotGlyph"],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../composerStates.css"),
      import("../composerLocation.css"),
      import("../composerLook.css"),
    ]).then(() => undefined),
  load: () =>
    import("./SendSlotGlyph").then(
      ({ MorphFrame }) =>
        function Gallery({ arm }: Props) {
          const row = (look: "claude" | "codex", from: SlotGlyph, to: SlotGlyph, label: string) => (
            <div style={{ display: "contents" }}>
              <div style={{ color: "var(--agent-muted)", fontSize: "var(--text-detail)", alignSelf: "center" }}>
                {label}
              </div>
              {POINTS.map((point) => (
                <div
                  key={point}
                  className="acpmux-composer"
                  data-composer-look={look === "codex" ? "codex" : undefined}
                  style={{ display: "grid", placeItems: "center" }}
                >
                  <span className="acpmux-composer-bar" style={{ display: "grid", placeItems: "center" }}>
                    <button
                      type="button"
                      tabIndex={-1}
                      className={`acpmux-send${(point < 0.5 ? from : to) === "stop" ? " acpmux-cancel" : look === "codex" ? "" : " acpmux-send-ready"}`}
                      aria-label={`${label} ${point * 100}%`}
                    >
                      <MorphFrame arm={arm} from={from} to={to} progress={point} />
                    </button>
                  </span>
                </div>
              ))}
            </div>
          );
          return (
            <div className="acpmux-shell" style={{ display: "block", height: "auto", padding: "var(--ds-space-5)" }}>
              <div
                style={{
                  display: "grid",
                  gridTemplateColumns: "auto repeat(5, 48px)",
                  gap: "var(--ds-space-4)",
                  alignItems: "center",
                }}
              >
                <div />
                {POINTS.map((point) => (
                  <div
                    key={point}
                    style={{ color: "var(--agent-muted)", fontSize: "var(--text-caption)", textAlign: "center" }}
                  >
                    {point === 0 ? "rest" : point === 1 ? "end" : `${Math.round(point * 180)} ms`}
                  </div>
                ))}
                {row("claude", "return", "stop", "Claude ↵ → Stop")}
                {row("claude", "stop", "return", "Claude Stop → ↵")}
                {row("codex", "arrow", "stop", "Codex ↑ → Stop")}
                {row("codex", "stop", "arrow", "Codex Stop → ↑")}
              </div>
            </div>
          );
        },
    ),
  variants: {
    scale: {
      note: "Shipped. The old glyph shrinks to 70% as it fades and the new one grows from 70% as it fades in, on one 180 ms ease-out. Both glyphs stay readable through the run, the shape change reads as the button changing its job, and it costs one compositor-only transform and opacity per layer.",
      props: { arm: "scale" },
      play: boxesFixed,
    },
    rotate: {
      note: "The same crossfade and scale with a quarter turn out and in. Livelier, but the square and ↵ spin through diagonal frames that look like neither glyph, and the turn reads as a refresh more than a stop.",
      props: { arm: "rotate" },
      play: boxesFixed,
    },
    path: {
      note: "One stroke bends from the old outline into the new one. The truest morph, but its midpoints are tangled lines, ↵'s bar has no clean match on the square, and it rewrites the path on the main thread every frame.",
      props: { arm: "path" },
      play: boxesFixed,
    },
    blur: {
      note: "The old glyph blurs out as the new one comes into focus. Soft, but at 18 px the middle frames are a grey smudge, and a blur filter per frame is the costliest of the four.",
      props: { arm: "blur" },
      play: boxesFixed,
    },
  },
});
