// l10n-allow-file: deterministic geometry fixture for transcript row columns.
import { componentEntry } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import { TranscriptDisclosureProvider, resetTranscriptDisclosure } from "./transcriptDisclosure";
import { ToolGroupRow } from "./ToolGroupRow";
import { ToolRun } from "./ToolRun";
import { ThoughtRow } from "./ThoughtRow";
import { CommandRow } from "./CommandRow";
import { SessionStartNote } from "./SessionStartNote";
import type { AcpmuxActivity } from "../model";
import { useEffect, type ReactNode } from "react";

const commandItems: AcpmuxActivity[] = [
  tool("Run the focused tests", "execute", "completed", {
    id: "chevron-command-a",
    command: "bun test webviews",
    description: "Run the focused tests",
    output: "12 pass, 0 fail",
    startedAt: 1000,
    endedAt: 3500,
  }),
  tool("Inspect the worktree", "execute", "completed", {
    id: "chevron-command-b",
    command: "git status",
    description: "Inspect the worktree",
    output: "clean",
    startedAt: 1000,
    endedAt: 4200,
  }),
];

function Row({ children, label }: { children: ReactNode; label: string }) {
  return (
    <section className="acpmux-row chevron-column-gallery__row" data-label={label}>
      <div className="cv-tools">{children}</div>
    </section>
  );
}

function ChevronColumnGallery() {
  useEffect(() => resetTranscriptDisclosure("gallery-chevron-column"), []);
  return (
    <TranscriptDisclosureProvider sessionId="gallery-chevron-column">
      <main className="chevron-column-gallery" data-chevron-column>
        <Row label="start">
          <SessionStartNote
            start={{
              agent: "claude",
              version: "2.1.303",
              model: "claude-opus-5-5",
              harness: "claude",
              cwd: "/Users/you/src/sample",
            }}
          />
        </Row>
        <Row label="run">
          <ToolRun items={commandItems} disclosureKey="run">
            {commandItems.map((item, index) => (
              <CommandRow key={index} item={item} />
            ))}
          </ToolRun>
        </Row>
        <Row label="command">
          <CommandRow item={{ ...commandItems[0]!, tool: { ...commandItems[0]!.tool!, id: "chevron-lone-command" } }} />
        </Row>
        <Row label="group">
          <ToolGroupRow kind="commands" items={commandItems} disclosureKey="group" folded />
        </Row>
        <Row label="thought">
          <ThoughtRow
            item={{
              kind: "thought",
              text: "Thinking through the fixed column while checking that the trailing action slot never moves the disclosure control.",
            }}
            id="thought"
          />
        </Row>
      </main>
    </TranscriptDisclosureProvider>
  );
}

export default componentEntry<Record<string, never>>({
  id: "agent-pane.transcript-chevron-column",
  title: "Transcript chevron column",
  area: "Agent pane",
  pane: true,
  experimental: true,
  height: 640,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  anchors: [{ selector: "[data-chevron-column]" }],
  covers: ["agent-session/acpmux/conversation/conversation.css"],
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./ChevronColumn.gallery.css")]),
  load: async () => ChevronColumnGallery,
  variants: {
    shipped: {
      props: {},
      note: "Real summary, command, group and thought controls share one trailing chevron column. Check/time are before it; Copy remains inside the opened Shell block.",
    },
  },
});
