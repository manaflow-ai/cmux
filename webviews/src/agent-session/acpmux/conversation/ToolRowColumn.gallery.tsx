// l10n-allow-file: gallery fixture titles, commands and output, not shipped copy.
// Codex-style tool rows (Leo 2026-10-29: "fade is nice ish too on these tool calls... having stuff
// aligned is nice"): one turn's tool rows with their verbs in one column, and an opened MCP call
// whose response scrolls at a fixed height, its bottom edge fading while more lies under it.
// Versions: before (no column, a hard bottom edge), the shipped one (the column as wide as the
// turn's widest verb, a 28px fade as a cut preview's), a fixed-width column, and a taller fade.
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import { useEffect, type ReactNode } from "react";
import { CommandRow } from "./CommandRow";
import { McpCallDetails, McpCallRows } from "./McpCallRows";
import { ToolGroupRow } from "./ToolGroupRow";
import { ToolRow } from "./ToolRow";
import { ToolRun } from "./ToolRun";
import { ToolVerbColumn } from "./ToolVerb";
import { TranscriptDisclosureProvider, resetTranscriptDisclosure } from "./transcriptDisclosure";

type Look = "before" | "column" | "fixed" | "tall-fade";
type Props = { look: Look; mode: "light" | "dark" };

const response = JSON.stringify(
  {
    messages: Array.from({ length: 14 }, (_, n) => ({
      from: n % 2 ? "reviewer" : "lane",
      text: n % 2 ? "Looks right; one nit on the fold." : `Pushed step ${n + 1} of the tool-row column.`,
    })),
  },
  null,
  2,
);

const rows = {
  run: [tool("Read App.tsx", "read", "completed"), tool("Read conversation.css", "read", "completed")],
  status: tool("git status", "execute", "completed", { command: "git status", output: "On branch msg-fold\n" }),
  read: tool("Read ToolRow.tsx", "read", "completed"),
  search: tool("Searched for cv-tool__text", "search", "completed"),
  edit: tool("Edited conversation.css", "delete", "completed"),
  commands: [
    tool("bun test transcript", "execute", "completed", { command: "bun test transcript" }),
    tool("bunx vp lint", "execute", "completed", { command: "bunx vp lint" }),
  ],
  mcp: tool("mcp__hub__read_chat", "other", "completed", {
    inputSummary: JSON.stringify({ chat: "msg-fold" }),
    output: response,
  }),
};

function Column({ look, children }: { look: Look; children: ReactNode }) {
  return look === "before" ? (
    <div className="cv-tools">{children}</div>
  ) : (
    <ToolVerbColumn className="cv-tools">{children}</ToolVerbColumn>
  );
}

function ToolRowColumnGallery({ look, mode }: Props) {
  useEffect(() => resetTranscriptDisclosure("gallery-tool-row-column"), []);
  return (
    <TranscriptDisclosureProvider sessionId="gallery-tool-row-column">
      <main
        className="tool-row-column-gallery acpmux-conversation"
        data-mode={mode}
        data-look={look}
        data-tool-row-column
      >
        <Column look={look}>
          <ToolRun items={rows.run} disclosureKey="gallery:run">
            {null}
          </ToolRun>
          <ToolRow item={rows.status} />
          <ToolRow item={rows.read} />
          <ToolRow item={rows.search} />
          <ToolRow item={rows.edit} />
          <ToolGroupRow kind="commands" items={rows.commands} disclosureKey="gallery:commands" folded />
          <CommandRow item={rows.commands[0]!} />
          <McpCallRows items={[rows.mcp]} disclosureKey="gallery:mcp" />
          {/* The call's opened details, drawn at once (no fold to wait on), so the still shows the
              response box's bottom edge. */}
          <McpCallDetails
            id="gallery-mcp"
            call={{ server: "hub", tool: "read_chat", args: { chat: "msg-fold" } }}
            raw="mcp__hub__read_chat"
            output={response}
            strip={false}
            reveal={0}
          />
        </Column>
      </main>
    </TranscriptDisclosureProvider>
  );
}

const variant = (look: Look, mode: Props["mode"], note: string): ComponentVariant<Props> => ({
  note: `${note} ${mode === "dark" ? "Dark" : "Light"} theme.`,
  props: { look, mode },
});

export default componentEntry<Props>({
  id: "agent-pane.tool-row-column",
  title: "Tool rows: verb column and output fade",
  area: "Agent pane",
  pane: true,
  height: 700,
  widths: { narrow: 420, normal: 640, wide: 900 },
  anchors: [{ selector: "[data-tool-row-column] .cv-tools > :first-child" }],
  covers: ["agent-session/acpmux/conversation/ToolVerb.tsx", "agent-session/acpmux/conversation/McpCallRows.tsx"],
  styles: () => import("./ToolRowColumn.gallery.css"),
  load: async () => ToolRowColumnGallery,
  keywords: ["align", "aligned", "fade", "codex", "ran", "verb"],
  variants: {
    before: variant("before", "light", "Before: each subject starts after its own verb; the response cuts hard."),
    column: variant("column", "light", "Shipped: verbs in a column as wide as the widest; 28px bottom fade."),
    "column-dark": variant("column", "dark", "Shipped: verbs in a column as wide as the widest; 28px bottom fade."),
    fixed: variant("fixed", "light", "A fixed 4.6em verb column; 28px bottom fade."),
    "tall-fade": variant("tall-fade", "light", "Widest-verb column; a 48px bottom fade."),
  },
});
