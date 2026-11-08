// l10n-allow-file: gallery fixtures (sample prompts, harnesses and hosts), not shipped UI.
//
// The sender chip under a prompt sent with `acpmux send` from a harness or an app (#38065): before
// it, the prompt said only "via CLI on <host>"; after, it names where it came from, marked
// self-reported unless acpmux found the app itself.
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxRow } from "../model";
import type { SentFrom } from "../conversation/sentFromHarness";
import { MessageRow } from "./MessageRow";

type State = "before" | "selfReported" | "confirmed";

const desktop: Omit<SentFrom, "confirmed"> = {
  promptId: "gallery-sent-from",
  harness: "claude-code",
  label: "Claude desktop",
  sessionId: "8f0c2b7e",
};

const sentFrom: Record<State, SentFrom | undefined> = {
  before: undefined,
  selfReported: { ...desktop, confirmed: false },
  confirmed: {
    ...desktop,
    checked: { app: "Claude.app", signedBy: "Developer ID Application: Anthropic" },
    confirmed: true,
  },
};

function row(state: State): AcpmuxRow {
  return {
    id: "gallery-sent-from",
    version: 1,
    at: 0,
    kind: "user",
    text: "The checkout page build is green again; can you re-run the visual check?",
    viaCli: "studio-mac",
    ...(sentFrom[state] && { sentFrom: sentFrom[state] }),
  };
}

function SentFromChipGallery({ state }: { state: State }) {
  return (
    <div className="acpmux-stage" style={{ padding: 24 }}>
      <MessageRow row={row(state)} onToggleActivity={() => undefined} expanded={false} />
    </div>
  );
}

export default componentEntry<{ state: State }>({
  id: "agent-pane.sent-from-chip",
  title: "Sender chip under a sent prompt",
  area: "Agent pane",
  pane: true,
  height: 200,
  widths: { narrow: 420, normal: 760 },
  covers: ["agent-session/acpmux/conversation/SentFromLine.tsx#SentFromLine"],
  styles: () => Promise.all([import("../styles.css"), import("../conversation/conversation.css")]),
  load: async () => SentFromChipGallery,
  variants: {
    before: {
      props: { state: "before" },
      note: "Before: a prompt sent with acpmux send from Claude desktop reads as the person's, via CLI on the host.",
    },
    "self-reported": {
      props: { state: "selfReported" },
      note: "After: the sender chip names Claude desktop, marked self-reported because acpmux did not find the app.",
    },
    confirmed: {
      props: { state: "confirmed" },
      note: "After: acpmux found Claude.app on the sending process chain, so the chip carries no self-reported note.",
    },
  },
});
