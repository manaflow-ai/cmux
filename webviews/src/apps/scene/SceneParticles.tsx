import { useEffect, useRef } from "react";
import { sceneMotionEnv } from "./motionProps";
import { drawParticles, ParticleField, particlePreset } from "./particleField";
import { sceneColor, sceneNumber } from "./sceneStyle";
import type { SceneNode } from "./store";

/** The longest step one frame advances the field (a frame after a stall does not jump). */
const MAX_FRAME_SECONDS = 0.05;

/** Resolves theme tokens (`accent`, `var(--...)`) to colors a canvas can paint: every color is
 * written to a hidden probe first and all are read after, so the style resolves once. */
function canvasColors(canvas: HTMLCanvasElement, value: unknown): string[] | null {
  if (!Array.isArray(value)) return null;
  const doc = canvas.ownerDocument;
  const view = doc.defaultView;
  if (!view) return null;
  const colors = value
    .slice(0, 16)
    .map(sceneColor)
    .filter((color): color is string => !!color);
  if (colors.length === 0) return null;
  const holder = doc.createElement("span");
  holder.hidden = true;
  const probes = colors.map((color) => {
    const probe = doc.createElement("span");
    probe.style.color = color;
    return probe;
  });
  holder.append(...probes);
  canvas.parentElement?.append(holder);
  const resolved = probes.map((probe, index) => view.getComputedStyle(probe).color || colors[index]!);
  holder.remove();
  return resolved;
}

/**
 * `Particles`: one canvas filling the node's frame, one requestAnimationFrame loop that runs only
 * while the canvas is on screen, the page is visible and the app's motion is full (Reduce Motion and
 * `ui.animationSpeed: off` stop it and clear the canvas). Props reach the field through refs, so a
 * prop change never restarts the loop and a frame never renders React.
 */
export function SceneParticles({ node }: { node: SceneNode }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const field = useRef<ParticleField | null>(null);
  const kick = useRef<() => void>(() => {});
  const lastBurst = useRef<number | undefined>(undefined);
  const preset = particlePreset(node.props.preset);
  const rate = sceneNumber(node.props.rate);
  const burst = sceneNumber(node.props.burst);
  const colors = node.props.colors;

  // The field and its loop live as long as the preset does.
  useEffect(() => {
    const canvas = canvasRef.current;
    const doc = canvas?.ownerDocument;
    const view = doc?.defaultView;
    if (!canvas || !doc || !view || !preset) return;
    // No observer, no frames: a host that cannot say the canvas is on screen never runs the loop.
    if (typeof view.IntersectionObserver !== "function" || typeof view.requestAnimationFrame !== "function") return;
    const current = new ParticleField(preset, canvasColors(canvas, colors));
    current.setRate(rate);
    field.current = current;
    let context: CanvasRenderingContext2D | null = null;
    let onScreen = false;
    let frame = 0;
    let last = 0;
    let scale = 1;
    let warmed = false;
    // Read when the loop starts and when a switch changes, never per frame.
    let env = sceneMotionEnv(doc, canvas);

    const allowed = () => onScreen && doc.visibilityState !== "hidden" && env.mode === "full";
    const clear = () => context?.clearRect(0, 0, current.width, current.height);
    const stop = () => {
      if (frame) view.cancelAnimationFrame(frame);
      frame = 0;
    };
    const tick = (now: number) => {
      frame = 0;
      if (!allowed()) {
        clear();
        current.particles.length = 0;
        return;
      }
      const dt = last ? Math.min((now - last) / 1000, MAX_FRAME_SECONDS) / env.speed : 0;
      last = now;
      current.step(dt);
      if (context) drawParticles(context, current.shapes(), current.width, current.height);
      if (current.active) frame = view.requestAnimationFrame(tick);
      else clear();
    };
    const start = () => {
      if (frame || !allowed()) return;
      if (!context) context = canvas.getContext("2d");
      if (!context) return;
      if (!warmed) {
        warmed = true;
        current.prewarm(3);
      }
      context.setTransform(scale, 0, 0, scale, 0, 0);
      last = 0;
      frame = view.requestAnimationFrame(tick);
    };
    kick.current = start;

    const resize = () => {
      const rect = canvas.getBoundingClientRect();
      scale = Math.min(view.devicePixelRatio || 1, 3);
      canvas.width = Math.max(1, Math.round(rect.width * scale));
      canvas.height = Math.max(1, Math.round(rect.height * scale));
      current.resize(rect.width, rect.height);
      context?.setTransform(scale, 0, 0, scale, 0, 0);
    };
    resize();
    const resizer = typeof view.ResizeObserver === "function" ? new view.ResizeObserver(resize) : undefined;
    resizer?.observe(canvas);
    const visibility = new view.IntersectionObserver((entries) => {
      onScreen = entries.some((entry) => entry.isIntersecting);
      if (onScreen) start();
      else stop();
    });
    visibility.observe(canvas);
    // The app's motion switch and Reduce Motion can change while the field runs.
    const recheck = () => {
      env = sceneMotionEnv(doc, canvas);
      if (allowed()) start();
      else {
        stop();
        clear();
        current.particles.length = 0;
      }
    };
    const switches = new view.MutationObserver(recheck);
    switches.observe(doc.documentElement, {
      attributes: true,
      attributeFilter: ["data-cmux-motion", "data-agent-motion"],
    });
    const reduced = view.matchMedia?.("(prefers-reduced-motion: reduce)");
    reduced?.addEventListener?.("change", recheck);
    doc.addEventListener("visibilitychange", recheck);
    return () => {
      stop();
      resizer?.disconnect();
      visibility.disconnect();
      switches.disconnect();
      reduced?.removeEventListener?.("change", recheck);
      doc.removeEventListener("visibilitychange", recheck);
      kick.current = () => {};
      field.current = null;
    };
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- rate, colors and bursts reach the running field below; only a new preset makes a new field
  }, [preset]);

  useEffect(() => {
    field.current?.setRate(rate);
    kick.current();
  }, [rate]);

  const colorKey = JSON.stringify(colors ?? null);
  useEffect(() => {
    const canvas = canvasRef.current;
    if (canvas && field.current) field.current.setColors(canvasColors(canvas, colors));
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- `colorKey` is the colors' value; a new array with the same colors changes nothing
  }, [colorKey]);

  // `burst` is a counter: each increase fires one burst; the first value fires nothing.
  useEffect(() => {
    const previous = lastBurst.current;
    lastBurst.current = burst;
    if (burst === undefined || previous === undefined || burst <= previous) return;
    const canvas = canvasRef.current;
    if (!canvas || !field.current || sceneMotionEnv(canvas.ownerDocument, canvas).mode !== "full") return;
    field.current.burst();
    kick.current();
  }, [burst]);

  return <canvas ref={canvasRef} className="cmux-app-scene-particles-canvas" aria-hidden="true" />;
}
