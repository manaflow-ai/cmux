// l10n-allow-file: synthetic geometry fixtures, never user data.
import { componentEntry } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import { AgentMessageRow } from "./AgentMessageRow";
import { AgentCard } from "../subagents/AgentCard";
import { DisclosureRow } from "../subagents/DisclosureRow";
import { ToolVerbColumn } from "./ToolVerb";
import { ToolGroupRow } from "./ToolGroupRow";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";
import { OpenBook } from "./icons";
import "./SubsessionCallCard.css";

function TranscriptGridCards() {
  return (
    <TranscriptDisclosureProvider sessionId="grid-cards">
      <main className="transcript-grid-cards">
        <ToolVerbColumn className="cv-tools">
          {[2, 12].map((count) => (
            <section key={count} data-grid-count={count}>
              <ToolGroupRow
                kind="commands"
                folded
                disclosureKey={`grid-count-${count}`}
                items={Array.from({ length: count }, (_, i) =>
                  tool(`Check ${i}`, "execute", "completed", { command: `check ${i}` }),
                )}
              />
            </section>
          ))}
          <AgentMessageRow
            direction="sent"
            icon={<OpenBook />}
            sentence={"Sent to \u0000"}
            name="reviewer"
            preview="A long report that truncates before the trailing disclosure mark even in narrow panes"
            label="Open report"
            open
            onToggle={() => {}}
            body="The full report uses the shared text column."
            under={<div className="cv-agentmsg__under">Delivered</div>}
          />
          <DisclosureRow icon={<OpenBook />} label="Started sub-session" defaultOpen>
            <div className="cv-subsession__under">One nested body uses the shared text column.</div>
          </DisclosureRow>
          <AgentCard name="Review" state="working" doing="Checking transcript geometry" />
        </ToolVerbColumn>
      </main>
    </TranscriptDisclosureProvider>
  );
}

export default componentEntry({
  id: "agent-pane.transcript-grid-cards",
  title: "Transcript grid cards",
  area: "Agent pane",
  covers: ["agent-session/acpmux/conversation/AgentMessageRow.tsx", "agent-session/acpmux/subagents/AgentCard.tsx"],
  pane: true,
  height: 700,
  widths: { narrow: 480, normal: 1000, wide: 1200 },
  styles: () => import("./TranscriptGridCards.gallery.css"),
  load: async () => TranscriptGridCards,
  variants: {
    grid: { props: {}, note: "Opened message, nested sub-session and live agent card with changing command counts." },
  },
});
