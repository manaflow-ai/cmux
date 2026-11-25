// l10n-allow-file: gallery fixture labels, not shipped UI.
// A running tool row's shimmer (Leo, 2026-11-03, on a running "Monitor" row whose spinner sat at the
// transcript's far edge: "this is kinda weird looking" / "doesn't claude desktop have the thinking
// shimmer go across stuff"). The real rows: "TaskStop" finished, "Monitor" running in the
// background, a read and a command running, a finished read. Each arm sets the band's width,
// period or lit colour (conversation.css `--cv-row-shimmer-*`); `still` is Reduce Motion.
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxActivity } from "../model";
import { CommandRow } from "./CommandRow";
import { ToolRow } from "./ToolRow";

type Look = "shipped" | "narrow" | "wide" | "quick" | "accent" | "still";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const call = (tool: Partial<Tool> & { id: string }): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { title: "", kind: "other", status: "completed", startedAt: 1000, endedAt: 3000, ...tool },
});

const ROWS: AcpmuxActivity[] = [
  call({ id: "shimmer-taskstop", title: "TaskStop" }),
  call({ id: "shimmer-monitor", title: "Monitor", background: { state: "running" } }),
  call({ id: "shimmer-read", kind: "read", title: "Read src/checkout/ProductGrid.tsx", status: "in_progress" }),
  call({ id: "shimmer-command", kind: "execute", command: "bun test src/checkout", status: "in_progress" }),
  call({ id: "shimmer-done", kind: "read", title: "Read src/checkout/cart.ts" }),
];

function ToolRowShimmer({ look }: { look: Look }) {
  return (
    <div className="acpmux-shell cv-tool-row-shimmer-looks" data-look={look}>
      <div className="acpmux-row" style={{ position: "relative", width: "100%" }}>
        <div className="cv-tools">
          {ROWS.map((item) =>
            item.tool!.command ? (
              <CommandRow key={item.tool!.id} item={item} />
            ) : (
              <ToolRow key={item.tool!.id} item={item} />
            ),
          )}
        </div>
      </div>
    </div>
  );
}

export default componentEntry<{ look: Look }>({
  id: "agent-pane.tool-row-shimmer",
  title: "Running tool row: shimmer",
  area: "Agent pane",
  pane: true,
  height: 200,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: ["agent-session/acpmux/conversation/ShimmerText.tsx#RowShimmer"],
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./ToolRowShimmer.gallery.css")]),
  load: async () => ToolRowShimmer,
  variants: {
    shipped: {
      note: "Shipped: the Thinking line's band (40% of the words) and clock (2.8 s), dim words lit to the text colour.",
      props: { look: "shipped" },
    },
    narrow: {
      note: "A fixed 48 px band, ChatGPT's few letters at a time, on the same clock.",
      props: { look: "narrow" },
    },
    wide: {
      note: "A 70% band: a broad glow across the words.",
      props: { look: "wide" },
    },
    quick: {
      note: "The shipped band on a 1.8 s clock: a faster sweep, out of step with the Thinking line.",
      props: { look: "quick" },
    },
    accent: {
      note: "The Thinking line's lit colour: the band tinted with the theme accent.",
      props: { look: "accent" },
    },
    still: {
      note: "Reduce Motion: the running words rest dimmed and hold still.",
      props: { look: "still" },
    },
  },
});
