// l10n-allow-file: gallery fixtures (subagent names), not shipped UI.
// The line a group of subagents that started together draws (SubagentStartedLine.tsx,
// startedLine.experiment.ts). Leo, 2026-11-22, on "✧ M… , ✧ iO… , ✧ i… , ✧ T… , ✧ S… , ✧ E… , and
// ✧ Li… started working": "this is so fucking awkward as ui. unilaterally, literally anything else
// would be a motherfucking improvement. go debate figure shit out. try some variants." Seven
// subagents in a 420px pane, as his was, under each look; then two and one, which every look names
// whole. Synthetic data.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import type { Subagent } from "./subagentFold";
import { startedLineLook } from "./startedLine.experiment";

type Props = { count: number; pane?: number };

/// Leo's seven, by what they did (his chips read M…, iO…, i…, T…, S…, E…, Li…).
const NAMES = [
  "Mac grant switch",
  "iOS relay probe",
  "inbox held count",
  "Tray header clip",
  "Subagent fork chips",
  "Experiment registry sweep",
  "Linux fieldwork",
];

const agent = (name: string, index: number): Subagent => ({
  id: `started-agent-${index}`,
  parent: null,
  name,
  task: name,
  state: "running",
  startedAt: minutesAgo(2),
});

const started = (count: number): AcpmuxRow => ({
  id: "gallery-started",
  version: 1,
  kind: "subagentStarted" /* subagentRows.ts SUBAGENT_STARTED */,
  at: minutesAgo(2),
  subagents: NAMES.slice(0, count).map(agent),
});

/// Opens the count (the `count` look); the other looks have nothing to open.
const openCount: Play = async (ctx) => {
  if (!ctx.document.querySelector(".cv-subagent-started.is-count")) return;
  await ctx.click({ selector: ".cv-subagent-started.is-count" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-started__names") !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.subagent-started-line",
  title: "Subagents started: the grouped line",
  area: "Agent pane",
  pane: true,
  height: 320,
  widths: { narrow: 420, normal: 760 },
  anchors: [{ selector: "[data-started-line-gallery]" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentStartedLine.tsx#SubagentStartedLine",
    "agent-session/acpmux/subagents/startedLine.experiment.ts",
  ],
  experiment: { definition: startedLineLook, script: [{ name: "Leo's seven", run: async () => {} }] },
  load: async () => {
    const { SubagentStartedLine } = await import("./SubagentStartedLine");
    const { SubagentNavContext } = await import("./subagentGroupModel");
    return function GalleryStartedLine({ count, pane }: Props) {
      return (
        <SubagentNavContext.Provider value={() => undefined}>
          <main
            className="acpmux-shell"
            data-started-line-gallery
            style={{ padding: "16px", flexDirection: "column", gap: "0", ...(pane ? { width: `${pane}px` } : {}) }}
          >
            <section className="acpmux-row">
              <SubagentStartedLine row={started(count)} />
            </section>
          </main>
        </SubagentNavContext.Provider>
      );
    };
  },
  styles: () =>
    Promise.all([import("../styles.css"), import("../conversation/conversation.css"), import("./subagents.css")]),
  variants: {
    seven: {
      note: 'Leo\'s seven in a 420px pane. The pick (count): their icons and "7 subagents started working", one line that never cuts a name; a click opens them.',
      props: { count: 7 },
    },
    "seven-open": {
      note: "The count opened: one line per subagent, every name whole, each opening its chat.",
      props: { count: 7 },
      play: openCount,
    },
    two: {
      note: "Two read whole in the sentence, no count to open.",
      props: { count: 2 },
    },
    one: {
      note: "One: its name whole.",
      props: { count: 1 },
    },
  },
});
