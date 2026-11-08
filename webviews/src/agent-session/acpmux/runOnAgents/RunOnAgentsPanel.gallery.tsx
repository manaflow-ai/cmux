// l10n-allow-file: gallery fixtures, not shipped UI.
// Run on N agents' panel over a composer. Three looks were drawn against the batch-launch reference
// (a full modal with a count slider and tool checkboxes): rows (one line per agent: agent, model,
// effort, remove), pills (the same picks as wrapped chips) and cards (one small column per agent,
// as the runs card draws them after). Picked: rows. It reads like the result card's columns turned
// on their side, scans top to bottom, keeps a fixed 32px row so adding or removing an agent moves
// only the rows under it, and fits a narrow pane; pills wrapped unevenly at three agents and cards
// ran out of width at four. The other two are gallery-only (RunOnAgentsPanel.gallery.css).
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { PickerCatalog, PickerHarness } from "../modelCatalogData";
import { RunOnAgentsPanel } from "./RunOnAgentsPanel";
import type { RunVariant } from "./runOnAgents";

type Props = {
  prompt?: string;
  initial?: RunVariant[];
  look?: "rows" | "pills" | "cards";
  refuse?: string;
};

const model = (id: string, shortName: string, efforts: string[] = []) =>
  ({ id, name: shortName, shortName, efforts, fast: false, searchText: id }) as PickerHarness["models"][number];
const harness = (id: string, name: string, models: PickerHarness["models"]): PickerHarness => ({
  id,
  name,
  brand: id,
  acpmuxHarness: id,
  installed: true,
  pickable: true,
  models,
});
const catalog: PickerCatalog = {
  provisional: false,
  harnesses: [
    harness("claude", "Claude", [
      model("claude-opus-5-5", "Opus 5.5", ["low", "medium", "high", "max"]),
      model("claude-sonnet-5-5", "Sonnet 5.5", ["low", "medium", "high"]),
    ]),
    harness("codex", "Codex", [model("gpt-6.1-sol", "GPT-6.1 Sol", ["medium", "high", "xhigh"])]),
    harness("opencode", "OpenCode", []),
  ],
};
const four: RunVariant[] = [
  { harness: "claude", model: "claude-opus-5-5", effort: "high" },
  { harness: "codex", model: "gpt-6.1-sol", effort: "xhigh" },
  { harness: "claude", model: "claude-sonnet-5-5" },
  { harness: "opencode" },
];

function GalleryRunOn({ prompt = "Make uploads retry on a 429 with backoff", initial, look = "rows", refuse }: Props) {
  return (
    <div className="acpmux-shell">
      <div data-run-on-fixture data-run-on-look={look} style={{ flex: 1, minWidth: 0, padding: 12, paddingTop: 24 }}>
        <RunOnAgentsPanel
          catalog={catalog}
          prompt={prompt}
          initial={initial}
          onRun={async () => {
            if (refuse) throw new Error(refuse);
          }}
          onClose={() => undefined}
        />
      </div>
    </div>
  );
}

const addAgent: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-run-on-add" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-run-on-row").length === 4);
};

export default componentEntry<Props>({
  id: "agent-pane.run-on-agents",
  title: "Run on N agents",
  area: "Agent pane",
  pane: true,
  height: 300,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: "[data-run-on-fixture]" }],
  covers: ["agent-session/acpmux/runOnAgents/RunOnAgentsPanel.tsx#RunOnAgentsPanel"],
  styles: () => Promise.all([import("../styles.css"), import("./RunOnAgentsPanel.gallery.css")]),
  load: async () => GalleryRunOn,
  variants: {
    rows: {
      note: "Picked look. Opened from the + menu, /run-on or ⌘⇧Return: Claude Opus, Codex and Claude Sonnet, Run on 3 agents.",
      props: {},
    },
    pills: {
      note: "Alternative, not shipped: the same picks as wrapped chips. Uneven wrap at three agents.",
      props: { look: "pills" },
    },
    cards: {
      note: "Alternative, not shipped: one small column per agent, like the runs card. Too narrow at four.",
      props: { look: "cards", initial: four },
    },
    four: {
      note: "The most a run takes: Add agent is off at four, each row with its own model and effort.",
      props: { initial: four },
    },
    "add-press": {
      note: "Add agent pressed: a fourth row (the agent the run does not use yet) appears under the others; nothing above moves.",
      props: {},
      play: addAgent,
    },
    empty: {
      note: "No prompt yet: Run is off and the heading says to type one first.",
      props: { prompt: "" },
    },
    refused: {
      note: "acpmux refused the run (the chat's sub-session limit): the panel stays with the reason, the prompt is kept.",
      props: { refuse: "this chat already runs its most sub-sessions (8)" },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-run-on-run" });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-run-on-note[role="alert"]'));
      },
    },
  },
});
