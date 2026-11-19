// l10n-allow-file: gallery fixtures, not shipped UI.
// The glass engine (engine/glassEngine.ts) over the Liquid Glass wallpaper: three overlapping
// layers as the taste prototypes stack them (a sidebar card, a toolbar capsule over it, a round
// button over both), one variant per preset, and a moving variant that redraws every frame and
// prints its frame times (the bench, scripts/bench/benches/glass-engine-frames, reads the same
// readout at 4K).
import { useEffect, useRef, useState } from "react";
import wallpaper from "../../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { componentEntry } from "../../../gallery/format";
import { GlassEngine, type GlassLayer } from "./glassEngine";
import { GLASS_PRESETS, type GlassLook, type GlassPreset } from "./optics";

type Props = {
  preset: GlassPreset;
  /** Each layer's look over the preset. */
  look?: Partial<GlassLook>;
  /** Moves the layers every frame and prints frame times. */
  moving?: boolean;
  /** Layers drawn; the stack keeps its order. */
  layers?: 1 | 2 | 3;
};

/** The three layers at time `t` seconds, laid out in a `width` x `height` stage. */
export function stackAt(
  width: number,
  height: number,
  t: number,
  look: Partial<GlassLook>,
  count: number,
): GlassLayer[] {
  const sway = Math.sin(t * 1.3) * width * 0.06;
  const bob = Math.cos(t * 0.9) * height * 0.05;
  const stack: GlassLayer[] = [
    // A sidebar card.
    { x: width * 0.08, y: height * 0.12, width: width * 0.36, height: height * 0.72, look: { ...look, radius: 26 } },
    // A toolbar capsule across it.
    {
      x: width * 0.26 + sway,
      y: height * 0.2 + bob,
      width: width * 0.5,
      height: Math.max(44, height * 0.13),
      look: { ...look, radius: 999 },
    },
    // A round button over both.
    {
      x: width * 0.56 - sway,
      y: height * 0.5 - bob,
      width: Math.max(72, height * 0.24),
      height: Math.max(72, height * 0.24),
      look: { ...look, radius: 999 },
    },
  ];
  return stack.slice(0, count);
}

/** Frame-interval percentiles over the last `samples`, ms. */
export function frameSummary(samples: readonly number[]): { p50: number; p95: number; max: number; fps: number } {
  if (samples.length === 0) return { p50: 0, p95: 0, max: 0, fps: 0 };
  const sorted = [...samples].sort((a, b) => a - b);
  const at = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
  const mean = samples.reduce((sum, value) => sum + value, 0) / samples.length;
  return { p50: at(0.5), p95: at(0.95), max: sorted[sorted.length - 1]!, fps: mean > 0 ? 1000 / mean : 0 };
}

function GlassEngineGallery({ preset, look, moving = false, layers = 3 }: Props) {
  const stage = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const [readout, setReadout] = useState("");

  useEffect(() => {
    const host = stage.current;
    const surface = canvas.current;
    if (!host || !surface) return;
    const engine = GlassEngine.create(surface);
    if (!engine) {
      setReadout("WebGL2 unavailable: the engine draws nothing and pages keep their CSS glass.");
      return;
    }
    const merged = { ...GLASS_PRESETS[preset], ...look };
    let width = 0;
    let height = 0;
    let frame = 0;
    let ready = false;
    let stopped = false;
    const intervals: number[] = [];
    const cpu: number[] = [];
    let last = 0;
    const draw = (now: number) => {
      if (stopped) return;
      if (ready) {
        engine.render(stackAt(width, height, moving ? now / 1000 : 0, merged, layers));
        if (moving) {
          if (last > 0) intervals.push(now - last);
          cpu.push(engine.stats.cpuMs);
          if (intervals.length > 240) intervals.shift();
          if (cpu.length > 240) cpu.shift();
          last = now;
          if (intervals.length % 30 === 0) {
            const s = frameSummary(intervals);
            const c = frameSummary(cpu);
            const text = `${engine.canvas.width}x${engine.canvas.height} device px, ${layers} layers: frame p50 ${s.p50.toFixed(1)} ms, p95 ${s.p95.toFixed(1)} ms, ${s.fps.toFixed(0)} fps; render() cpu p95 ${c.p95.toFixed(2)} ms`;
            setReadout(text);
            (window as { cmuxGlassEngineFrames?: unknown }).cmuxGlassEngineFrames = {
              width: engine.canvas.width,
              height: engine.canvas.height,
              layers,
              intervals: [...intervals],
              cpu: [...cpu],
            };
          }
        }
      }
      if (moving) frame = requestAnimationFrame(draw);
    };
    const size = () => {
      const box = host.getBoundingClientRect();
      width = box.width;
      height = box.height;
      engine.resize(width, height, window.devicePixelRatio || 1);
      if (!moving) draw(0);
    };
    const image = new Image();
    image.onload = () => {
      engine.setBackdrop(image);
      ready = true;
      size();
      if (moving) frame = requestAnimationFrame(draw);
    };
    image.src = wallpaper;
    const observer = new ResizeObserver(size);
    observer.observe(host);
    return () => {
      stopped = true;
      cancelAnimationFrame(frame);
      observer.disconnect();
      engine.dispose();
    };
  }, [preset, look, moving, layers]);

  return (
    <div ref={stage} style={{ position: "relative", height: "100%", minHeight: 420, overflow: "hidden" }}>
      <canvas
        ref={canvas}
        aria-label="Three glass layers over the wallpaper"
        style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }}
      />
      {readout ? (
        <div
          data-glass-engine-readout
          style={{
            position: "absolute",
            left: 12,
            bottom: 12,
            padding: "4px 8px",
            borderRadius: 6,
            background: "rgba(0, 0, 0, 0.55)",
            color: "white",
            fontSize: "var(--text-caption)",
            fontVariantNumeric: "tabular-nums",
          }}
        >
          {readout}
        </div>
      ) : null}
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.glass-engine",
  title: "Glass engine",
  area: "Pages",
  height: 520,
  covers: ["ui/glass/engine/glassEngine.ts#GlassEngine", "ui/glass/engine/optics.ts#bendAt"],
  load: async () => GlassEngineGallery,
  variants: {
    regular: {
      note: "Regular: a clear slab, a convex squircle bevel that pulls the wallpaper inward at the rim (Snell's law, ior 1.5), 6 px frost, the rim lit from the upper left. The capsule and the button refract the card under them, not only the wallpaper.",
      props: { preset: "regular" },
    },
    clear: { note: "Clear: almost no frost, for glass over art.", props: { preset: "clear" } },
    thick: { note: "Thick: a 28 px bevel, 40 px slab, a strong bend and light.", props: { preset: "thick" } },
    prism: {
      note: "Prism: the thick slab with the bend split per channel at the rim (two more frost taps per rim pixel).",
      props: { preset: "prism" },
    },
    frosted: { note: "Frosted: a menu's density over the same bevel.", props: { preset: "frosted" } },
    "no-bevel": {
      note: "Before: the same layers with no bevel (frost, tint and light only), what CSS backdrop-filter glass draws.",
      props: { preset: "regular", look: { thickness: 0, specular: 0 } },
    },
    moving: {
      note: "The three layers move every frame; the readout prints frame intervals and render() CPU time.",
      props: { preset: "regular", moving: true },
    },
  },
});
