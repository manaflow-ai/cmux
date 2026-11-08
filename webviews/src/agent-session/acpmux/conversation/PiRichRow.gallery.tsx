import { componentEntry } from "../../../gallery/format";
import { PiRichRow } from "./PiRichRow";

const item = (status: string, output?: string) => ({
  kind: "tool",
  text: "paint_chart",
  tool: {
    id: `pi-rich-${status}`,
    title: "paint_chart",
    kind: "other",
    status,
    piRich: true as const,
    inputSummary: JSON.stringify({ series: [1, 3, 2], theme: "night" }),
    ...(output ? { output } : {}),
  },
});

function Gallery({ status, output }: { status: string; output?: string }) {
  return (
    <main style={{ padding: 18, width: 520 }}>
      <PiRichRow item={item(status, output)} />
    </main>
  );
}

export default componentEntry({
  id: "agent-pane.pi-rich-row",
  title: "Pi custom tool rich row",
  area: "Agent pane",
  pane: true,
  load: async () => Gallery,
  styles: () => import("./conversation.css"),
  variants: {
    pending: { props: { status: "in_progress" }, note: "Structured call input stays visible while the tool runs." },
    completed: {
      props: { status: "completed", output: JSON.stringify({ summary: "Chart painted", points: 3 }) },
      note: "The generic row keeps the custom tool result beside its call payload.",
    },
    text: {
      props: { status: "completed", output: "A renderer can return plain text too." },
      note: "Plain text results remain readable without a renderer-specific component.",
    },
  },
});
