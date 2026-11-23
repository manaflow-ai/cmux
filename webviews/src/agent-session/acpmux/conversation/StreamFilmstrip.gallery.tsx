// l10n-allow-file: gallery fixtures (sample replies cut mid-stream), not shipped UI.
// AUDIT (uncommitted): a reply's Markdown at each point it streams through, one frame per cut,
// so a block that flips type, jumps in height or moves sideways shows between two frames. Each
// frame draws `Markdown` with `streaming` (the safe tail, safeTail.ts) at a prefix of the source;
// the last frame is the finished reply. The line under each frame reads the reply's height and,
// when it has one, the table's left edge and width, the code card's and chart's heights.
import { useEffect, useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { Markdown } from "./Markdown";

type Scenario = "table" | "table-bare" | "code" | "diagram" | "chart" | "math" | "list" | "inline";

const CUT = "⁞";

const SOURCES: Record<Scenario, string> = {
  table: [
    "Here are the runs:",
    "",
    `| Check | Base |${CUT}`,
    `| --- |${CUT} --- |`,
    `${CUT}| lint | 41 s |`,
    `${CUT}| bun test |${CUT} 2 m 10 s |`,
    `| the browser lane, which runs separately on its own runner | 3 m 02 s |${CUT}`,
    "",
    `After the table.${CUT}`,
  ].join("\n"),
  "table-bare": [
    "Runs:",
    "",
    `Check | Base${CUT}`,
    `--${CUT}- |${CUT} ---`,
    `${CUT}lint | 41 s`,
    `${CUT}bun test | 2 m 10 s${CUT}`,
  ].join("\n"),
  code: [
    "Run this:",
    "",
    `\`${CUT}\`\`${CUT}ty${CUT}pescript`,
    `${CUT}export const retry = 3;`,
    `${CUT}export const backoffMs = 250;${CUT}`,
    `\`${CUT}\`\`${CUT}`,
    "",
    `Then rebuild.${CUT}`,
    "",
    `\`\`\`${CUT}\`ma${CUT}rkdown`,
    "```md",
    "# inner",
    "```",
    `\`\`\`\`${CUT}`,
  ].join("\n"),
  diagram: [
    "The flow:",
    "",
    "```mermaid",
    `${CUT}graph TD`,
    `  A[Prompt] --> B[Agent]${CUT}`,
    `  B --> C[Tools]${CUT}`,
    `  C --> D[Reply]${CUT}`,
    `\`\`\`${CUT}`,
    "",
    `That is all.${CUT}`,
  ].join("\n"),
  chart: [
    "Times:",
    "",
    "```vega-lite",
    `{"$schema": "https://vega.github.io/schema/vega-lite/v5.json",${CUT}`,
    ` "width": 300, "height": 160,`,
    ` "data": {"values": [{"k": "lint", "s": 41}, {"k": "test", "s": 130}, {"k": "e2e", "s": 182}]},${CUT}`,
    ` "mark": "bar",`,
    ` "encoding": {"x": {"field": "k", "type": "nominal"}, "y": {"field": "s", "type": "quantitative"}}}${CUT}`,
    `\`\`\`${CUT}`,
    "",
    `Done.${CUT}`,
  ].join("\n"),
  math: [
    `The energy is $E${CUT}=mc^2$${CUT} for a body at rest.`,
    "",
    `$$${CUT}`,
    `\\int_0^1 x${CUT}\\,dx = \\tfrac12`,
    `${CUT}$$${CUT}`,
    "",
    `After the equation.${CUT}`,
  ].join("\n"),
  list: [
    "Steps:",
    "",
    `-${CUT} first ${CUT}item`,
    `-${CUT} second item`,
    `${CUT}  -${CUT} nested under the second`,
    "",
    `1${CUT}. ordered${CUT}`,
    `2. next${CUT}`,
    "",
    `##${CUT} A head${CUT}ing`,
    `${CUT}`,
  ].join("\n"),
  inline: `Some **bold${CUT} words** and a [link${CUT}](https://exa${CUT}mple.com) and \`co${CUT}de\` and *ital${CUT}ic* end.${CUT}`,
};

function cuts(source: string): string[] {
  const parts = source.split(CUT);
  const out: string[] = [];
  for (let index = 1; index <= parts.length; index += 1) out.push(parts.slice(0, index).join(""));
  return out;
}

function Frame({ text, streaming, index }: { text: string; streaming: boolean; index: number }) {
  const ref = useRef<HTMLDivElement>(null);
  const [metrics, setMetrics] = useState("");
  useEffect(() => {
    const read = () => {
      const host = ref.current;
      if (!host) return;
      const md = host.querySelector(".cv-md") as HTMLElement | null;
      const base = host.getBoundingClientRect();
      const parts = [`h=${Math.round(md?.getBoundingClientRect().height ?? 0)}`];
      const table = host.querySelector(".cv-table-block");
      if (table) {
        const box = table.getBoundingClientRect();
        parts.push(`table x=${Math.round(box.left - base.left)} w=${Math.round(box.width)}`);
      }
      const code = host.querySelector(".cv-codeblock, .cv-code-handoff");
      if (code) parts.push(`code h=${Math.round(code.getBoundingClientRect().height)}`);
      const diagram = host.querySelector(".cv-diagram");
      if (diagram) parts.push(`chart h=${Math.round(diagram.getBoundingClientRect().height)}`);
      const math = host.querySelector(".cv-math-display, .cv-math--display");
      if (math) parts.push(`math h=${Math.round(math.getBoundingClientRect().height)}`);
      setMetrics(parts.join("  "));
    };
    read();
    const timer = window.setInterval(read, 400);
    return () => window.clearInterval(timer);
  }, [text]);
  const label = JSON.stringify(text.slice(-26));
  return (
    <div className="stream-frame" style={{ width: 520, border: "1px dashed rgb(128 128 128 / 0.5)", padding: 8 }}>
      <div style={{ font: "10px ui-monospace, monospace", opacity: 0.7, marginBottom: 6, whiteSpace: "pre" }}>
        {`#${index} ${streaming ? "streaming" : "FINISHED"} …${label}\n${metrics}`}
      </div>
      <div ref={ref}>
        <Markdown streaming={streaming} className="cv-reply">
          {text}
        </Markdown>
      </div>
    </div>
  );
}

function Strip({ scenario }: { scenario: Scenario }) {
  const frames = cuts(SOURCES[scenario]);
  return (
    <div
      className="acpmux-shell"
      style={{ padding: 12, display: "flex", flexWrap: "wrap", gap: 10, alignItems: "flex-start" }}
    >
      {frames.map((text, index) => (
        <Frame key={index} index={index} text={text} streaming />
      ))}
      <Frame index={frames.length} text={frames.at(-1)!} streaming={false} />
    </div>
  );
}

const variants = Object.fromEntries(
  (Object.keys(SOURCES) as Scenario[]).map((scenario) => [scenario, { props: { scenario } }]),
) as Record<Scenario, { props: { scenario: Scenario } }>;

export default componentEntry<{ scenario: Scenario }>({
  id: "agent-pane.stream-filmstrip",
  title: "AUDIT: a reply at each point it streams through",
  area: "Agent pane",
  pane: true,
  height: 1400,
  widths: { narrow: 1180, normal: 1180, wide: 1180 },
  covers: ["agent-session/acpmux/conversation/safeTail.ts", "agent-session/acpmux/conversation/Markdown.tsx"],
  load: async () => Strip,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants,
});
