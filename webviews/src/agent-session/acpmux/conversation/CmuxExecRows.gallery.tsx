// l10n-allow-file: gallery fixture scripts, tool names and workspace titles, not shipped copy.
// cmux_exec rows (Leo, 2026-10-30: "these should be rendered better than just cmux called cmux exec
// we know what these are supposed to be"): three scripts in a row (a workspace list, twelve agent
// sessions opened into "Leads", a docs search), the second opened. Before: each row read "Called
// cmux · cmux exec" and opened to the raw `mcp__cmux__cmux_exec` line and escaped JSON. After: each
// says what it did and opens to the script as JavaScript, its calls and its result as a tree, the
// raw call behind Raw. Synthetic data only.
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import { useEffect, useId, useMemo } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { ChevronRight, ToolGroup } from "./icons";
import { CmuxExecDetails, McpCallDetails, McpCallRows } from "./McpCallRows";
import { mcpCall, mcpLabel, mcpRawName } from "./mcpCalls";
import { ToolLabel, ToolVerbColumn } from "./ToolVerb";
import { TranscriptDisclosureProvider, resetTranscriptDisclosure } from "./transcriptDisclosure";

type Look = "before" | "after" | "running";
type Props = { look: Look; mode: "light" | "dark" };

const SESSIONS = Array.from({ length: 12 }, (_, n) => `lead-${String(n + 1).padStart(2, "0")}`);
const answer = (value: unknown) =>
  JSON.stringify({
    content: [{ type: "text", text: JSON.stringify(value) }],
    structuredContent: value,
    isError: false,
  });

const SCRIPTS = {
  list: 'const d = await cmux.call("workspace_list", {});\nreturn d.items.map((w) => ({ id: w.id, title: w.title }));',
  open: [
    "const { items } = await cmux.workspace_list({});",
    'const leads = items.find((w) => w.title === "Leads");',
    `const sessions = ${JSON.stringify(SESSIONS.slice(0, 3))}.concat(/* … */);`,
    "for (const session of sessions) {",
    '  await cmux.call("app_agent_open_tab", { session, workspace: leads.id });',
    "}",
    "return { workspace: leads.title, opened: sessions.length };",
  ].join("\n"),
  docs: 'const found = await cmux.docs("browser tab");\nconsole.log(`${found.tools.length} tools`);\nreturn found;',
};

const exec = (script: string, output: string | undefined, status = "completed") =>
  tool("mcp__cmux__cmux_exec", "other", status, {
    inputSummary: JSON.stringify({ script }),
    ...(output !== undefined && { output }),
  });

const rows = (running: boolean): AcpmuxActivity[] => [
  exec(
    SCRIPTS.list,
    answer({
      calls: 1,
      call_log: [{ name: "workspace_list", ok: true }],
      logs: [],
      result: [
        { id: "ws_4f2a", title: "Leads" },
        { id: "ws_9c1e", title: "Inbox" },
      ],
    }),
  ),
  running
    ? exec(SCRIPTS.open, undefined, "in_progress")
    : exec(
        SCRIPTS.open,
        answer({
          calls: 13,
          call_log: [
            { name: "workspace_list", ok: true },
            ...SESSIONS.map(() => ({ name: "app_agent_open_tab", ok: true })),
          ],
          logs: [],
          result: { workspace: "Leads", opened: 12 },
        }),
      ),
  exec(
    SCRIPTS.docs,
    answer({
      calls: 0,
      call_log: [],
      logs: ["2 tools"],
      result: {
        query: "browser tab",
        tools: [
          { name: "tab_create_browser", description: "Opens a browser tab.\nTakes url and an optional pane." },
          { name: "workspace_open_url", description: "Opens a URL in the workspace's browser." },
        ],
      },
    }),
  ),
];

/// The row as it drew before: "Called cmux · cmux exec" over the raw call (McpCallRows at its base).
function BeforeRow({ item, open }: { item: AcpmuxActivity; open: boolean }) {
  const t = useT();
  const id = useId();
  const call = useMemo(() => mcpCall(item.tool!)!, [item]);
  return (
    <>
      <button type="button" className="cv-tool is-toggle is-strong" aria-expanded={open}>
        <span className="cv-tool__icon">
          <ToolGroup size={16} strokeWidth={1.2} />
        </span>
        <span className="cv-tool__text">
          <ToolLabel text={mcpLabel(t, [call], new Map())} />
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {open && (
        <McpCallDetails
          id={id}
          call={call}
          raw={mcpRawName(item.tool!, call)}
          output={item.tool!.output}
          strip={false}
          reveal={0}
        />
      )}
    </>
  );
}

/// The rows as they draw now, the second opened (drawn at once, with no fold to wait on).
function AfterRows({ items }: { items: AcpmuxActivity[] }) {
  const second = items[1]!;
  const call = useMemo(() => mcpCall(second.tool!)!, [second]);
  return (
    <>
      <McpCallRows items={[items[0]!]} disclosureKey="gallery:cmux-exec:0" />
      <McpCallRows items={[second]} disclosureKey="gallery:cmux-exec:1" />
      <CmuxExecDetails
        id="gallery-cmux-exec"
        tool={second.tool!}
        call={call}
        raw={mcpRawName(second.tool!, call)}
        reveal={0}
      />
      <McpCallRows items={[items[2]!]} disclosureKey="gallery:cmux-exec:2" />
    </>
  );
}

function CmuxExecRowsGallery({ look, mode }: Props) {
  useEffect(() => resetTranscriptDisclosure("gallery-cmux-exec"), []);
  const items = useMemo(() => rows(look === "running"), [look]);
  return (
    <TranscriptDisclosureProvider sessionId="gallery-cmux-exec">
      <main
        className="tool-row-column-gallery acpmux-conversation"
        data-mode={mode}
        data-look={look}
        data-cmux-exec-rows
      >
        <ToolVerbColumn className="cv-tools">
          {look === "before" ? (
            items.map((item, index) => <BeforeRow key={item.tool!.id} item={item} open={index === 1} />)
          ) : (
            <AfterRows items={items} />
          )}
        </ToolVerbColumn>
      </main>
    </TranscriptDisclosureProvider>
  );
}

const variant = (look: Look, mode: Props["mode"], note: string): ComponentVariant<Props> => ({
  note: `${note} ${mode === "dark" ? "Dark" : "Light"} theme.`,
  props: { look, mode },
});

export default componentEntry<Props>({
  id: "agent-pane.cmux-exec-rows",
  title: "cmux script rows",
  area: "Agent pane",
  pane: true,
  height: 820,
  widths: { narrow: 420, normal: 640, wide: 900 },
  anchors: [{ selector: "[data-cmux-exec-rows] .cv-tools > :first-child" }],
  covers: ["agent-session/acpmux/conversation/McpCallRows.tsx#CmuxExecDetails"],
  styles: () => import("./ToolRowColumn.gallery.css"),
  load: async () => CmuxExecRowsGallery,
  keywords: ["cmux_exec", "cmux exec", "mcp", "script", "code mode"],
  variants: {
    before: variant("before", "light", 'Before: every script reads "Called cmux · cmux exec" over escaped JSON.'),
    "before-dark": variant("before", "dark", 'Before: every script reads "Called cmux · cmux exec" over escaped JSON.'),
    after: variant("after", "light", "Each script says what it did; opened, JavaScript, calls and a result tree."),
    "after-dark": variant(
      "after",
      "dark",
      "Each script says what it did; opened, JavaScript, calls and a result tree.",
    ),
    running: variant("running", "light", "The second script still running: its title from the calls in its source."),
  },
});
