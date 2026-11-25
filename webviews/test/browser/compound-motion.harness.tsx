// The compound motions of the agent pane (conversation/compoundScenarios.tsx), sampled frame by
// frame for the motion map (compound-motion.test.ts). Every frame is sampled after its layout,
// before it paints (a ResizeObserver on a sentinel the frame callback resizes): each mounted row's
// drawn top and the viewport's middle. The URL picks the arm of compound-motion
// (`?arm=transaction|separate`) and the frames' own clock (`?clock=frames`, frameClock.ts).
import "./frameClock";
import { createRoot } from "react-dom/client";
import { loadHighlightedCode } from "../../src/agent-session/acpmux/conversation/codeBlockModel";
import {
  CompoundPane,
  playCompound,
  type CompoundCase,
  type PaneState,
} from "../../src/agent-session/acpmux/conversation/compoundScenarios";
import { nextFrame } from "../../src/agent-session/acpmux/direct";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "katex/dist/katex.min.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/chips/chips.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/bottomStack.css";
import "../../src/agent-session/acpmux/markdownField.css";
import { TOGGLE_CALL_ID } from "../../src/agent-session/acpmux/conversation/scriptedTurn";
import { TRANSCRIPT_ROW } from "../../src/agent-session/acpmux/transcriptSelectors";

const query = new URLSearchParams(location.search);
const arm = query.get("arm");
if (arm) globalThis.cmuxExperiments = { "compound-motion": arm };
// The page measures the motion itself: a loaded runner never turns the chat's minimal motion on.
document.documentElement.setAttribute("data-chat-motion", "full");

let show: (next: Partial<PaneState>) => void = () => {};
const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%", display: "flex", flexDirection: "column" });
createRoot(root).render(<CompoundPane sessionId="compound-motion" bind={(set) => (show = set)} />);

export type RowTop = { id: string; top: number; height: number };
/// `opened`: the toggled call's line reads open (the fold cases' click landed).
/// `bottom`: the viewport's bottom edge (the latest row's gap to it is where the case ends).
export type Sample = { t: number; phase: string; rows: RowTop[]; middle: number; bottom: number; opened: boolean };

const samples: Sample[] = [];
let phase = "idle";
let sampling = false;
const sentinel = document.createElement("div");
Object.assign(sentinel.style, { position: "fixed", left: "0", top: "0", height: "1px", visibility: "hidden" });
document.body.append(sentinel);
let frameAt = 0;
let toggle = false;
let sampler: ResizeObserver | undefined;
const sampleFrame = () => {
  if (!sampling) return;
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) return;
  const view = scroller.getBoundingClientRect();
  const rows: RowTop[] = [];
  for (const row of scroller.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW)) {
    const box = row.getBoundingClientRect();
    if (box.height > 0) rows.push({ id: row.dataset.rowId!, top: box.top, height: box.height });
  }
  const line = scroller.querySelector(`[data-tool-id="${TOGGLE_CALL_ID}"][aria-expanded]`);
  samples.push({
    t: frameAt,
    phase,
    rows,
    middle: (view.top + view.bottom) / 2,
    bottom: view.bottom,
    opened: line?.getAttribute("aria-expanded") === "true",
  });
};
const tick = (t: number) => {
  frameAt = t;
  toggle = !toggle;
  sentinel.style.width = toggle ? "2px" : "1px";
  requestAnimationFrame(tick);
};
requestAnimationFrame(tick);

// fixed-wait: the harness's own pauses, each named where it waits
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function run({ scenario }: { scenario: CompoundCase }) {
  await loadHighlightedCode();
  // fixed-wait: the history's rows measure over the first frames
  await wait(400);
  samples.length = 0;
  // After the transcript's own observers (made at its mount): the rows as this frame paints them.
  if (!sampler) (sampler = new ResizeObserver(sampleFrame)).observe(sentinel);
  sampling = true;
  phase = "idle";
  // fixed-wait: the frames before the case are sampled as its rest
  await wait(100);
  // fixed-wait: the case is a socket's events on its own clock; the frames sampled are the measurement
  await playCompound(scenario, { show, frame: nextFrame, step: (name) => (phase = name), root: document });
  sampling = false;
  return samples;
}

(window as unknown as { __compound: { run: typeof run } }).__compound = { run };
