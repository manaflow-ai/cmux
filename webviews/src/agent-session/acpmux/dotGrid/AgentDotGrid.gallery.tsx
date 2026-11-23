// l10n-allow-file: gallery fixture session titles, not shipped UI.
//
// The agent dot grid (agent-dot-grid experiment, off by default): every agent chat across workspaces
// as one dot on the new chat's home. Fill and outline carry the state, running dots pulse (1.8 s),
// a state change fades its colors (0.3 s). Hover a dot for its chat's name; a click opens the chat.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { session } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxSessionEntry, SessionIndicator } from "../sessionList";
import { AgentDotGrid } from "./AgentDotGrid";

type Props = ComponentProps<typeof AgentDotGrid>;

const onSelect = () => undefined;

const chat = (sessionId: string, title: string, indicator?: SessionIndicator, unread = false): AcpmuxSessionEntry =>
  session({ sessionId, title, ...(indicator ? { indicator } : {}), unread, updatedAt: minutesAgo(3) });

const four: AcpmuxSessionEntry[] = [
  chat("dots-1", "Fix the checkout page", "working"),
  chat("dots-2", "Investigate the build cache", "input"),
  chat("dots-3", "Release notes", "done", true),
  chat("dots-4", "Settings sign-in"),
];

const TITLES = [
  "Refactor the router",
  "Upgrade the bundler",
  "Flaky upload test",
  "Docs for the CLI",
  "Theme tokens",
  "Search ranking",
  "Image cache",
  "Billing webhook",
];
// A spread like a busy day: mostly running and idle, a few asks, done and failures.
const PATTERN: Array<[SessionIndicator | undefined, boolean]> = [
  ["working", false],
  ["working", false],
  [undefined, false],
  ["input", false],
  ["working", false],
  ["done", true],
  [undefined, false],
  ["failed", false],
  ["working", false],
  [undefined, false],
];
const forty: AcpmuxSessionEntry[] = Array.from({ length: 40 }, (_, index) => {
  const [indicator, unread] = PATTERN[index % PATTERN.length]!;
  return chat(`dots-40-${index}`, `${TITLES[index % TITLES.length]} ${index + 1}`, indicator, unread);
});

const allStates: AcpmuxSessionEntry[] = [
  chat("state-input", "Needs approval", "input"),
  chat("state-failed", "Failed", "failed"),
  chat("state-lost", "Machine lost", "lost"),
  chat("state-working", "Running", "working"),
  chat("state-done", "Done, unread", "done", true),
  chat("state-idle", "Idle"),
];

export default componentEntry<Props>({
  id: "agent-pane.agent-dot-grid",
  title: "Agent dot grid",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 220,
  widths: { narrow: 360, normal: 560, wide: 760 },
  covers: ["agent-session/acpmux/dotGrid/AgentDotGrid.tsx#AgentDotGrid"],
  load: () => import("./AgentDotGrid").then((module) => module.AgentDotGrid),
  variants: {
    "four-agents": {
      note: "Four chats: running (solid, pulsing), needs approval (thick ring), done (solid), idle (thin ring).",
      props: { sessions: four, currentId: "dots-4", onSelect },
    },
    "forty-agents": {
      note: "Forty chats wrap into a field; each keeps its place when its state changes.",
      props: { sessions: forty, onSelect },
    },
    "all-states-legend": {
      note: "Every state with the legend and its count: lost counts as an error.",
      props: { sessions: allStates, onSelect, legend: true },
    },
    "compact-forty": {
      note: "The compact arm: dense 6px dots for the same forty chats.",
      props: { sessions: forty, onSelect, size: "compact" },
    },
  },
});
