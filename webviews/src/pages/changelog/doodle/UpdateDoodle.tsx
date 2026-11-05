// The Updated card's doodle (ThemeDecorations `updated-card` = "doodle", Debug Settings "Doodle on the
// Updated card", off by default). Leo 2026-11-05, on the Yab browser's after-update note: "They have
// that little line thing, which is kind of cutesy quirky" ... "it is a personality thing that I think
// is kind of cute. You can try it out, like just build it." A hand-drawn note over the card in a marker
// ink: "you're on nightly 3845050!" with a check, a curved arrow from "have a look" to the card's
// What's New button with a loop around it, and "got it", which hides the card for this version as its
// x does. What's New marks the version seen too, so the doodle shows once per version, with the card.
//
// The strokes are our own SVG paths (pathLength 1, so each draws on with one dash offset), roughened
// by a turbulence filter into a marker's edge. They draw on once the page is visible and the face has
// loaded (doodleFont.ts), in about a second and a quarter; under Reduce Motion they are simply there, and
// with the web animations switched off (`data-cmux-motion="off"`) the bootstrap ends them at once.
// Every piece has its room from the first frame, so the card's height never changes as it draws.
import { useEffect, useState, useSyncExternalStore, type CSSProperties, type ReactNode } from "react";
import type { Strings } from "../../shared/i18n";
import { getColorScheme, subscribeColorScheme } from "../colorScheme";
import "./updateDoodle.css";

/** How long the doodle waits for its face before it draws in the fallback one. */
const FONT_WAIT_MS = 400;

/** `waiting`: laid out, not yet drawn; `drawing`: the draw-on runs (or, without motion, is done). */
type Phase = "waiting" | "drawing";

function motionIsReduced(): boolean {
  const motion = globalThis.document?.documentElement.getAttribute("data-cmux-motion");
  if (motion === "reduced" || motion === "off") return true;
  return globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
}

/** Draws once the page shows and the face loaded (or `FONT_WAIT_MS` passed); at once without motion.
 *  `animate` false (gallery stills) shows the drawn doodle from the start. */
function useDrawPhase(animate: boolean): Phase {
  const [phase, setPhase] = useState<Phase>(() => (!animate || motionIsReduced() ? "drawing" : "waiting"));
  useEffect(() => {
    if (phase === "drawing") {
      // Drawn from the start (a still, Reduce Motion): the face replaces the fallback when it loads.
      void import("./doodleFont").then(({ loadDoodleFont }) => loadDoodleFont());
      return undefined;
    }
    let cancelled = false;
    let fontReady = false;
    const start = () => {
      if (cancelled || !fontReady || globalThis.document?.visibilityState === "hidden") return;
      setPhase("drawing");
    };
    const ready = () => {
      fontReady = true;
      start();
    };
    const timer = setTimeout(ready, FONT_WAIT_MS);
    void import("./doodleFont").then(({ loadDoodleFont }) => loadDoodleFont()).then(ready, ready);
    document.addEventListener("visibilitychange", start);
    return () => {
      cancelled = true;
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", start);
    };
  }, [phase]);
  return phase;
}

/** The ink's roughened edge, which every stroke group references. A page shows one card, so one id;
 *  a second doodle in the same document defines the same filter again, which changes nothing. */
const MARKER = "wn-doodle-marker";

function MarkerFilter() {
  return (
    <svg className="wn-doodle-defs" aria-hidden="true" focusable="false" width="0" height="0">
      <filter id={MARKER} x="-10%" y="-10%" width="120%" height="120%">
        <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="2" seed="7" result="grain" />
        <feDisplacementMap in="SourceGraphic" in2="grain" scale="1.6" xChannelSelector="R" yChannelSelector="G" />
      </filter>
    </svg>
  );
}

/** One stroke that draws on (`--wn-doodle-at`: when it starts, in the sequence). */
function Stroke({ d, at, width }: { d: string; at: number; width?: number }) {
  return (
    <path
      className="wn-doodle-stroke"
      d={d}
      pathLength={1}
      vectorEffect="non-scaling-stroke"
      style={{ "--wn-doodle-at": `${at}ms`, ...(width ? { strokeWidth: width } : {}) } as CSSProperties}
    />
  );
}

/** Handwritten words that write in from the start of the line. */
function Words({ at, className, children }: { at: number; className?: string; children: ReactNode }) {
  return (
    <span
      className={className ? `wn-doodle-words ${className}` : "wn-doodle-words"}
      style={{ "--wn-doodle-at": `${at}ms` } as CSSProperties}
    >
      {children}
    </span>
  );
}

/** The doodle's frame around the card's content: its phase, its ink for the scheme, the filter. */
export function Doodle({ animate = true, children }: { animate?: boolean; children: ReactNode }) {
  const phase = useDrawPhase(animate);
  const scheme = useSyncExternalStore(subscribeColorScheme, getColorScheme, () => "light" as const);
  return (
    <div className="wn-doodle" data-phase={phase} data-scheme={scheme}>
      <MarkerFilter />
      {children}
    </div>
  );
}

/** "you're on nightly 3845050!" and a check, over the card's title. */
export function DoodleHeadline({ version, strings }: { version: string; strings: Strings }) {
  return (
    <div className="wn-doodle-headline">
      <Words at={0}>{strings.format("updates.doodle.youreOn", version)}</Words>
      <svg className="wn-doodle-check" viewBox="0 0 22 16" aria-hidden="true" focusable="false">
        <g filter={`url(#${MARKER})`}>
          <Stroke d="M2.5 8.6 C4.4 10.1 6 11.7 7.6 13.6 C10.4 8.9 14.6 4.6 20 2.2" at={480} />
        </g>
      </svg>
    </div>
  );
}

/** The card's What's New button circled, a curved arrow to it from "have a look", and "got it". */
export function DoodleActions({
  strings,
  whatsNew,
  onGotIt,
}: {
  strings: Strings;
  /** The card's own What's New button: the doodle circles it, never replaces it. */
  whatsNew: ReactNode;
  onGotIt?: () => void;
}) {
  return (
    <div className="wn-doodle-actions">
      <span className="wn-doodle-circled">
        {whatsNew}
        <svg
          className="wn-doodle-loop"
          viewBox="0 0 120 44"
          preserveAspectRatio="none"
          aria-hidden="true"
          focusable="false"
        >
          {/* One pass around, a little past where it started, as a pen loops a word. */}
          <g filter={`url(#${MARKER})`}>
            <Stroke
              d="M72 4.5 C40 1.5 6 7 4.5 22 C3 36 40 42.5 70 40.5 C99 38.5 117 31 115.5 19 C114 8 90 3 58 5.5 C49 6.2 42 7.6 37 9.4"
              at={980}
            />
          </g>
        </svg>
      </span>
      <svg className="wn-doodle-arrow" viewBox="0 0 40 30" aria-hidden="true" focusable="false">
        <g filter={`url(#${MARKER})`}>
          <Stroke d="M37 6 C27 2.5 15 5 8.5 18.5" at={720} />
          <Stroke d="M3.6 12.6 C5.6 15.4 7.1 17.6 8.3 19.6 C10.7 18.2 13.4 17.1 16.4 16.4" at={900} />
        </g>
      </svg>
      <span className="wn-doodle-aside">
        <Words at={560}>{strings.t("updates.doodle.haveALook")}</Words>
        {onGotIt && (
          <button type="button" className="wn-doodle-got-it" onClick={onGotIt}>
            <Words at={1300}>{strings.t("updates.doodle.gotIt")}</Words>
          </button>
        )}
      </span>
    </div>
  );
}
