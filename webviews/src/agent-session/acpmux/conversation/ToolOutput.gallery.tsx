// l10n-allow-file: public-safe sample tool results, never a capture or transcript from a real chat.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";

/// `mcp`: the same result as an opened MCP call's response (McpCallRows.tsx), which reads in the
/// same body as every other tool output.
type Props = { output: string; kind?: string; title?: string; mcp?: boolean };
const summary = [
  "## Network map: summary",
  "",
  "**What it is:** A sample service map used to document a demo project.",
  "",
  "### How the pieces connect",
  "- **Reader:** receives the page and keeps the original source.",
  "- **Viewer:** shows headings, lists, and emphasis in a readable layout.",
  "",
  ...Array.from(
    { length: 18 },
    (_, n) => `### Section ${n + 1}\n\nThe reader can inspect every line in section ${n + 1}.`,
  ),
  "",
  "**End of the complete result.**",
].join("\n");
const props: Props = { kind: "fetch", title: "Fetch https://example.test/network-map", output: summary };
const open: Play = async (ctx) => {
  await ctx.click({ selector: "button.cv-tool" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-tool-output-card"));
};
const expand: Play = async (ctx) => {
  await open(ctx);
  await ctx.click({ selector: ".cv-output-more" });
};

export default componentEntry<Props>({
  id: "agent-pane.tool-output-full-read",
  title: "Tool output, full result",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/conversation/ToolRow.tsx#ToolRow",
    "agent-session/acpmux/conversation/McpCallRows.tsx#McpCallDetails",
  ],
  load: async () => {
    const [{ ToolRow }, { McpCallDetails }] = await Promise.all([import("./ToolRow"), import("./McpCallRows")]);
    return function GalleryToolOutput({ output, kind = "other", title = "Tool result", mcp }: Props) {
      if (mcp)
        return (
          <div style={{ padding: 16 }}>
            <McpCallDetails
              id="gallery-mcp-output"
              call={{ server: "docs", tool: "web_read", args: { url: "https://example.test/network-map" } }}
              raw="mcp__docs__web_read"
              output={JSON.stringify({ content: [{ type: "text", text: output }] })}
              strip={false}
              reveal={0}
            />
          </div>
        );
      return (
        <div style={{ padding: 16 }}>
          <ToolRow
            item={{
              kind: "tool",
              text: title,
              tool: { id: "gallery-full-output", title, kind, output, status: "completed" },
            }}
          />
        </div>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css"), import("../chips/chips.css")]),
  widths: { narrow: 420, normal: 720, wide: 960 },
  height: 760,
  variants: {
    collapsed: { props, note: "The tool row at rest. Public-safe sample data." },
    compact: { props, play: open, note: "Rendered Markdown in the compact viewport, with scroll and Show all." },
    expanded: { props, play: expand, note: "All source lines are available in the larger scrollable viewport." },
    raw: {
      props,
      play: async (ctx) => {
        await expand(ctx);
        await ctx.click({ selector: ".cv-tool-output__raw" });
      },
      note: "The same complete result as monospace source.",
    },
    "mcp-markdown": {
      props: { ...props, mcp: true },
      note: "An opened MCP call whose response is Markdown: the same rendered, scrollable body with Show all and Raw.",
    },
    json: {
      props: { output: JSON.stringify({ ok: true, nodes: ["reader", "viewer"], count: 2 }), kind: "fetch" },
      play: open,
    },
    log: {
      props: { kind: "fetch", output: Array.from({ length: 60 }, (_, n) => `[INFO] row ${n}: processed`).join("\n") },
      play: open,
    },
    "wrapped-line": {
      props: { output: "Long result: ".repeat(180) },
      play: open,
      note: "One source line wraps beyond the viewport; it still offers Show all 1 line.",
    },
  },
});
