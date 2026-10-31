// l10n-allow-file: deterministic transcript reading samples.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import { toolFiles } from "../diff";
import { ShellRow } from "../shell/ShellRow";
import { PlainCode } from "./StreamingCode";
import { ShellBlock } from "./ShellBlock";
import { EditDiff } from "./EditDiff";
import { Markdown } from "./Markdown";
import { DiagramBlock } from "./DiagramBlock";
import { RenderCard } from "./RenderCard";
import { ImageViewer } from "./ImageViewer";
import { TurnFooter } from "./TurnRows";
import { TurnActionsContext } from "./turnActions";
import { ToolRow } from "./ToolRow";
import { CommandRow } from "./CommandRow";

const output = Array.from({ length: 14 }, (_, index) => `step ${index + 1}: completed`).join("\n");
const file = toolFiles([
  tool("Update retry", "edit", "completed", {
    diffs: [
      {
        path: "src/long-retry-policy-name.ts",
        oldText: Array.from({ length: 14 }, (_, index) => `retry(${index + 1});`).join("\n"),
        newText: Array.from({ length: 14 }, (_, index) => `retry(${index + 3});`).join("\n"),
      },
    ],
  }).tool!,
])[0]!;
const image = {
  src: `data:image/svg+xml,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="240" height="120"><rect width="240" height="120" fill="gray"/></svg>')}`,
  alt: "Retry report with a deliberately long image title",
};

function TranscriptType() {
  const [viewer, setViewer] = useState(false);
  return (
    <main className="acpmux-scroll" style={{ padding: 18, overflow: "auto", height: "100%", boxSizing: "border-box" }}>
      <PlainCode lang="typescript" code={"export const retry = 3;\n\nretry();"} open />
      <EditDiff file={file} />
      <ShellBlock command="cd ~/src/atlas && bun test" output={output} exitCode={2} />
      <div data-type="tool-output">
        <ToolRow item={tool("Fetch retry log", "fetch", "completed", { output })} />
      </div>
      <CommandRow item={tool("Run retry tests", "execute", "completed", { command: "bun test", exitCode: 2 })} />
      <ShellRow
        row={{
          id: "type-shell",
          kind: "userShell",
          at: 1000,
          version: 1,
          shell: {
            id: "type-shell",
            command: "bun test src/net/retry.test.ts",
            cwd: "/src/atlas",
            startedAt: 1000,
            status: "running",
            output,
            truncated: false,
            version: 1,
          },
        }}
        expanded={false}
        onToggleActivity={() => {}}
      />
      <Markdown>
        {
          "The retry report has a note.[^report]\n\n[^report]: The timeout is retried three times, then returned to the caller."
        }
      </Markdown>
      <TurnActionsContext.Provider
        value={{
          switchModel: () => {},
          reauthenticate: () => {},
          transferCloudCredentials: async () => {},
          route: { name: "Claude Code", hostKind: "cloud" },
        }}
      >
        <TurnFooter
          row={{
            id: "type-auth",
            kind: "turnSummary",
            version: 1,
            at: 1000,
            status: "failed",
            error: "401 unauthorized",
            prompt: "Run retry tests",
            retryRowId: "type-auth-prompt",
          }}
        />
      </TurnActionsContext.Provider>
      <RenderCard call={{ html: "<p>Retry report</p>", title: "Retry report with a deliberately long title" }} />
      <DiagramBlock lang="vega-lite" code="{ invalid chart" />
      <button type="button" onClick={() => setViewer(true)}>
        Open image
      </button>
      {viewer && <ImageViewer images={[image, image]} index={0} onIndex={() => {}} onClose={() => setViewer(false)} />}
    </main>
  );
}

export default componentEntry({
  id: "agent-pane.transcript-type",
  title: "Transcript reading size",
  area: "Agent pane",
  pane: true,
  height: 1100,
  widths: { narrow: 390, normal: 760 },
  covers: [
    "agent-session/acpmux/conversation/StreamingCode.tsx#PlainCode",
    "agent-session/acpmux/conversation/EditDiff.tsx",
    "agent-session/acpmux/conversation/ShellBlock.tsx",
    "agent-session/acpmux/shell/ShellRow.tsx",
    "agent-session/acpmux/conversation/Markdown.tsx",
    "agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter",
    "agent-session/acpmux/conversation/RenderCard.tsx",
    "agent-session/acpmux/conversation/DiagramBlock.tsx",
    "agent-session/acpmux/conversation/ImageViewer.tsx",
    "agent-session/acpmux/conversation/ToolRow.tsx",
    "agent-session/acpmux/conversation/CommandRow.tsx",
  ],
  load: async () => TranscriptType,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    reading: {
      props: {},
      note: "Real transcript headers, code, output, footnotes, actions, diagrams and media.",
      play: async (ctx) => {
        await ctx.click({ selector: '[data-type="tool-output"] .cv-tool' });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-tool-output"));
      },
    },
  },
});
