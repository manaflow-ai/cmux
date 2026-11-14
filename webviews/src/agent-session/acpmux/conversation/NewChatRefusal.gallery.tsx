// l10n-allow-file: gallery fixtures (a prompt and acpmux's refusal words), not shipped UI.
// A send this device may not make: a Claude chat its Mac started, sent to from another account's
// device (acpmux D13, `remote.local_claude_session`, `action: new_chat`). Leo, 2026-11-14, of the
// sentence that refusal used to show ("From another device, start a new chat there. On this Mac
// itself, close and reopen the chat"): "wtf do i do these options dont do anything"; and then:
// "Where a refusal stays (another account), name the one action that works, as a button." The card
// (PromptDelivery.tsx DeliveryFailure) says one sentence and draws New chat; Retry, refused the same
// way again, is gone. The variants try New chat's weight beside Edit, Remove and Details: the
// design system's solid button (shipped), its subtle one, and the text link Trust folder uses.
import { minutesAgo } from "../../../gallery/clock";
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxRow } from "../model";

/// `look`: New chat's weight tried (`solid` ships). `offered`: the pane can start a chat (off: a
/// pane with no chat.new, which keeps the sentence and Edit, Remove and Details).
type Props = { look: "solid" | "subtle" | "link"; offered: boolean };

const refusal =
  "Only the cmux app on this Mac can control a Claude chat started on this Mac. From another device, start a new chat there. On this Mac itself, close and reopen the chat to reconnect.";

const prompt: AcpmuxRow = {
  id: "user-1",
  version: 1,
  at: minutesAgo(1),
  kind: "user",
  text: "hello",
  failed: true,
  delivery: {
    state: "failed",
    promptId: "p1",
    sessionId: "s",
    sentAt: 0,
    failedAt: 220,
    hop: "acpmux",
    code: "-32000",
    reason: "remote.local_claude_session",
    error: refusal,
  },
};

/// The looks New chat was tried in, over the same button: the subtle fill, and the Trust folder link.
const LOOKS: Record<Props["look"], string> = {
  solid: "",
  subtle: `.cv-gallery-new-chat .cv-user__new-chat { background: var(--ds-color-hover); color: var(--ds-color-fg); font-weight: var(--weight-regular); }`,
  link: `.cv-gallery-new-chat .cv-user__new-chat { height: auto; padding: 0; background: none; color: var(--cv-text); font: inherit; font-weight: var(--weight-emphasis); text-decoration: underline; text-underline-offset: 2px; }`,
};

export default componentEntry<Props>({
  id: "agent-pane.new-chat-refusal",
  title: "Refused send: New chat",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: ".cv-user__status--failed" }],
  covers: ["agent-session/acpmux/conversation/PromptDelivery.tsx#DeliveryFailure"],
  keywords: ["refused", "not sent", "remote.local_claude_session", "new chat", "D13"],
  load: async () => {
    const [{ DeliveryFailure }, { FailedSendsContext }, { failedSendText, failedRuns }] = await Promise.all([
      import("./PromptDelivery"),
      import("./promptDeliveryModel"),
      import("../sendFailure"),
    ]);
    return function GalleryNewChatRefusal({ look, offered }: Props) {
      const row = {
        ...prompt,
        error: failedSendText({ reason: "remote.local_claude_session", action: "new_chat" }, false),
      };
      const sends = { runs: failedRuns([row]), ...(offered ? { newChat: () => undefined } : {}) };
      return (
        <div className="cv-gallery-new-chat" style={{ padding: "16px 24px 0" }}>
          {LOOKS[look] && <style>{LOOKS[look]}</style>}
          <div className="cv-user" style={{ display: "flex", flexDirection: "column", alignItems: "flex-end" }}>
            <div className="cv-user__body">
              <div className="ui-glass cv-user__bubble">{row.text}</div>
            </div>
            <FailedSendsContext.Provider value={sends}>
              <DeliveryFailure row={row} />
            </FailedSendsContext.Provider>
          </div>
        </div>
      );
    };
  },
  styles: () =>
    Promise.all([import("../../../ui/controls.css"), import("../styles.css"), import("./conversation.css")]),
  variants: {
    solid: {
      note: "Shipped. New chat in the design system's solid button (its one primary action) leads the card; Edit, Remove and Details stay links; no Retry. It reads as the way out at a glance, which the link-styled Trust folder never had to.",
      props: { look: "solid", offered: true },
    },
    subtle: {
      note: "New chat in the subtle button: a button, but it weighs the same as the links beside it, so the eye does not land on it first.",
      props: { look: "subtle", offered: true },
    },
    link: {
      note: "New chat as an emphasized link, as Trust folder draws: consistent with the card's other actions, but it reads as one more option among four, the thing Leo asked to fix.",
      props: { look: "link", offered: true },
    },
    "no-new-chat": {
      note: "A pane that cannot start a chat (no chat.new): the sentence, Edit, Remove and Details; still no Retry.",
      props: { look: "solid", offered: false },
    },
  },
});
