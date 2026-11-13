// l10n-allow-file: isolated gallery prototype, not shipped UI.
// Agent Board (2026-11-13): an off-by-default board of what each agent built, its decisions,
// every permutation and the evidence, fed by the work-tracking skill's ledger.
import { componentEntry } from "../../gallery/format";
import type { AgentBoardProps } from "./AgentBoard";

const PHONE = { platform: "iphone" as const };

export default componentEntry<AgentBoardProps>({
  id: "prototype.agent-board",
  title: "Agent Board",
  area: "Prototypes",
  experimental: true,
  keywords: ["agent", "tracker", "ledger", "evidence", "decisions", "permutations", "work-tracking", "onboarding"],
  covers: [
    "prototypes/agent-board/AgentBoard.tsx",
    "prototypes/agent-board/Onboarding.tsx",
    "prototypes/agent-board/views.tsx",
    "prototypes/agent-board/parts.tsx",
  ],
  load: () => import("./AgentBoard").then((module) => module.AgentBoard),
  styles: () => import("./agent-board.css"),
  height: 860,
  widths: { narrow: 390, normal: 1180, wide: 1500 },
  variants: {
    "onboarding-off": {
      note: "Off by default: what Agent Board does and why it costs more tokens, with one button to turn it on.",
      props: { state: "off" },
    },
    "onboarding-confirm": {
      note: "Turn On asks once, with the cost restated; Return turns it on, Escape cancels.",
      props: { state: "confirm" },
    },
    "on-empty": {
      note: "Just turned on: nothing recorded yet; only sessions started from now on are tracked.",
      props: { state: "on-empty" },
    },
    loading: { note: "Reading the ledgers.", props: { state: "loading" } },
    ledger: {
      note: "Ledger: capabilities as a dense list, each opening to its states and evidence; decisions in a rail.",
      props: { state: "live", design: "ledger" },
    },
    matrix: {
      note: "Matrix: every capability as a grid of its states, the proof in each cell.",
      props: { state: "live", design: "matrix" },
    },
    story: {
      note: "Story: the work in the order it happened, each decision with what was turned down.",
      props: { state: "live", design: "story" },
    },
    "ledger-needs-you": {
      note: "Needs you: only unproven or broken states and decisions flagged for a person.",
      props: { state: "live", design: "ledger", needsYou: true },
    },
    "matrix-needs-you": { props: { state: "live", design: "matrix", needsYou: true } },
    "story-needs-you": { props: { state: "live", design: "story", needsYou: true } },
    error: {
      note: "A ledger with unreadable lines: they show as an error, the rest of the board still works.",
      props: { state: "error", design: "ledger" },
    },
    stress: {
      note: "18 agents with long names.",
      props: { state: "stress", design: "ledger" },
    },
    "iphone-onboarding": { props: { state: "off", ...PHONE } },
    "iphone-ledger": { props: { state: "live", design: "ledger", ...PHONE } },
    "iphone-matrix": { props: { state: "live", design: "matrix", ...PHONE } },
    "iphone-story": { props: { state: "live", design: "story", ...PHONE } },
  },
});
