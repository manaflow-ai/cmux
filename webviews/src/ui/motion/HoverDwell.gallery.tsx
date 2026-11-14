// l10n-allow-file: gallery labels are fixture content, not shipped UI.
// The hover reveal's dwell ramp, compared (Leo, 2026-11-07: "it should be, like, having its limit
// based off of how long you've had your cursor actually on it"). Each arm scripts three pointers at
// once on a message footer's "7 minutes ago" and Copy: a pass of 80 ms, a pass of 200 ms, and one
// that stays. Each lane draws the control's opacity over 900 ms, frame by frame, and its peak.
//
// Picked: standard, 400 ms on cubic-bezier(0.4, 0, 0.2, 1) in, 180 ms ease-in out. Its gentle start
// keeps an 80 ms pass faint (about 0.13) while a 200 ms look is already readable (about 0.8), and
// its ease-out finish lands on full with no visible end. linear lights a pass more (0.2) and drags
// at the end; ease-out 320 front-loads, so a pass reaches about 0.4, close to the flash Leo
// described; slow 600 never reads as a response under a 200 ms look (0.5); before (a 100 ms delay,
// then 120 ms) shows a pass nothing and a 200 ms look everything, the one-shot he called out.
import { useEffect, useRef, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";

type Curve = "standard" | "linear" | "ease-out" | "slow" | "before";
type DwellDemoProps = { curve: Curve };

const LANES = [
  { label: "80 ms pass", stay: 80 },
  { label: "200 ms pass", stay: 200 },
  { label: "stays", stay: Infinity },
];
const RUN_MS = 900;

function HoverDwellDemo({ curve }: DwellDemoProps) {
  const rows = useRef<(HTMLDivElement | null)[]>([]);
  const [traces, setTraces] = useState<{ t: number; v: number }[][]>();
  useEffect(() => {
    const samples: { t: number; v: number }[][] = LANES.map(() => []);
    let frame = 0;
    let start = 0;
    const timers: number[] = [];
    const tick = (now: number) => {
      if (!start) {
        start = now;
        rows.current.forEach((row, index) => {
          row?.setAttribute("data-dwell-hover", "");
          const stay = LANES[index]!.stay;
          if (Number.isFinite(stay))
            timers.push(window.setTimeout(() => row?.removeAttribute("data-dwell-hover"), stay));
        });
      }
      rows.current.forEach((row, index) => {
        const reveal = row?.querySelector(".ui-reveal");
        if (reveal) samples[index]!.push({ t: now - start, v: Number(getComputedStyle(reveal).opacity) });
      });
      if (now - start < RUN_MS) frame = requestAnimationFrame(tick);
      else setTraces(samples);
    };
    // Two frames first, so the resting style is committed and the first change transitions.
    frame = requestAnimationFrame(() => (frame = requestAnimationFrame(tick)));
    return () => {
      cancelAnimationFrame(frame);
      timers.forEach((timer) => window.clearTimeout(timer));
    };
  }, []);
  return (
    <div className="dwell-demo" data-curve={curve} data-dwell-done={traces ? "" : undefined}>
      {LANES.map((lane, index) => {
        const trace = traces?.[index];
        const peak = trace ? Math.max(...trace.map((sample) => sample.v)) : undefined;
        return (
          <div key={lane.label} className="dwell-demo__lane">
            <span className="dwell-demo__label">{lane.label}</span>
            <div
              ref={(element) => {
                rows.current[index] = element;
              }}
              className="dwell-demo__row ui-reveal-host"
            >
              <span className="ui-reveal">7 minutes ago</span>
              <span className="ui-reveal" aria-hidden>
                ⧉
              </span>
            </div>
            <svg className="dwell-demo__trace" viewBox={`0 0 ${RUN_MS} 30`} preserveAspectRatio="none" aria-hidden>
              <line x1="0" x2={RUN_MS} y1="2" y2="2" />
              <line x1="0" x2={RUN_MS} y1="28" y2="28" />
              {trace && <polyline points={trace.map((sample) => `${sample.t},${28 - sample.v * 26}`).join(" ")} />}
            </svg>
            <span className="dwell-demo__peak">{peak === undefined ? "…" : `peak ${peak.toFixed(2)}`}</span>
          </div>
        );
      })}
    </div>
  );
}

const ran: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector("[data-dwell-done]"), { capMs: 5000 });
};

export default componentEntry<DwellDemoProps>({
  id: "ui.motion-hover-dwell",
  title: "Hover reveal: the dwell ramp",
  area: "UI primitives",
  height: 160,
  covers: ["ui/motion/motion.css", "pages/shared/desktop.css"],
  load: async () => HoverDwellDemo,
  styles: () =>
    Promise.all([import("../../pages/shared/desktop.css"), import("./motion.css"), import("./motion.gallery.css")]),
  variants: {
    standard: {
      note: "Picked: 400 ms cubic-bezier(0.4, 0, 0.2, 1) in, 180 ms ease-in out. A pass stays faint; a look reads.",
      props: { curve: "standard" },
      play: ran,
    },
    linear: { note: "400 ms linear in and out.", props: { curve: "linear" }, play: ran },
    "ease-out": {
      note: "320 ms ease-out in, 200 ms ease-in out: a pass nearly flashes.",
      props: { curve: "ease-out" },
      play: ran,
    },
    slow: {
      note: "600 ms ease-out in, 300 ms out: a look never reads as a response.",
      props: { curve: "slow" },
      play: ran,
    },
    before: {
      note: "Before: 100 ms delay, then 120 ms. A pass shows nothing; a 200 ms look flashes to full.",
      props: { curve: "before" },
      play: ran,
    },
  },
});
