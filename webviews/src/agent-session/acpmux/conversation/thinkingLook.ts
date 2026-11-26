// The thinking look: four agent-settable settings a look sets to draw the running line the way Claude's
// desktop app does (Leo, 2026-11-19: "btw previously there was this thinking thing (this is claude code
// desktop) that i added in cmux nightly... and lawrence said to remove it from default... but i liked
// it! well we can add back it into our claude code desktop customization. we will also want to be
// adding it for that one's jump to bottom's animation too when it's thinking and stuff").
//
// Every default draws what cmux draws today: the one-second sweep every four seconds (#42247), the
// band half the line wide, and the static Jump to latest arrow. A look turns on
//   - `agentPane.display.thinking.shimmer: "continuous"`: the band crosses the words pass after pass,
//     eased in and out, one pass every `shimmerPeriod` ms (600 to 4000);
//   - `agentPane.display.thinking.shimmerBand`: the band's lit width in px (0 keeps half the line);
//   - `agentPane.display.thinking.jumpButton: "dots"`: while the agent works, Jump to latest and the live
//     line draw three dots in the theme accent that change shape in three stages (a big middle, big spread
//     ends, even dots; JumpDots.css), the button's arrow back on hover and once the agent stops.
// The host's `display` push carries them (chatDisplay.ts `setChatDisplay`), so a look install or a
// `cmux settings set` swaps them live: they land on the document root as attributes and variables, and
// the shimmer cadence (shimmerCadence.ts) and the Jump to latest button read them there. The settings
// rows and their range checks are schemas/settings/source/agent-pane-display.json (Rust cmux-config
// refuses an out-of-range value); an unknown value here falls back to the default.
//
// A look's own thinking dots (Leo, 2026-11-19: "the dots and the way it moves changes a lot"; "i
// guess the particle systems could be an api as well... like the customizations thing?"):
//   - `agentPane.display.thinking.glyph`: a `cmux.particles/1` document (cmux-app-host js/ABI.md
//     "Particles choreography"; Rust cmux-config checks it with the one validator, particles.rs).
//     Set, the live status line plays it before its words (ThinkingGlyph.tsx), its trigger the agent's
//     current activity kind (thinkingGlyphModel.ts `glyphTrigger`);
//   - `agentPane.display.thinking.jumpButton: "glyph"`: Jump to latest plays the same document while
//     the agent works, at `agentPane.display.thinking.glyphSize` points a dot when above 0.
// Unset, nothing is mounted and the page draws what it drew before.
import { useSyncExternalStore } from "react";
import { parseChoreography, type Choreography } from "../../../apps/scene/choreography";

export const THINKING_SHIMMER_KEY = "agentPane.display.thinking.shimmer";
export const THINKING_SHIMMER_PERIOD_KEY = "agentPane.display.thinking.shimmerPeriod";
export const THINKING_SHIMMER_BAND_KEY = "agentPane.display.thinking.shimmerBand";
export const THINKING_JUMP_BUTTON_KEY = "agentPane.display.thinking.jumpButton";
export const THINKING_GLYPH_KEY = "agentPane.display.thinking.glyph";
export const THINKING_GLYPH_SIZE_KEY = "agentPane.display.thinking.glyphSize";

export type ThinkingShimmer = "cadenced" | "continuous";
export type ThinkingJumpButton = "arrow" | "dots" | "glyph";

export type ThinkingLook = {
  shimmer: ThinkingShimmer;
  /** One continuous pass, ms. */
  periodMs: number;
  /** The band's lit width in px; 0 keeps the default band (half the line). */
  bandPx: number;
  jumpButton: ThinkingJumpButton;
  /** The look's thinking dots, parsed; null draws none. */
  glyph: Choreography | null;
  /** The document as the host sent it (compact JSON), so the same document keeps the running glyph. */
  glyphKey: string;
  /** Jump to latest's dot size in points over the document's; 0 keeps the document's. */
  glyphSize: number;
};

export const DEFAULT_THINKING_LOOK: ThinkingLook = {
  shimmer: "cadenced",
  periodMs: 1250,
  bandPx: 0,
  jumpButton: "arrow",
  glyph: null,
  glyphKey: "",
  glyphSize: 0,
};

const PERIOD_MIN = 600;
const PERIOD_MAX = 4000;
const BAND_MAX = 240;
const GLYPH_SIZE_MAX = 16;

const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

/** The look from the host's display map; a value out of the setting's range keeps its default. */
export function resolveThinkingLook(values: Record<string, unknown> | undefined): ThinkingLook {
  if (!values) return DEFAULT_THINKING_LOOK;
  const shimmer = values[THINKING_SHIMMER_KEY] === "continuous" ? "continuous" : "cadenced";
  const period = values[THINKING_SHIMMER_PERIOD_KEY];
  const band = values[THINKING_SHIMMER_BAND_KEY];
  const document = values[THINKING_GLYPH_KEY];
  const glyph = document === undefined || document === null ? null : parseChoreography(document);
  const glyphSize = values[THINKING_GLYPH_SIZE_KEY];
  const jump = values[THINKING_JUMP_BUTTON_KEY];
  return {
    shimmer,
    periodMs: finite(period) && period >= PERIOD_MIN && period <= PERIOD_MAX ? period : DEFAULT_THINKING_LOOK.periodMs,
    bandPx: finite(band) && band >= 0 && band <= BAND_MAX ? band : 0,
    // "glyph" with no document to play keeps the arrow.
    jumpButton: jump === "dots" ? "dots" : jump === "glyph" && glyph ? "glyph" : "arrow",
    glyph,
    glyphKey: glyph ? JSON.stringify(document) : "",
    glyphSize: finite(glyphSize) && glyphSize > 0 && glyphSize <= GLYPH_SIZE_MAX ? glyphSize : 0,
  };
}

const same = (a: ThinkingLook, b: ThinkingLook) =>
  a.shimmer === b.shimmer &&
  a.periodMs === b.periodMs &&
  a.bandPx === b.bandPx &&
  a.jumpButton === b.jumpButton &&
  a.glyphKey === b.glyphKey &&
  a.glyphSize === b.glyphSize;

let current = DEFAULT_THINKING_LOOK;
const listeners = new Set<() => void>();

/** Writes the look on `root`: nothing at all for a default, so today's page is unchanged. */
export function applyThinkingLook(root: HTMLElement, look: ThinkingLook): void {
  if (look.shimmer === "continuous") root.dataset.thinkingShimmer = "continuous";
  else delete root.dataset.thinkingShimmer;
  if (look.shimmer === "continuous") root.style.setProperty("--cv-shimmer-period", `${look.periodMs}ms`);
  else root.style.removeProperty("--cv-shimmer-period");
  if (look.bandPx > 0) {
    root.dataset.thinkingBand = "";
    root.style.setProperty("--cv-shimmer-band", `${look.bandPx}px`);
  } else {
    delete root.dataset.thinkingBand;
    root.style.removeProperty("--cv-shimmer-band");
  }
  if (look.jumpButton !== "arrow") root.dataset.jumpButton = look.jumpButton;
  else delete root.dataset.jumpButton;
}

/** The host's display push (chatDisplay.ts `setChatDisplay`): the page follows at once. */
export function configureThinkingLook(values: Record<string, unknown> | undefined, root?: HTMLElement): void {
  const next = resolveThinkingLook(values);
  const target = root ?? (typeof document === "undefined" ? undefined : document.documentElement);
  if (target) applyThinkingLook(target, next);
  if (same(next, current)) return;
  current = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};
const snapshot = () => current;

export const thinkingLook = (): ThinkingLook => current;
export const useThinkingLook = (): ThinkingLook => useSyncExternalStore(subscribe, snapshot, snapshot);
