// l10n-allow-file: deterministic gallery fixture labels, not shipped copy.
// Leo, 2026-11-07 (ask-bc3f176943): "the user's prompt, like, fades in from the right and, like,
// grows to the left ... it's all just one unified motion". A sent prompt's bubble comes in on the
// send motion (conversation.css SEND-ENTRANCE) while the thread rises into its room and the thinking
// row fades in on the same clock. `reveal` is the product's: the bubble opens leftward from its right
// edge, its text never scaled. The others are for comparison: `grow` scales it from its right edge,
// `slide` moves it in from the right, and `fade` is the entrance before (opacity only).
import { useMemo, useState } from "react";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import { componentEntry } from "../../../gallery/format";
import { VirtualTranscript } from "../App";
import type { AcpmuxRow } from "../model";
import { THINKING } from "./turns";

type Variant = "reveal" | "grow" | "slide" | "fade";

const row = (id: string, kind: "user" | "assistant", text: string, at: number): AcpmuxRow => ({
  id,
  kind,
  text,
  version: 1,
  at,
});

const HISTORY: AcpmuxRow[] = [
  row("send-history-user-1", "user", "Can you look at why the nightly failed?", minutesAgo(9)),
  row("send-history-answer-1", "assistant", "The notarize step timed out; the build itself passed.", minutesAgo(8)),
  row("send-history-user-2", "user", "ok and now about now", minutesAgo(3)),
  row("send-history-answer-2", "assistant", "Everything on the board is green again.", minutesAgo(2)),
];

function SendEntranceGallery({ variant, sent: initiallySent }: { variant: Variant; sent?: boolean }) {
  const [sent, setSent] = useState(initiallySent ? 1 : 0);
  const rows = useMemo(
    () => [
      ...HISTORY,
      ...(sent > 0
        ? [
            row(
              `send-user-${sent}`,
              "user",
              "what else do you think would be good across the project can you go independently look at what needs helping out and then go ahead",
              GALLERY_NOW,
            ),
            { id: "send-thinking", version: 1, at: GALLERY_NOW, kind: THINKING, below: true } as AcpmuxRow,
          ]
        : []),
    ],
    [sent],
  );
  return (
    <main className="message-entrance-gallery" data-send-entrance={variant} data-send-entrance-gallery>
      <header className="message-entrance-gallery__header">
        <div>
          <h1>Sent prompt entrance</h1>
          <p>Send a prompt: its room, its bubble and the thread's rise move as one, on the send motion.</p>
        </div>
        <button type="button" className="ui-button" onClick={() => setSent((value) => value + 1)}>
          Send prompt
        </button>
      </header>
      <div className="message-entrance-gallery__transcript">
        <div className="acpmux-shell" style={{ height: "100%" }}>
          <VirtualTranscript
            rows={rows}
            sessionId={`send-entrance-${variant}`}
            onToggleActivity={() => {}}
            expanded={new Set()}
            working={sent > 0}
          />
        </div>
      </div>
    </main>
  );
}

export default componentEntry<{ variant: Variant; sent?: boolean }>({
  id: "agent-pane.send-entrance",
  title: "Sent prompt entrance",
  area: "Agent pane",
  pane: true,
  experimental: true,
  height: 560,
  anchors: [{ selector: "[data-send-entrance-gallery]" }],
  covers: [
    "agent-session/acpmux/conversation/conversation.css#SEND-ENTRANCE",
    "agent-session/acpmux/conversation/followGlide.ts",
  ],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("./MessageEntrance.gallery.css"),
    ]),
  load: async () => SendEntranceGallery,
  variants: {
    reveal: {
      props: { variant: "reveal", sent: true },
      note: "Selected: fades in and opens leftward from its right edge; text never scales.",
    },
    grow: { props: { variant: "grow", sent: true }, note: "Scale .94→1 from the right edge with the fade." },
    slide: { props: { variant: "slide", sent: true }, note: "Moves in 16px from the right with the fade." },
    fade: { props: { variant: "fade", sent: true }, note: "Before: opacity only at its final size." },
  },
});
