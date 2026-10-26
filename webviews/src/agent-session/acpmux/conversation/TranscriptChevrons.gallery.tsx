// l10n-allow-file: synthetic gallery transcript, not shipped copy.
import { useLayoutEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { row, thought, tool } from "../../../gallery/fixtures/acpmux";
import { AgentMessageRow } from "./AgentMessageRow";
import { IncomingMessageLine } from "./IncomingMessageCard";
import { ReceivedActions, SentActions } from "./MessageActions";
import { ToolRow } from "./ToolRow";
import { CommandRow } from "./CommandRow";
import { ToolGroupRow } from "./ToolGroupRow";
import { ThoughtRow } from "./ThoughtRow";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";
import { Cut } from "./SubsessionCallCard";
import { ChevronRight, Envelope } from "./icons";
import { SubagentGroupHeader } from "../subagents/SubagentGroup";
import { AgentRunCard } from "../subagents/AgentRunCard";
import { resetChatDisplay, setChatDisplay } from "../chatDisplay";

const text = "The synthetic build receipt is ready. ".repeat(30);
const short = tool("Read notes", "read", "completed", { output: "Synthetic notes" });
const long = tool(
  "Read the complete synthetic transcript verification report with a very long file name",
  "read",
  "failed",
  {
    output: "Synthetic failure",
  },
);
const agent = {
  id: "synthetic-agent",
  parent: null,
  name: "Check layout",
  task: "Check layout",
  kind: "general-purpose",
  state: "completed" as const,
  startedAt: 1,
  endedAt: 1001,
  command: "codex exec 'Check synthetic layout'",
  result: text,
};
const receivedRow = row("user", 0, { id: "synthetic-received" });

function Sent({ preview }: { preview: string }) {
  const [open, setOpen] = useState(false);
  return (
    <AgentMessageRow
      direction="sent"
      icon={<Envelope />}
      sentence={"Sent to \u0000"}
      name="layout-check"
      preview={preview}
      label="Toggle synthetic sent message"
      open={open}
      onToggle={() => setOpen(!open)}
      body={text}
      meta={<span className="cv-command__meta">Delivered</span>}
      actions={<SentActions text={text} />}
    />
  );
}

function TranscriptChevrons({ rtl, minimal }: { rtl: boolean; minimal: boolean }) {
  useLayoutEffect(() => {
    setChatDisplay({ "sidebar.minimal": minimal });
    return resetChatDisplay;
  }, [minimal]);
  const [agentsOpen, setAgentsOpen] = useState(false);
  const [workedOpen, setWorkedOpen] = useState(false);
  return (
    <main dir={rtl ? "rtl" : "ltr"} style={{ padding: "var(--cv-edge)", minWidth: 0 }}>
      <TranscriptDisclosureProvider sessionId="synthetic-chevron-column">
        <div data-chevron-column>
          <section data-case="tool-short" className="cv-tools">
            <ToolRow item={short} />
          </section>
          <section data-case="tool-long-failed" className="cv-tools">
            <ToolRow item={long} />
          </section>
          <section
            data-case="command-copy"
            className="acpmux-row"
            data-floating-copy="true"
            style={{ position: "relative", inset: "auto", padding: 0 }}
          >
            <div className="cv-tools">
              <CommandRow
                item={tool("git status", "execute", "completed", {
                  command: "git status --short",
                  output: "clean",
                  durationMs: 1234,
                })}
              />
            </div>
            <button
              type="button"
              className="acpmux-row__copy cv-iconbtn"
              aria-label="Copy synthetic command"
            >
              C
            </button>
          </section>
          <section data-case="group-closed" className="cv-tools">
            <ToolGroupRow kind="reads" items={[short, long]} disclosureKey="closed" folded />
          </section>
          <section data-case="group-open" className="cv-tools">
            <ToolGroupRow
              kind="reads"
              items={Array.from({ length: 7 }, (_, n) =>
                tool(`Read synthetic note ${n}`, "read", "completed", { output: "Synthetic note" }),
              )}
              disclosureKey="open"
            />
          </section>
          <section data-case="nested" className="cv-tools">
            <div className="cv-tool-group">
              <ToolRow item={short} />
            </div>
          </section>
          <section data-case="thought" className="cv-tools">
            <ThoughtRow id="synthetic-thought" item={thought(text)} />
          </section>
          <section data-case="sent-short">
            <Sent preview="Ready" />
          </section>
          <section data-case="sent-long">
            <Sent preview={text} />
          </section>
          <section data-case="received">
            <IncomingMessageLine
              id="synthetic-received"
              message={{
                name: "layout-check",
                text,
                raw: `Synthetic envelope\n${text}`,
                sessionId: "synthetic-agent",
                msgId: "synthetic-message",
              }}
              onOpen={() => {}}
              onReply={async () => {}}
              actions={<ReceivedActions row={receivedRow} text={text} />}
            />
          </section>
          <section data-case="subagent">
            <SubagentGroupHeader
              row={row("subagents", 0, { subagents: [agent] })}
              expanded={agentsOpen}
              onToggle={() => setAgentsOpen(!agentsOpen)}
            />
          </section>
          <section data-case="subagent-raw">
            <AgentRunCard agent={agent} />
          </section>
          <section data-case="worked">
            <button
              type="button"
              className="cv-worked is-toggle"
              aria-expanded={workedOpen}
              onClick={() => setWorkedOpen(!workedOpen)}
            >
              <span className="cv-worked__label">Worked for 12 seconds</span>
              <ChevronRight
                size={14}
                className={`cv-worked__chevron cv-rotor${workedOpen ? " is-open" : ""}`}
              />
            </button>
          </section>
          <section data-case="text-disclosure">
            <Cut text={text} />
          </section>
        </div>
      </TranscriptDisclosureProvider>
    </main>
  );
}

export default componentEntry<{ rtl: boolean; minimal: boolean }>({
  id: "agent-pane.transcript-chevrons",
  title: "Transcript expansion column",
  area: "Agent pane",
  pane: true,
  height: 1100,
  widths: { narrow: 420, normal: 760, wide: 980 },
  covers: [
    "agent-session/acpmux/conversation/AgentMessageRow.tsx",
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx",
    "agent-session/acpmux/conversation/ThoughtRow.tsx",
    "agent-session/acpmux/conversation/ToolGroupRow.tsx",
  ],
  anchors: [{ selector: "[data-chevron-column]" }],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => TranscriptChevrons,
  variants: {
    ltr: { props: { rtl: false, minimal: false } },
    rtl: { props: { rtl: true, minimal: false } },
    "minimal-ltr": { props: { rtl: false, minimal: true } },
    "minimal-rtl": { props: { rtl: true, minimal: true } },
  },
});
