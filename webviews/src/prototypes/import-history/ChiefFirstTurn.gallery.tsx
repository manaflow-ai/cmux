// l10n-allow-file: isolated gallery prototype, not shipped UI.
// Placement (a): the Chief's first turn carries the offer as an inline card under its greeting, so
// the import is where the person already is (findings G4 and G13: one first turn from the Chief, not
// a wizard in front of the chat). The card is the real Settings › Import card (ui/ImportCards.tsx);
// Bring It In shows the running state, Not Now folds it away.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { ImportCards } from "../../ui/ImportCards";
import { RevealedMarkdown } from "../../agent-session/acpmux/conversation/RevealedMarkdown";
import { HISTORY_CARD, HISTORY_CARD_RUNNING, historyList } from "./fixtures";

type Props = { state: "ready" | "running" };

const GREETING = [
  "Hi, I'm your Chief. Tell me what you want done, in plain words: I start agents for the big jobs, remember what matters and follow up here.",
  "I found your Claude Code and Codex history on this Mac. Bring it in, and I and every agent here know your projects from the first message.",
].join("\n\n");

function ChiefFirstTurn({ state }: Props) {
  const [shown, setShown] = useState<Props["state"] | "dismissed">(state);
  return (
    <div className="acpmux-shell" style={{ padding: 16, display: "grid", gap: 12, alignContent: "start" }}>
      <div className="cv-message">
        <RevealedMarkdown text={GREETING} streaming={false} artifactIdentity="chief-first-turn" />
      </div>
      {shown !== "dismissed" && (
        <ImportCards
          list={historyList(shown === "running" ? HISTORY_CARD_RUNNING : HISTORY_CARD)}
          onAction={(_, action) => setShown(action === "start" ? "running" : "dismissed")}
        />
      )}
    </div>
  );
}

export default componentEntry<Props>({
  id: "prototype.import-history-chief-turn",
  title: "Bring your history: Chief first turn",
  area: "Prototypes",
  experimental: true,
  pane: true,
  covers: ["prototypes/import-history/ChiefFirstTurn.gallery.tsx"],
  keywords: ["import", "history", "memory", "claude code", "codex", "chief", "onboarding"],
  height: 360,
  widths: { narrow: 360, normal: 560, wide: 760 },
  load: async () => ChiefFirstTurn,
  styles: () =>
    Promise.all([
      import("../../agent-session/acpmux/styles.css"),
      import("../../agent-session/acpmux/conversation/conversation.css"),
    ]),
  variants: {
    offer: {
      note: "(a) The Chief's greeting, then one card: both tools, counts, one button.",
      props: { state: "ready" },
    },
    running: {
      note: "After Bring It In: the import runs in the background and the chat stays usable.",
      props: { state: "running" },
    },
  },
});
