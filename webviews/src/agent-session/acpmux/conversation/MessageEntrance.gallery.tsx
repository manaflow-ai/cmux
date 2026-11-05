// l10n-allow-file: deterministic gallery fixture labels, not shipped copy.
// The product fades new messages at their final size. The former scale entrance and two other
// compositor-only candidates stay here for comparison without changing layout.
import { useMemo, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { VirtualTranscript } from "../App";
import type { AcpmuxRow } from "../model";

type Variant = "fade" | "scale" | "translate" | "scale-y";

const row = (id: string, kind: "user" | "assistant", text: string, at: number): AcpmuxRow => ({
  id,
  kind,
  text,
  version: 1,
  at,
});

function MessageEntranceGallery({ variant }: { variant: Variant }) {
  const [turn, setTurn] = useState(0);
  const rows = useMemo(
    () => [
      row("entrance-history-user", "user", "Existing prompt", 1),
      row("entrance-history-answer", "assistant", "Existing answer", 2),
      ...(turn > 0
        ? [
            row(`entrance-user-${turn}`, "user", `New prompt ${turn}`, turn * 2 + 1),
            row(`entrance-answer-${turn}`, "assistant", `New answer ${turn}`, turn * 2 + 2),
          ]
        : []),
    ],
    [turn],
  );
  return (
    <main className="message-entrance-gallery" data-variant={variant} data-message-entrance>
      <header className="message-entrance-gallery__header">
        <div>
          <h1>New message entrance</h1>
          <p>Append a prompt and reply to compare a 180ms compositor-only entrance.</p>
        </div>
        <button type="button" className="ui-button" onClick={() => setTurn((value) => value + 1)}>
          Add prompt + reply
        </button>
      </header>
      <div className="message-entrance-gallery__transcript">
        <VirtualTranscript
          rows={rows}
          sessionId={`message-entrance-${variant}`}
          onToggleActivity={() => {}}
          expanded={new Set()}
          working={false}
        />
      </div>
    </main>
  );
}

export default componentEntry<{ variant: Variant }>({
  id: "agent-pane.message-entrance",
  title: "New message entrance",
  area: "Agent pane",
  pane: true,
  experimental: true,
  height: 560,
  anchors: [{ selector: "[data-message-entrance]" }],
  covers: [
    "agent-session/acpmux/VirtualTranscript.tsx",
    "agent-session/acpmux/conversation/conversation.css#cv-message-enter",
  ],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("./MessageEntrance.gallery.css"),
    ]),
  load: async () => MessageEntranceGallery,
  variants: {
    fade: { props: { variant: "fade" }, note: "Opacity only at final size; selected product motion." },
    scale: { props: { variant: "scale" }, note: "Former scale .985→1 with opacity; comparison only." },
    translate: { props: { variant: "translate" }, note: "Translate 4px→0 with opacity; layout remains reserved." },
    "scale-y": {
      props: { variant: "scale-y" },
      note: "ScaleY .98→1 from the bottom with opacity; no height animation.",
    },
  },
});
