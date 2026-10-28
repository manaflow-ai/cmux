// l10n-allow-file: deterministic geometry fixture for transcript row columns.
import { componentEntry } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import { TranscriptDisclosureProvider, resetTranscriptDisclosure } from "./transcriptDisclosure";
import { ToolGroupRow } from "./ToolGroupRow";
import { ToolRun } from "./ToolRun";
import { ThoughtRow } from "./ThoughtRow";
import { CommandRow } from "./CommandRow";
import type { AcpmuxActivity } from "../model";
import { useEffect, type ReactNode } from "react";

const commandItems: AcpmuxActivity[] = [
  tool("Ran 31 commands, used a tool", "execute", "completed", { command: "bun test webviews" }),
  tool("Ran a second command with a long description", "execute", "completed", { command: "git status" }),
];

function CopySlot() {
  return (
    <button type="button" className="acpmux-row__copy cv-iconbtn" aria-label="Copy">
      ▢
    </button>
  );
}

function Row({ children, copy = false, label }: { children: ReactNode; copy?: boolean; label: string }) {
  return (
    <section
      className="acpmux-row chevron-column-gallery__row"
      data-label={label}
      data-floating-copy={copy ? "true" : undefined}
    >
      {copy ? <CopySlot /> : null}
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
          <ToolRun items={commandItems} disclosureKey="start">
            {commandItems.map((item, index) => (
              <CommandRow key={index} item={item} />
            ))}
          </ToolRun>
        </Row>
        <Row label="copy" copy>
          <ToolRun items={commandItems} disclosureKey="copy">
            {commandItems.map((item, index) => (
              <CommandRow key={index} item={item} />
            ))}
          </ToolRun>
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
  height: 300,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  anchors: [{ selector: "[data-chevron-column]" }],
  covers: ["agent-session/acpmux/conversation/conversation.css"],
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./ChevronColumn.gallery.css")]),
  load: async () => ChevronColumnGallery,
  variants: {
    shipped: { props: {}, note: "Hover action slots stay left of a shared trailing chevron column." },
  },
});
