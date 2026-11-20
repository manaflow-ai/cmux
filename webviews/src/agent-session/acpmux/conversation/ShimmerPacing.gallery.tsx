// l10n-allow-file: gallery fixture prose and tool names, not shipped copy.
// The glimmer's pacing (Leo, 2026-11-08, "Glimmer pacing": "i know there's some accel/decel aka
// easing"). One pass of the band speeds up out of the left edge and slows into the right; it used to
// walk across at one constant speed (`steps(48, end)`). `eased` ships: the motion scale's sweep curve
// (`--cmux-ease-sweep`, ease-in-out), the curve the Home shimmers already sweep on. The other looks
// are kept to compare: `linear` is the shipped pass before, `strong` a steeper ease-in-out that holds
// at both edges longer, `settle` the fold's curve, a fast start that only decelerates. The live line
// and a running tool row share the curve. A pass starts 0.6 s after the stage shows, then every 4 s.
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import type { AcpmuxActivity } from "../model";
import { Thinking } from "./Thinking";
import { ToolRow } from "./ToolRow";
import { WorkingCountsContext, type WorkingCounts } from "./workingForModel";

type Look = "eased" | "linear" | "strong" | "settle";
type Props = { look: Look };

const START = Date.UTC(2026, 10, 8, 10, 48, 0);
const now = () => START + 12_000;
const counts: WorkingCounts = {
  agents: 0,
  commands: 0,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
  tokens: 1_700,
};

const READ: AcpmuxActivity = {
  kind: "tool",
  text: "",
  tool: {
    id: "pacing-read",
    kind: "read",
    title: "Read src/checkout/ProductGrid.tsx",
    status: "in_progress",
    startedAt: START,
  },
};

function ShimmerPacing({ look }: Props) {
  return (
    <main className="shimmer-pacing acpmux-conversation" data-look={look}>
      <WorkingCountsContext.Provider value={counts}>
        <div className="acpmux-row acpmux-thinking">
          <Thinking since={START} now={now} below />
        </div>
        <div className="acpmux-row acpmux-thinking">
          <Thinking since={START} now={now} doing="Running bun test src/checkout" below />
        </div>
      </WorkingCountsContext.Provider>
      <div className="acpmux-row">
        <div className="cv-tools">
          <ToolRow item={READ} />
        </div>
      </div>
    </main>
  );
}

const variant = (look: Look, note: string): ComponentVariant<Props> => ({ note, props: { look } });

export default componentEntry<Props>({
  id: "agent-pane.shimmer-pacing",
  title: "The glimmer's pacing: one pass eases in and out",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 320, normal: 640 },
  covers: ["agent-session/acpmux/conversation/conversation.css", "agent-session/acpmux/conversation/ShimmerText.tsx"],
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./ShimmerPacing.gallery.css")]),
  load: async () => ShimmerPacing,
  keywords: ["shimmer", "glimmer", "sweep", "easing", "ease", "accel", "decel", "pacing", "thinking"],
  variants: {
    eased: variant("eased", "Chosen: ease-in-out, the motion scale's sweep curve, as the Home shimmers sweep."),
    linear: variant("linear", "Before: one constant speed across the words (steps(48, end))."),
    strong: variant(
      "strong",
      "A steeper ease-in-out (0.65, 0, 0.35, 1): slower at both edges, quicker through the middle.",
    ),
    settle: variant("settle", "The fold's settle curve: a fast start that only decelerates into the right edge."),
  },
});
