// l10n-allow-file: deterministic, public-safe fixture for the transcript's one row grammar.
// Leo 2026-10-29: "this ui isn't consistent :(" and "this rendering can be better for sent stuff".
// Four row kinds side by side, each drawn by its real component: a SendMessage call
// (MessageCard.tsx), a shell `acpmux send` (SentMessageLine.tsx), "Ran 2 commands"
// (ToolGroupRow.tsx) and "Subagent finished" (SubagentDoneLine.tsx). Every one is the tool rows'
// grid: icon, sentence, then the trailing column (status, then duration), then the chevron.
// The variants compare the recipient's one look: the chip (shipped), a link, plain text.
import { useLayoutEffect, type ReactNode } from "react";
import { componentEntry } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { SubagentDoneLine } from "../subagents/SubagentDoneLine";
import { SubagentNavContext } from "../subagents/SubagentGroup";
import { acpmuxSendCall } from "./acpmuxSends";
import { agentMessage } from "./agentMessages";
import { MessageCard } from "./MessageCard";
import { AcpmuxSendLine } from "./SentMessageLine";
import { ToolGroupRow } from "./ToolGroupRow";
import { TranscriptDisclosureProvider, resetTranscriptDisclosure } from "./transcriptDisclosure";

type Props = { recipient: "chip" | "link" | "plain"; open?: boolean };

const sendMessage = tool("SendMessage", "other", "completed", {
  id: "grammar-send-message",
  inputSummary: JSON.stringify({
    to: "Organize the sidebar",
    message: "The sessions you set up should nest under their parent chat.",
  }),
  output: JSON.stringify({ queued: true }),
});
const shellSend = tool("acpmux send", "execute", "completed", {
  id: "grammar-shell-send",
  command:
    "acpmux send --no-wait fanout-infra 'An addition to the broker blocker: the NOW page reads the queue first.\n\nThen it reads the fleet census.'",
  output: "queued",
});
const commands: AcpmuxActivity[] = [
  tool("git status", "execute", "completed", { id: "grammar-cmd-a", command: "git status", output: "clean" }),
  tool("git log -1", "execute", "completed", { id: "grammar-cmd-b", command: "git log -1", output: "ac3dc3f" }),
];
const subagent: AcpmuxRow = {
  id: "grammar-subagent",
  version: 1,
  at: 148_000,
  kind: "activity",
  settled: true,
  subagents: [
    {
      id: "grammar-sa",
      parent: null,
      name: "Audit agent friction",
      state: "completed",
      startedAt: 0,
      endedAt: 148_000,
    },
  ],
} as AcpmuxRow;

function Row({ children, label }: { children: ReactNode; label: string }) {
  return (
    <section className="acpmux-row row-grammar-gallery__row" data-label={label}>
      <div className="cv-tools">{children}</div>
    </section>
  );
}

function RowGrammarGallery({ recipient, open = false }: Props) {
  // Reset first, as a layout effect, so it runs before the `open` variant's clicks below and
  // never closes what they opened.
  useLayoutEffect(() => resetTranscriptDisclosure("gallery-row-grammar"), []);
  useLayoutEffect(() => {
    const root = document.documentElement;
    if (recipient === "chip") delete root.dataset.recipientStyle;
    else root.dataset.recipientStyle = recipient;
    return () => void delete root.dataset.recipientStyle;
  }, [recipient]);
  useLayoutEffect(() => {
    if (!open) return;
    for (const toggle of document.querySelectorAll<HTMLElement>(
      ".row-grammar-gallery .cv-agentmsg__toggle, .row-grammar-gallery .cv-sent",
    ))
      toggle.click();
  }, [open]);
  const message = agentMessage(sendMessage.tool!)!;
  const send = acpmuxSendCall(shellSend.tool!)!;
  return (
    <TranscriptDisclosureProvider sessionId="gallery-row-grammar">
      <SubagentNavContext.Provider value={() => undefined}>
        <main className="row-grammar-gallery" data-row-grammar>
          <Row label="send-message">
            <MessageCard item={sendMessage} message={message} />
          </Row>
          <Row label="acpmux-send">
            <AcpmuxSendLine tool={shellSend.tool!} send={send} />
          </Row>
          <Row label="commands">
            <ToolGroupRow kind="commands" items={commands} disclosureKey="grammar-group" folded />
          </Row>
          <Row label="subagent">
            <SubagentDoneLine row={subagent} />
          </Row>
        </main>
      </SubagentNavContext.Provider>
    </TranscriptDisclosureProvider>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.transcript-row-grammar",
  title: "Transcript row grammar",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  anchors: [{ selector: "[data-row-grammar]" }],
  covers: [
    "agent-session/acpmux/conversation/AgentMessageRow.tsx",
    "agent-session/acpmux/conversation/SentMessageLine.tsx#AcpmuxSendLine",
    "agent-session/acpmux/subagents/SubagentDoneLine.tsx#SubagentDoneLine",
  ],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../subagents/subagents.css"),
      import("./RowGrammar.gallery.css"),
    ]),
  load: async () => RowGrammarGallery,
  variants: {
    chip: {
      props: { recipient: "chip" },
      note: 'Shipped. Both sends read "Sent to" with the recipient as the one chip, the first line muted and cut with one ellipsis; status ("Queued") and duration ("2m 28s") share the trailing column before the chevron, which sits on one x in all four rows.',
    },
    link: {
      props: { recipient: "link" },
      note: "Compared: the recipient as an underlined link, the old acpmux send look. Reads as navigation even when the recipient opens nothing.",
    },
    plain: {
      props: { recipient: "plain" },
      note: "Compared: the recipient as medium-weight plain text. Quietest, but the name runs into the preview.",
    },
    open: {
      props: { recipient: "chip", open: true },
      note: "Both sends opened: the message shows once, under its row, and the line drops its first line. Raw stays under the shell send's message.",
    },
  },
});
