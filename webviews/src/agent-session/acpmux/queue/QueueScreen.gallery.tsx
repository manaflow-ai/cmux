// l10n-allow-file: gallery fixtures, public-safe sample asks and chats.
// Waiting on you (History > Waiting on you, QueueScreen.tsx): three looks of the same queue and its
// states. `inbox` ships: two lines a row, the answers on the selected row only.
import type { ComponentProps } from "react";
import { minutesAgo } from "../../../gallery/clock";
import { componentEntry } from "../../../gallery/format";
import type { QueueScreen } from "./QueueScreen";

type Props = ComponentProps<typeof QueueScreen>;

const allowDeny = [
  { optionId: "allow", name: "Allow", kind: "allow_once" },
  { optionId: "always", name: "Always allow", kind: "allow_always" },
  { optionId: "deny", name: "Deny", kind: "reject_once" },
];

const items = [
  {
    id: "acpmux:p-plan",
    kind: "plan",
    sessionId: "s-plan",
    title: "Port the sidebar to the new layout",
    harness: "claude",
    ask: "Approve the plan to move the sidebar onto the shared row geometry",
    detail:
      "1. Move the row metrics into one token set\n2. Replace the three list components with the shared list\n3. Keep the old look behind a setting for one release\n4. Run the gallery and the list tests",
    at: minutesAgo(18),
    impact: 9,
    impactReasons: ["blocksTurn", "queuedPrompts:2", "costUsd:3.40"],
    score: 9.4,
    permissionId: "p-plan",
    options: [
      { optionId: "go", name: "Approve plan", kind: "allow_once" },
      { optionId: "stay", name: "Keep planning", kind: "reject_once" },
    ],
  },
  {
    id: "acpmux:p-run",
    kind: "approval",
    sessionId: "s-run",
    title: "Fix the flaky upload test",
    harness: "codex",
    ask: "Run bun test test/upload.test.ts",
    detail: "bun test test/upload.test.ts --rerun-each 20",
    at: minutesAgo(6),
    impact: 6,
    impactReasons: ["blocksTurn", "subsessions:3"],
    score: 6.1,
    permissionId: "p-run",
    options: allowDeny,
  },
  {
    id: "acpmux:p-ask",
    kind: "question",
    sessionId: "s-ask",
    title: "Profile cold startup",
    harness: "claude",
    ask: "Which build should I profile?",
    at: minutesAgo(31),
    impact: 4,
    impactReasons: ["blocksTurn", "age"],
    score: 5.2,
    permissionId: "p-ask",
    options: [
      { optionId: "nightly", name: "Nightly" },
      { optionId: "dev", name: "This branch's dev build" },
      { optionId: "both", name: "Both, side by side" },
    ],
  },
  {
    id: "pr:https://example.com/acme/app/pull/412",
    kind: "pr",
    sessionId: "s-pr",
    title: "Add retry to the upload client",
    harness: "claude",
    ask: "acme/app #412 Upload retry is ready for review",
    at: minutesAgo(52),
    impact: 3,
    impactReasons: ["costUsd:1.10"],
    score: 3.3,
    prUrl: "https://example.com/acme/app/pull/412",
  },
  {
    id: "acpmux:p-peer",
    kind: "approval",
    sessionId: "s-peer",
    host: "studio",
    title: "Trim the agent pane bundle",
    harness: "codex",
    ask: "Write to webviews/package.json",
    at: minutesAgo(70),
    impact: 2,
    impactReasons: ["blocksTurn"],
    score: 2.4,
    permissionId: "p-peer",
    options: allowDeny,
  },
];

const reply = { items, now: minutesAgo(0) };
const done = async () => undefined;
const base: Props = {
  load: async () => reply,
  answer: async () => "answered",
  verdict: done,
  open: () => undefined,
  exportAudit: async () => 128,
  openReview: () => undefined,
};

/// Many machines' worth of asks: the list stays one frame's work (memoized rows, content-visibility).
const many = Array.from({ length: 300 }, (_, index) => ({
  ...items[index % items.length]!,
  id: `acpmux:many-${index}`,
  permissionId: `many-${index}`,
  score: 300 - index,
  at: minutesAgo(index * 3),
}));

export default componentEntry<Props>({
  id: "agent-pane.review-queue",
  title: "Waiting on you",
  area: "Agent pane",
  covers: ["agent-session/acpmux/queue/QueueScreen.tsx#QueueScreen"],
  styles: () => Promise.all([import("../styles.css"), import("../keys.css"), import("./queue.css")]),
  load: () => import("./QueueScreen").then((module) => module.QueueScreen),
  widths: { narrow: 380, normal: 720, wide: 960 },
  height: 560,
  anchors: [{ selector: ".wq" }],
  variants: {
    inbox: {
      note: "Shipped: two lines a row, the answers on the selected row only, why it ranks high under the ask.",
      props: base,
    },
    cards: {
      note: "Alternative: every row a tonal card with its answers and detail showing.",
      props: { ...base, look: "cards" },
    },
    compact: {
      note: "Alternative: one line a row, answered by the app's permission shortcuts only.",
      props: { ...base, look: "compact" },
    },
    many: {
      note: "300 asks across machines: moving the cursor redraws two rows.",
      props: { ...base, load: async () => ({ items: many, now: minutesAgo(0) }) },
    },
    unreached: {
      note: "A machine that did not answer the read is named under the list.",
      props: { ...base, load: async () => ({ ...reply, peersOmitted: ["laptop"] }) },
    },
    loading: {
      note: "The first read is on its way: the status line holds the list's place.",
      props: { ...base, load: () => new Promise(() => {}) },
    },
    empty: {
      note: "Nothing waits on the person.",
      props: { ...base, load: async () => ({ items: [], now: minutesAgo(0) }) },
    },
    older: {
      note: "This Mac's acpmux predates the queue: it says so instead of failing.",
      props: { ...base, load: async () => Promise.reject({ code: -32601, message: "Method not found" }) },
    },
  },
});
