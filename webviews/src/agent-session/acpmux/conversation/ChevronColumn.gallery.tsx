// l10n-allow-file: deterministic geometry fixture for transcript row columns.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { tool } from "../../../gallery/fixtures/acpmux";
import { TranscriptDisclosureProvider, resetTranscriptDisclosure } from "./transcriptDisclosure";
import { ToolGroupRow } from "./ToolGroupRow";
import { ToolRun } from "./ToolRun";
import { ThoughtRow } from "./ThoughtRow";
import { CommandRow } from "./CommandRow";
import { SessionStartNote } from "./SessionStartNote";
import type { AcpmuxActivity } from "../model";
import { useEffect, useState, type ReactNode } from "react";
import { AgentMessageRow } from "./AgentMessageRow";
import { TerminalSquare } from "./icons";

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
  const [messageOpen, setMessageOpen] = useState(false);
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
          <CommandRow
            item={{
              ...commandItems[0]!,
              tool: { ...commandItems[0]!.tool!, id: "chevron-lone-command" },
            }}
          />
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
        <Row label="agent-message">
          <AgentMessageRow
            direction="received"
            icon={<TerminalSquare />}
            sentence={"Received from \u0000"}
            name="claude-code"
            preview="Finished 4 background tasks, ran 5 commands (2 failed)"
            label="Expand agent message"
            open={messageOpen}
            onToggle={() => setMessageOpen((open) => !open)}
            body="Full agent message"
          />
        </Row>
      </main>
    </TranscriptDisclosureProvider>
  );
}

const checkInlineCaret: Play = async (ctx) => {
  const rows = [...ctx.document.querySelectorAll<HTMLElement>("[data-chevron-column] .chevron-column-gallery__row")];
  await ctx.waitFor(() =>
    rows.every((row) => row.querySelector(".cv-tool__chevron, .cv-agentmsg__toggle .cv-tool__chevron")),
  );
  for (const row of rows) {
    const caret = row.querySelector<HTMLElement>(".cv-tool__chevron");
    if (!caret) throw new Error(`Missing disclosure caret in ${row.dataset.label}`);
    const label = row.querySelector<HTMLElement>(
      ".cv-tool__text, .cv-command__text, .cv-thought__label, .cv-agentmsg__preview",
    );
    if (!label) throw new Error(`Missing disclosure label in ${row.dataset.label}`);
    const button = caret.closest<HTMLElement>("button");
    const token = Number.parseFloat(
      ctx.document.defaultView?.getComputedStyle(button ?? caret).getPropertyValue("--cv-disclosure-gap") ?? "",
    );
    if (!Number.isFinite(token)) throw new Error(`Missing disclosure gap token in ${row.dataset.label}`);
    const gap = caret.getBoundingClientRect().left - label.getBoundingClientRect().right;
    if (gap < -0.5 || gap > token + 0.5)
      throw new Error(`${row.dataset.label} caret gap ${gap}px; expected <= ${token}px`);
    const meta = row.querySelector<HTMLElement>(".cv-command__meta, .cv-tool__meta");
    if (meta) {
      const buttonBox = (button ?? row).getBoundingClientRect();
      const caretBox = caret.getBoundingClientRect();
      const metaBox = meta.getBoundingClientRect();
      if (metaBox.left < caretBox.right - 0.5) throw new Error(`${row.dataset.label} status overlaps its caret`);
      if (metaBox.right < buttonBox.right - 1) throw new Error(`${row.dataset.label} status is not trailing`);
    }
  }
};

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
    light: {
      props: {},
      note: "Light: every collapsible transcript row keeps its disclosure caret inline after the label.",
      play: checkInlineCaret,
    },
    dark: {
      props: {},
      note: "Dark: every collapsible transcript row keeps its disclosure caret inline after the label.",
      play: checkInlineCaret,
    },
  },
});
