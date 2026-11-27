// l10n-allow-file: gallery fixtures (subagent names and tasks), not shipped UI.
// A subagent name chip's hover preview (SubagentPreview.tsx). Leo, 2026-11-14, on a grouped
// "✧ St… , ✧ To… , ✧ P… , … and ✧ F… started working" row whose nine chips were cut to a letter or
// two: "there's no hover preview on these". Pointing at a chip, or focusing it from the keyboard,
// shows the subagent's whole name, its state, its latest output and its task, on the shared hover
// card (the tooltip layer's glass), so nothing in the transcript moves.
//
// From the design references: a session hover card (status-and-progress topic,
// a status pill, then the title and its context) and Codex mobile's agents sheet
// (`codex-mobile/live/agents-sheet-active-completed`: a name, then Working or Done); and the card
// Session Info's Subagents lines already show (session-info/SubagentsSection.tsx). Three looks:
// - `card` (the pick, shipped): Session Info's card, one surface for every subagent hover: the name
//   emphasized, a muted state line, the latest output, the task dim;
// - `status-pill`: the reference card's, the state as a tinted pill above the name;
// - `name-only`: the plain tooltip, the name with the task as its detail line.
// The other variants hover a chip in each place one renders: the grouped start line, a single start
// line, a finished line, and the keyboard's way in. Synthetic data.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import type { Subagent } from "./subagentFold";

type Look = "card" | "status-pill" | "name-only";

type Props = {
  /// How many of the fixture's subagents the start line names.
  count: number;
  /// Draw a finished line too, under the start line.
  done?: boolean;
  /// A compared look, drawn open under the line (gallery only); unset, the shipped card on hover.
  look?: Look;
  /// The pane's width in CSS px.
  pane?: number;
  /// Where the lines sit in the stage: at its top edge (no room above the chip) or its bottom edge.
  edge?: "top" | "bottom";
};

type Fixture = { name: string; task: string; kind?: string; action?: string; state?: string; ran: number };

/// Nine subagents, as Leo's row had: each chip cut to a letter or two in a narrow pane.
const FIXTURES: Fixture[] = [
  {
    name: "Stage the release notes",
    task: "Stage the release notes for the nightly from merged PRs since the last tag",
    action: "Read CHANGELOG.md",
    ran: 3,
  },
  {
    name: "Tool-call audit",
    task: "Audit every tool call row for the shared row grammar and list each one that drifts",
    kind: "Explore",
    action: "Grep cv-tool__text",
    ran: 4,
  },
  {
    name: "Profile the cold start",
    task: "Profile the agent pane's cold start and name the three slowest imports",
    action: "Run bun run bench:cold",
    ran: 2.5,
  },
  { name: "Queue drain fix", task: "Fix the queued prompt that never drains after a harness switch", ran: 1.5 },
  { name: "gallery variants for tray", task: "Add three gallery variants for the tray's rim and pick one", ran: 1 },
  { name: "Pricing page copy", task: "Rewrite the pricing page copy in plain English, short sentences", ran: 5 },
  {
    name: "Push relay",
    task: "Push the relay bundle to the GCP lanes and confirm each one answers",
    action: "Run gcloud compute ssh lane-2",
    ran: 2,
  },
  {
    name: "Accessibility sweep",
    task: "Sweep the composer for controls without an accessible name",
    kind: "general-purpose",
    ran: 0.8,
  },
  {
    name: "Find bar flicker",
    task: "Find why the find bar flickers when the transcript streams",
    state: "completed",
    ran: 6,
  },
];

const agent = (fixture: Fixture, index: number): Subagent => ({
  id: `preview-agent-${index}`,
  parent: null,
  name: fixture.name,
  task: fixture.task,
  ...(fixture.kind && { kind: fixture.kind }),
  ...(fixture.action && { action: fixture.action }),
  state: fixture.state ?? "running",
  startedAt: minutesAgo(fixture.ran + 1),
  ...(fixture.state === "completed" && {
    endedAt: minutesAgo(1),
    lastMessage: "The find bar re-measured on every streamed token; it now measures once per frame.",
  }),
});

const started = (count: number): AcpmuxRow => ({
  id: "preview-started",
  version: 1,
  kind: "subagentStarted" /* subagentRows.ts SUBAGENT_STARTED */,
  at: minutesAgo(7),
  subagents: FIXTURES.slice(0, count).map(agent),
});

const finished = (): AcpmuxRow => {
  const done = agent(FIXTURES[8]!, 8);
  return { id: "preview-done", version: 1, kind: "subagentDone", at: done.endedAt!, subagents: [done] };
};

const CHIP = ".cv-subagent-started button.cv-agent-tag";
const PREVIEW = ".acpmux-subagent-preview";
const shown = (ctx: Parameters<Play>[0]) => ctx.document.querySelector(PREVIEW) !== null;

const hoverChip =
  (selector: string): Play =>
  async (ctx) => {
    await ctx.hover({ selector });
    await ctx.waitFor(() => shown(ctx));
  };

export default componentEntry<Props>({
  id: "agent-pane.subagent-chip-preview",
  title: "Subagent chip hover preview",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  anchors: [{ selector: "[data-subagent-preview-gallery]" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentPreview.tsx",
    "agent-session/acpmux/subagents/SubagentStartedLine.tsx#SubagentStartedLine",
    "agent-session/acpmux/subagents/SubagentDoneLine.tsx#SubagentDoneLine",
    "agent-session/acpmux/conversation/AgentTag.tsx#AgentTag",
  ],
  load: async () => {
    // This entry is about the chips' cards, so it keeps every name a chip (startedLineCrowd.experiment.ts
    // `chips`); many starting at once read as icons and a count by default.
    globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, "subagent-started-crowd": "chips" };
    const { SubagentStartedLine } = await import("./SubagentStartedLine");
    const { SubagentDoneLine } = await import("./SubagentDoneLine");
    const { SubagentPreviewCard } = await import("./SubagentPreview");
    const { SubagentNavContext } = await import("./subagentGroupModel");
    return function GallerySubagentChipPreview({ count, done, look, pane, edge }: Props) {
      const row = started(count);
      const first = row.subagents![1]!;
      return (
        <SubagentNavContext.Provider value={() => undefined}>
          <main
            className="acpmux-shell subagent-preview-gallery"
            data-subagent-preview-gallery
            style={{
              padding: edge ? "var(--ds-space-1) 16px" : "16px",
              flexDirection: "column",
              gap: "0",
              ...(pane ? { width: `${pane}px` } : {}),
              ...(edge && {
                boxSizing: "border-box",
                height: "100vh",
                justifyContent: edge === "top" ? "flex-start" : "flex-end",
              }),
            }}
          >
            <section className="acpmux-row">
              <SubagentStartedLine row={row} />
            </section>
            {done && (
              <section className="acpmux-row">
                <SubagentDoneLine row={finished()} />
              </section>
            )}
            {/* A compared look, drawn open where its card would float (gallery only). */}
            {look === "card" && (
              <div className="ui-tooltip ui-glass ui-card acpmux-agent-card__popup acpmux-subagent-preview subagent-preview-gallery__open">
                <SubagentPreviewCard agent={first} />
              </div>
            )}
            {look === "status-pill" && (
              <div className="ui-tooltip ui-glass ui-card acpmux-agent-card__popup subagent-preview-gallery__open">
                <span className="acpmux-agent-card">
                  <span className="subagent-preview-gallery__pill">Running · 5m 0s</span>
                  <span className="acpmux-agent-card__name">{first.task}</span>
                  <span className="acpmux-agent-card__task">
                    {first.kind} · {first.action}
                  </span>
                </span>
              </div>
            )}
            {look === "name-only" && (
              <div className="ui-tooltip ui-glass subagent-preview-gallery__open">
                <span className="ui-tooltip-text">{first.task}</span>
                <span className="ui-tooltip-detail">{first.name}</span>
              </div>
            )}
          </main>
        </SubagentNavContext.Provider>
      );
    };
  },
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("./subagents.css"),
      import("./SubagentChipPreview.gallery.css"),
    ]),
  variants: {
    card: {
      note: "The pick: Session Info's subagent card, shared by every subagent hover. Whole name emphasized, then state, time, its own name and kind, then its latest output, then its task.",
      props: { count: 9, pane: 560, look: "card" },
    },
    "status-pill": {
      note: "Version B, after the session hover card reference: the state as a tinted pill above the name. A second card style next to Session Info's.",
      props: { count: 9, pane: 560, look: "status-pill" },
    },
    "name-only": {
      note: "Version C: the plain tooltip, the name and a detail line. No state and no latest output, so it can't tell a running agent from a stuck one.",
      props: { count: 9, pane: 560, look: "name-only" },
    },
    grouped: {
      note: "Leo's row at rest: nine chips cut to a letter or two, and a finished line (the browser test hovers these).",
      props: { count: 9, pane: 560, done: true },
    },
    "grouped-hover": {
      note: "Leo's row: nine chips cut to a letter or two; pointing at the second shows its card above it, and no row moves.",
      props: { count: 9, pane: 560, done: true },
      play: hoverChip(`${CHIP}:nth-of-type(2)`),
    },
    "single-hover": {
      note: "One subagent's start line: its chip has the same card.",
      props: { count: 1, pane: 560 },
      play: hoverChip(CHIP),
    },
    "done-hover": {
      note: "A finished line's chip: Done, how long it ran, and the last line it said.",
      props: { count: 2, pane: 560, done: true },
      play: hoverChip(".cv-subagent-done-row .cv-agent-tag"),
    },
    "near-top-hover": {
      note: 'Leo, 2026-11-22, on a hover card drawn over its row: "and more bullshit somehow happened here". The line at the stage\'s top edge: no room above, so the card flips below the row, never onto its words.',
      props: { count: 9, pane: 560, done: true, edge: "top" },
      play: hoverChip(`${CHIP}:nth-of-type(2)`),
    },
    "near-bottom-hover": {
      note: "The lines at the stage's bottom edge: the finished line's card opens above its row, clear of the words it describes.",
      props: { count: 9, pane: 560, done: true, edge: "bottom" },
      play: hoverChip(".cv-subagent-done-row .cv-agent-tag"),
    },
    "keyboard-focus": {
      note: "Tab onto a chip: the card shows for keyboard focus too; Enter still opens the subagent.",
      props: { count: 9, pane: 560 },
      play: async (ctx) => {
        await ctx.focus({ selector: `${CHIP}:nth-of-type(3)` });
        await ctx.waitFor(() => shown(ctx));
      },
    },
  },
});
