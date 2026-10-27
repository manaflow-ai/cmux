// l10n-allow-file: public-safe gallery fixture labels, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxRow } from "../model";
import { PromptActions, ReceivedActions, SentActions } from "./MessageActions";
import { TurnFooter } from "./TurnRows";
import { TurnActionsContext } from "./turnActions";

const prompt: AcpmuxRow = {
  id: "action-prompt",
  kind: "user",
  version: 1,
  at: 1_793_145_600_000,
  text: "Check the message layout.",
};

export function MessageActionExamples({ narrow = false }: { narrow?: boolean }) {
  const [result, setResult] = useState("");
  return (
    <TurnActionsContext.Provider
      value={{
        retry: (id) => setResult(`Retried ${id}`),
        fork: () => setResult("Forked"),
        forkAny: true,
        retryWith: {
          current: "model-a",
          models: [
            { id: "model-a", name: "Model A" },
            { id: "model-b", name: "Model B" },
          ],
          retry: (id, _text, model) => setResult(`Retried ${id} with ${model}`),
        },
      }}
    >
      <div className="action-examples" style={{ padding: 24, maxWidth: narrow ? 320 : 600 }}>
        <style>{`.action-examples > section { position: relative; margin-block-end: 24px; }
          .action-examples :is(.cv-user__actions,.cv-received-actions,.cv-sent-actions,.cv-turn-actions) { opacity: 1; }
          .action-examples h3 { font: inherit; margin: 0 0 4px; color: var(--cv-text-muted); }`}</style>
        <section data-message-kind="user">
          <h3>User prompt</h3>
          <PromptActions row={prompt} text={prompt.text!} />
        </section>
        <section data-message-kind="assistant">
          <h3>Assistant reply</h3>
          <TurnFooter
            row={{
              ...prompt,
              id: "answer",
              kind: "turn_summary",
              seq: 4,
              status: "completed",
              text: "The layout is ready.",
            }}
          />
        </section>
        <section className="acpmux-row" data-retryable data-message-kind="received">
          <h3>Received agent message</h3>
          <ReceivedActions row={{ ...prompt, id: "received" }} text="Review complete." />
        </section>
        <section data-message-kind="sent">
          <h3>Sent agent message</h3>
          <SentActions text="Please review the layout." />
        </section>
        <output aria-live="polite">{result}</output>
      </div>
    </TurnActionsContext.Provider>
  );
}

export default componentEntry({
  id: "agent-pane.message-action-row",
  title: "Message action rows",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/conversation/MessageActionRow.tsx#MessageActionRow",
    "agent-session/acpmux/conversation/MessageActionRow.tsx#MessageActionIcon",
    "agent-session/acpmux/conversation/MessageActions.tsx#PromptActions",
    "agent-session/acpmux/conversation/MessageActions.tsx#ReceivedActions",
    "agent-session/acpmux/conversation/MessageActions.tsx#SentActions",
  ],
  load: async () => MessageActionExamples,
  height: 400,
  variants: {
    compact: { note: "Same quiet, compact controls for user, assistant, received and sent messages.", props: {} },
    narrow: {
      note: "The same controls in a narrow transcript, without compressed or overlapping buttons.",
      props: { narrow: true },
    },
  },
});
