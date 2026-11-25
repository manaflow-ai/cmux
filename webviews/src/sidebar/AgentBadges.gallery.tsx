// l10n-allow-file: gallery fixtures, not shipped UI.
// Leo, 2026-11-19: "Count and status badges on tabs and sidebar rows. Neutral count pill for unread
// agent messages or pending approvals, width reserved so tabs never shift; sidebar rows get one
// tinted status pill (Running, Needs approval, Done); variant: a thin light beam travels along the
// row edge while an agent runs. Switch experiments.agentBadges."
// off, pills and beam are the setting's arms (AgentBadgesExperiment.swift); timeline proves zero
// shift; dot-count is an alternative count look.
import { componentEntry } from "../gallery/format";
import type { AgentBadgesProps, BadgeRow, BadgeTab, TimelineFrame } from "./AgentBadges";

const tabs: BadgeTab[] = [
  { title: "Fix the restore test", harness: "claude", unread: 2, approvals: 1, selected: true },
  { title: "Port the ranker", harness: "codex", unread: 0, approvals: 0 },
  { title: "Release notes", harness: "opencode", unread: 12, approvals: 0 },
  { title: "Bench the dock", harness: "pi", unread: 118, approvals: 2 },
];

const rows: BadgeRow[] = [
  { title: "Fix the flaky terminal restore test", harness: "claude", status: "running", selected: true },
  { title: "Port the palette ranker to Rust", harness: "codex", status: "idle" },
  { title: "Draft the release notes", harness: "opencode", status: "approval" },
  { title: "Why does the dock flicker on resize?", harness: "pi", status: "done" },
  { title: "Bump ghostty and rerun the bench", harness: "codex", status: "running" },
];

const tab = (unread: number, approvals: number): BadgeTab => ({
  title: "Fix the restore test",
  harness: "claude",
  unread,
  approvals,
  selected: true,
});
const row = (status: BadgeRow["status"]): BadgeRow => ({
  title: "Fix the flaky terminal restore test",
  harness: "claude",
  status,
});
const timeline: TimelineFrame[] = [
  { label: "Running", tab: tab(0, 0), row: row("running") },
  { label: "Running, 2 messages", tab: tab(2, 0), row: row("running") },
  { label: "Needs approval", tab: tab(2, 1), row: row("approval") },
  { label: "Done, unread", tab: tab(5, 0), row: row("done") },
  { label: "Opened: cleared", tab: tab(0, 0), row: row("idle") },
];

export default componentEntry<AgentBadgesProps>({
  id: "sidebar.agent-badges",
  title: "Agent badges: tab counts and row status (experiments.agentBadges)",
  area: "Sidebar",
  experimental: true,
  covers: ["sidebar/AgentBadges.tsx"],
  height: 280,
  keywords: ["badge", "count", "pill", "status", "beam", "unread", "approval", "agentBadges"],
  load: () => import("./AgentBadges").then((module) => module.AgentBadges),
  variants: {
    off: {
      note: "Today: an unread dot on the tab; spinner, yellow and blue dots on rows",
      props: { look: "off", tabs, rows },
    },
    pills: {
      note: "Neutral count pill in a reserved slot (99+ cap); one tinted status pill per row, idle none",
      props: { look: "pills", tabs, rows },
    },
    beam: {
      note: "Pills, plus a thin light running along each running row's edge (none under Reduce Motion)",
      props: { look: "beam", tabs, rows },
    },
    timeline: {
      note: "One tab and row: Running, Needs approval, Done, opened; dashed guides never move",
      props: { look: "pills", timeline },
    },
    "dot-count": {
      note: "Alternative: the count inside a compact blue dot on the tab; rows as pills",
      props: { look: "dot-count", tabs, rows },
    },
  },
});
