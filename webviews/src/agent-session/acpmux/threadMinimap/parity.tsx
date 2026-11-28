// Dev server only (threadMinimap/parity.html): the minimap over the Codex reference's nine turns,
// in the reference theme, so a capture compares frame by frame with reference.mov. The transcript
// rows are absent; the layout gives each turn a fixed height.
import "../../shared/styles.css";
import "./threadMinimap.css";
import React, { useRef } from "react";
import { createRoot } from "react-dom/client";
import type { AcpmuxRow } from "../model";
import { ThreadMinimap } from "./ThreadMinimap";

globalThis.__cmuxPaneStrings ??= (await import("../generated/strings.json")).default;

const turns: [string, string][] = [
  [
    "let's work on harness research stuff together, starting from the chief of staff idea",
    "My starting hypothesis: **one chief of staff that owns priorities, saved state for each project, and temporary workers for specific tasks.**",
  ],
  [
    "let's enumerate every possible topology and compare them",
    "Yes. The “chief plus workers” design assumes a human organization: one accountable coordinator, delegated labor, and summarized reporting back up the chain.",
  ],
  [
    "i want to see visualizations of each open it the right panel",
    "I created an interactive topology explorer and opened it in the right panel. It includes:\n\n- Central planner\n- Blackboard\n- Market",
  ],
  [
    "```mermaid flowchart TD U[You] <--> C[Chief] C --> W1[Worker]",
    "I will replace the node diagrams with Mermaid flowcharts for all topology families, start a local preview, and open that preview in the right panel.",
  ],
  [
    "u opened the file but not browser? maybe open it in chrome",
    "The Mermaid flowcharts are now open in Chrome in the right panel. I corrected the rendering issue, and all topology diagrams display: chief, swarm, market and pipeline.",
  ],
  [
    "RLM techinically encompasses the chief of staff design right?",
    "Yes, with an important distinction.\n\nAn **RLM is a control strategy for inference**:",
  ],
  [
    "is there a more generalized thing than RLM?",
    "Yes. The more general concept is an **environment-interacting agent runtime**.\n\nAn RLM is one particular operator inside that runtime, alongside tools and memory.",
  ],
  [
    "what are the main issues with rlms",
    "The main issue is that **recursion is not automatically intelligence**. It gives a model more ways to inspect context, but it also gives it more ways to fail.",
  ],
  [
    "remember my idea about convergent thing where events start agents",
    "Built and running: **Convergent**.\n\n- Each event starts a fresh coding agent with an event-file pointer. The agent reads it and converges.",
  ],
];
const rows: AcpmuxRow[] = turns.flatMap(([prompt, reply], index) => [
  { id: `user-${index}`, version: 1, at: index + 1, kind: "user", text: prompt },
  { id: `reply-${index}`, version: 1, at: index + 1, kind: "assistant", text: reply },
]);
const TURN = 400;
const tops = new Float64Array(rows.map((_, index) => (index >> 1) * TURN + (index & 1) * 60));
const heights = new Float64Array(rows.map((_, index) => (index & 1 ? TURN - 60 : 60)));
const layout = { tops, heights, totalHeight: turns.length * TURN };
const params = new URLSearchParams(location.search);
const width = Number(params.get("w") ?? 546);
const height = Number(params.get("h") ?? 336);
/// The reference rests on its seventh turn.
const scrollTop = Number(params.get("top") ?? 6 * TURN);

function Parity() {
  const scroller = useRef<HTMLDivElement>(null);
  return (
    <div ref={scroller} style={{ width, height, overflow: "hidden", position: "relative" }}>
      <ThreadMinimap
        rows={rows}
        layout={layout}
        scroller={scroller}
        scrollTop={scrollTop}
        viewportHeight={height}
        width={Math.max(width, 900)}
      />
    </div>
  );
}

document.documentElement.style.setProperty("--agent-text", "rgb(255 255 254)");
document.documentElement.style.setProperty("--agent-page-bg", "rgb(33 33 28)");
document.documentElement.style.setProperty("--acpmux-base", "rgb(33 33 28)");
document.body.style.cssText = "margin:0;background:rgb(33 33 28)";
createRoot(document.getElementById("root")!).render(<Parity />);
