// l10n-allow-file: gallery fixture text, not shipped UI.
// Glass candy (gallery ui.glass-candy, experiment glass-candy): the shared `.ui-glass` over the
// person's art in four looks. Built on the shipped glass, never beside it: the root's data-glass mode
// (plain, lens, spectrum), the lens's per-surface tokens (--glass-refraction, --glass-magnify,
// --glass-gloss), the theme tokens (--cmux-*) and the motion gate (data-cmux-motion, Reduce Motion).
//
// The art: with the URL's `background` (light, dark, busy) the frame already paints the window's
// picture and sends it to the lens (frame/background.ts), and the stage reads that; otherwise the
// stage paints one of the bundled paintings the same way, under a light wash of the theme surface.
// The art is read once (64 px wide, about the glass blur's scale) for its palette, from which the
// text-bearing glass gets a tint that keeps 4.5:1 over any part of it (theme/artTint.ts).
//
// Motion, and what it costs (the PR has the measured numbers):
// - refraction: one sheen across each glass on entry and on pointer enter (a Web Animation of the
//   sheen's transform and opacity, one --cmux-motion-large long); the loupe follows the pointer by a
//   `translate` transition. Stops: the sheen ends by itself; the loupe settles one transition after
//   the last pointer move. The lens wakes on the transition and stops after its 20 quiet frames.
// - depth: the panes rise in once (a CSS animation, iteration 1) and lean toward the pointer (one
//   `translate` transition per pointer move, near pane most). Stops as above.
// - plain and art-tint: no motion at all.
// No timer and no frame loop of its own: at rest 0 rAF and no running animation. Motion off or Reduce
// Motion: no sheen, no rise, no pointer listener; the loupe stays home (CSS and motionMode()).
import { type CSSProperties, type ReactNode, type RefObject, useEffect, useRef, useState } from "react";
import { parseComputedColor } from "../../backdrop";
import { isArm } from "../../experiments/experiment";
import { Glass } from "../../ui/glass/Glass";
import { glassCandy } from "../../ui/glass/glassCandy.experiment";
import { readBackdrop, type GlassMode } from "../../ui/glass/glassState";
import { motionMode } from "../../ui/motion/motionMode";
import { BACKGROUND_PICTURES } from "../frame/background";
import { artGlassTint, artPalette, PALETTE_SAMPLE, type ArtPalette, type ArtTint } from "../theme/artTint";
import { css, rgb, withAlpha, type ThemeRGB } from "../theme/tokens";
import wave from "./art/hokusai-great-wave.jpg?inline";
import sunrise from "./art/monet-impression-sunrise.jpg?inline";
import starry from "./art/van-gogh-starry-night.jpg?inline";

export type Candy = keyof typeof glassCandy.arms;
export type Art = "starry" | "wave" | "sunrise" | "light" | "dark" | "busy";
export type GlassCandyProps = {
  candy: Candy;
  art: Art;
  /** The root's glass mode; refraction takes the lens (or Spectrum when asked) on its own. */
  mode?: GlassMode;
};

const ART: Record<Art, string> = { starry, wave, sunrise, ...BACKGROUND_PICTURES };
/** The theme surface's wash over a bundled painting (the window tint, lightened: the app's own is
 * ThemeTokens.wallpaperTintOpacity, which the `background` URL key draws). */
const ART_WASH = 0.28;
/** How far the art-tint look moves the glass from the theme surface toward the art's leading color. */
export const ART_FOLLOW = 0.5;

type BackdropHost = { cmuxTheme?: { backdrop?: (partial: unknown) => void } };

function readColor(root: HTMLElement, name: string): ThemeRGB | null {
  const parsed = parseComputedColor(getComputedStyle(root).getPropertyValue(name));
  return parsed ? rgb(parsed.r / 255, parsed.g / 255, parsed.b / 255, parsed.a) : null;
}

function restoreAttribute(element: Element, name: string, value: string | null): void {
  if (value === null) element.removeAttribute(name);
  else element.setAttribute(name, value);
}

/** The art behind the stage and the wash over it: the frame's picture, or a painting painted here. */
function useArt(art: Art): { image: string; wash: ThemeRGB | null } | null {
  const [state, setState] = useState<{ image: string; wash: ThemeRGB | null } | null>(null);
  useEffect(() => {
    const root = document.documentElement;
    if (root.dataset.galleryBackground) {
      const backdrop = readBackdrop(window);
      const tint = parseComputedColor(backdrop.tint);
      setState(
        backdrop.image
          ? { image: backdrop.image, wash: tint ? rgb(tint.r / 255, tint.g / 255, tint.b / 255, tint.a) : null }
          : null,
      );
      return;
    }
    const image = ART[art];
    const saved = root.getAttribute("style");
    const wash = withAlpha(readColor(root, "--cmux-surface-solid") ?? rgb(0, 0, 0), ART_WASH);
    root.style.setProperty("--cmux-surface-background", "transparent");
    root.style.setProperty(
      "background",
      `linear-gradient(${css(wash)}, ${css(wash)}) fixed, url("${image}") 0 0 / 100vw 100vh no-repeat fixed`,
      "important",
    );
    const host = window as unknown as BackdropHost;
    const send = () =>
      host.cmuxTheme?.backdrop?.({
        image,
        key: `gallery-glass-candy-${art}`,
        rect: { x: 0, y: 0, width: root.clientWidth, height: root.clientHeight },
        blur: 0,
        tint: css(wash),
      });
    send();
    window.addEventListener("resize", send);
    setState({ image, wash });
    return () => {
      window.removeEventListener("resize", send);
      host.cmuxTheme?.backdrop?.({ image: null, key: null });
      restoreAttribute(root, "style", saved);
    };
  }, [art]);
  return state;
}

/** The art's palette, read once from a PALETTE_SAMPLE-wide copy. */
function usePalette(image: string | undefined): ArtPalette | null {
  const [palette, setPalette] = useState<ArtPalette | null>(null);
  useEffect(() => {
    if (!image) return;
    let live = true;
    const picture = new Image();
    picture.onload = () => {
      const width = PALETTE_SAMPLE;
      const height = Math.max(1, Math.round((width * picture.naturalHeight) / Math.max(1, picture.naturalWidth)));
      const canvas = document.createElement("canvas");
      canvas.width = width;
      canvas.height = height;
      const context = canvas.getContext("2d", { willReadFrequently: true });
      if (!context || !live) return;
      context.drawImage(picture, 0, 0, width, height);
      setPalette(artPalette(context.getImageData(0, 0, width, height).data));
    };
    picture.src = image;
    return () => {
      live = false;
    };
  }, [image]);
  return palette;
}

function useGlassMode(mode: GlassMode): void {
  useEffect(() => {
    const root = document.documentElement;
    const saved = root.getAttribute("data-glass");
    root.setAttribute("data-glass", mode);
    return () => restoreAttribute(root, "data-glass", saved);
  }, [mode]);
}

/** Lean and loupe: one pointer listener on the stage, writing three custom properties per move. */
function usePointer(stage: RefObject<HTMLDivElement | null>, active: boolean): void {
  useEffect(() => {
    const element = stage.current;
    if (!element || !active || motionMode(element.ownerDocument) !== "full") return;
    let box: DOMRect | null = null;
    const enter = () => {
      box = element.getBoundingClientRect();
    };
    const move = (event: PointerEvent) => {
      box ??= element.getBoundingClientRect();
      if (box.width <= 0 || box.height <= 0) return;
      const x = Math.max(-1, Math.min(1, ((event.clientX - box.left) / box.width) * 2 - 1));
      const y = Math.max(-1, Math.min(1, ((event.clientY - box.top) / box.height) * 2 - 1));
      element.style.setProperty("--candy-x", x.toFixed(3));
      element.style.setProperty("--candy-y", y.toFixed(3));
      // The loupe's center, from its home (glassCandy.gallery.css: 48 px in from the right, 64 down).
      element.style.setProperty("--candy-dx", `${Math.round(event.clientX - box.left - (box.width - 48 - LOUPE / 2))}px`);
      element.style.setProperty("--candy-dy", `${Math.round(event.clientY - box.top - (64 + LOUPE / 2))}px`);
    };
    const leave = () => {
      box = null;
      for (const name of ["--candy-x", "--candy-y", "--candy-dx", "--candy-dy"]) element.style.removeProperty(name);
    };
    element.addEventListener("pointerenter", enter, { passive: true });
    element.addEventListener("pointermove", move, { passive: true });
    element.addEventListener("pointerleave", leave, { passive: true });
    return () => {
      element.removeEventListener("pointerenter", enter);
      element.removeEventListener("pointermove", move);
      element.removeEventListener("pointerleave", leave);
      leave();
    };
  }, [stage, active]);
}

/** The loupe's diameter, CSS px. */
const LOUPE = 120;

function motionMs(root: HTMLElement): number {
  const value = Number.parseFloat(getComputedStyle(root).getPropertyValue("--cmux-motion-large"));
  return Number.isFinite(value) && value > 0 ? value : 240;
}

/** One light sweep across each `.candy-sheen` glass now, and again on pointer enter. */
function useSheen(stage: RefObject<HTMLDivElement | null>, active: boolean): void {
  useEffect(() => {
    const element = stage.current;
    if (!element || !active || motionMode(element.ownerDocument) !== "full") return;
    const duration = motionMs(element.ownerDocument.documentElement);
    const easing = getComputedStyle(element).getPropertyValue("--cmux-ease-out").trim() || "ease-out";
    const sweep = (glass: Element) => {
      if (glass.getAnimations({ subtree: true }).some((animation) => animation.playState === "running")) return;
      glass.animate(
        [
          { transform: "translateX(-100%)", opacity: 0 },
          { opacity: 1, offset: 0.35 },
          { transform: "translateX(100%)", opacity: 0 },
        ],
        { duration, easing, pseudoElement: "::after" },
      );
    };
    const glasses = [...element.querySelectorAll(".candy-sheen")];
    for (const glass of glasses) sweep(glass);
    const enter = (event: Event) => sweep(event.currentTarget as Element);
    for (const glass of glasses) glass.addEventListener("pointerenter", enter, { passive: true });
    return () => {
      for (const glass of glasses) glass.removeEventListener("pointerenter", enter);
    };
  }, [stage, active]);
}

/** `data-settled` on the stage once its entry motion (sheen, rise) has finished, so the gallery's
 * ready check (the DOM still for 250 ms) never captures a frame mid-entry. */
function useSettled(stage: RefObject<HTMLDivElement | null>, ready: boolean): void {
  useEffect(() => {
    const element = stage.current;
    if (!element || !ready) return;
    let live = true;
    const running = element.getAnimations({ subtree: true }).map((animation) => animation.finished);
    void Promise.allSettled(running).then(() => {
      if (live) element.dataset.settled = "";
    });
    return () => {
      live = false;
    };
  }, [stage, ready]);
}

const tintStyle = (tint: ArtTint | null): CSSProperties | undefined =>
  tint ? ({ "--glass-tint": css(tint.tint) } as CSSProperties) : undefined;

function Card({ tint, className, children }: { tint: ArtTint | null; className?: string; children: ReactNode }) {
  return (
    <Glass className={`candy-card ${className ?? ""}`} style={tintStyle(tint)}>
      {children}
    </Glass>
  );
}

function Composer({ tint, sheen }: { tint: ArtTint | null; sheen: boolean }) {
  return (
    <Glass className={`candy-composer ui-glass-floats${sheen ? " candy-sheen candy-refract" : ""}`} style={tintStyle(tint)}>
      <span className="candy-secondary">Ask anything, @ to mention a file</span>
      <div className="candy-composer-foot candy-secondary">
        <span>Plan</span>
        <span>Claude</span>
        <span className="candy-push">⌘↩</span>
      </div>
    </Glass>
  );
}

/** The worst contrast of the text on the glass over the art, and (art-tint) the art's leading colors. */
function Readout({ tint, palette, swatches }: { tint: ArtTint | null; palette: ArtPalette; swatches: boolean }) {
  if (!tint) return null;
  return (
    <Glass className="candy-readout" style={tintStyle(tint)} data-candy-worst={tint.worst.toFixed(2)}>
      {swatches &&
        palette.dominant.map((color) => <span key={css(color)} className="candy-swatch" style={{ background: css(color) }} />)}
      <span>Text {tint.worst.toFixed(1)}:1 over the art</span>
    </Glass>
  );
}

export function GlassCandyStage({ candy: variantCandy, art, mode }: GlassCandyProps) {
  const armed = globalThis.cmuxExperiments?.[glassCandy.id];
  const candy: Candy = isArm(glassCandy, armed) ? armed : variantCandy;
  const glassMode: GlassMode = candy === "refraction" ? (mode === "spectrum" ? "spectrum" : "lens") : (mode ?? "plain");
  useGlassMode(glassMode);
  const backdrop = useArt(art);
  const palette = usePalette(backdrop?.image);
  const stage = useRef<HTMLDivElement>(null);
  const [tint, setTint] = useState<ArtTint | null>(null);
  useEffect(() => {
    if (!palette) return;
    if (candy === "plain") {
      setTint(null);
      return;
    }
    const root = document.documentElement;
    const surface = readColor(root, "--cmux-surface-solid") ?? rgb(0, 0, 0);
    const inks = ["--cmux-text", "--cmux-text-secondary"].flatMap((name) => readColor(root, name) ?? []);
    const follow = candy === "art-tint" ? ART_FOLLOW : 0;
    setTint(artGlassTint({ surface, inks, palette, wash: backdrop?.wash ?? undefined, follow }));
  }, [palette, candy, backdrop]);
  const ready = palette !== null && (candy === "plain" || tint !== null);
  usePointer(stage, ready && (candy === "refraction" || candy === "depth"));
  useSheen(stage, ready && candy === "refraction");
  useSettled(stage, ready);

  // Drawn whole in its first frame: nothing until the art is read, so no tint snaps in later.
  if (!ready) return <div className="candy-stage" />;
  const sheen = candy === "refraction";
  return (
    <div ref={stage} className="candy-stage" data-candy={candy}>
      {candy === "depth" ? (
        <div className="candy-depth">
          <Card tint={tint} className="candy-layer candy-layer-far">
            <div className="candy-title">Sessions</div>
            <div className="candy-secondary">Three chats working, one waiting on you.</div>
          </Card>
          <Card tint={tint} className="candy-layer candy-layer-mid">
            <div className="candy-title">Review ready</div>
            <div className="candy-secondary">The fix holds 60 frames per second while it scrolls.</div>
          </Card>
          <Card tint={tint} className="candy-layer candy-layer-near">
            <div className="candy-title">Merged</div>
            <div className="candy-secondary">#35800 landed on feat-cmux-next.</div>
          </Card>
        </div>
      ) : (
        <Card tint={tint} className={sheen ? "candy-sheen candy-refract" : undefined}>
          <div className="candy-title">Nightly is ready</div>
          <div className="candy-secondary">The glass bends the art at its rim; the text keeps its contrast.</div>
        </Card>
      )}
      <div className="candy-chips">
        {["Plan", "Opus", "Worktree"].map((label) => (
          <Glass key={label} className={`candy-chip${sheen ? " candy-sheen candy-refract" : ""}`} style={tintStyle(tint)}>
            {label}
          </Glass>
        ))}
      </div>
      {sheen && <Glass className="candy-loupe" aria-hidden="true" />}
      <Readout tint={tint} palette={palette} swatches={candy === "art-tint"} />
      <Composer tint={tint} sheen={sheen} />
    </div>
  );
}
