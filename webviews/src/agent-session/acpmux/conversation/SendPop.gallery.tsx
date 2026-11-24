// l10n-allow-file: deterministic gallery fixture labels, not shipped copy.
// Leo, 2026-11-22: "dang it's CUTE and so much NICER FEELING than just a jarring instant send";
// "it does a little pop and settle". A sent prompt still lands at once (its room, the thread and the
// thinking row), and the prompt itself pops in where it sits (conversation.css SEND-POP). `claude`
// is the product's: the Claude desktop app's own user-message entrance (`cds-um-enter`, 450 ms,
// cubic-bezier(.34, 1.3, .64, 1), scale .92 and 6px low, from its trailing edge). The others are
// for comparison: `claude-fade` (Claude's earlier build, which also faded in), `spring` (a damped
// spring from .94) and `none` (the instant send before).
import { useMemo, useState } from "react";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import { componentEntry } from "../../../gallery/format";
import { VirtualTranscript } from "../App";
import type { AcpmuxRow, PromptImage } from "../model";
import { THINKING } from "./turns";

type Variant = "claude" | "claude-fade" | "spring" | "none";

const row = (id: string, kind: "user" | "assistant", text: string, at: number): AcpmuxRow => ({
  id,
  kind,
  text,
  version: 1,
  at,
});

const HISTORY: AcpmuxRow[] = [
  row("pop-history-user-1", "user", "Can you look at why the nightly failed?", minutesAgo(9)),
  row("pop-history-answer-1", "assistant", "The notarize step timed out; the build itself passed.", minutesAgo(8)),
  row("pop-history-user-2", "user", "ok and now about now", minutesAgo(3)),
  row("pop-history-answer-2", "assistant", "Everything on the board is green again.", minutesAgo(2)),
];

const PROMPT =
  "and the send behaviour too... it does a little pop and settle, so much nicer feeling than just a jarring instant send";

/// A 1440x900 screenshot the page draws, for the attachment case.
function screenshot(): string {
  const canvas = document.createElement("canvas");
  canvas.width = 1440;
  canvas.height = 900;
  const context = canvas.getContext("2d")!;
  context.fillStyle = "#3a7bd5";
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = "#f2f4f8";
  context.fillRect(80, 80, 1280, 120);
  return canvas.toDataURL("image/png");
}

function SendPopGallery({ variant, attachment }: { variant: Variant; attachment?: boolean }) {
  const [shot] = useState(screenshot);
  const [sends, setSends] = useState(1);
  const rows = useMemo(() => {
    const sent: AcpmuxRow[] = [];
    for (let index = 1; index <= sends; index += 1) {
      const image: PromptImage = { id: `pop-shot-${index}`, mimeType: "image/png", name: "Screenshot.png", src: shot };
      const prompt = row(`pop-user-${index}`, "user", PROMPT, GALLERY_NOW);
      sent.push(attachment ? { ...prompt, images: [image] } : prompt);
    }
    return [
      ...HISTORY,
      ...sent,
      { id: "pop-thinking", version: 1, at: GALLERY_NOW, kind: THINKING, below: true } as AcpmuxRow,
    ];
  }, [attachment, sends, shot]);
  return (
    <main className="message-entrance-gallery" data-send-pop={variant} data-send-pop-gallery>
      <header className="message-entrance-gallery__header">
        <div>
          <h1>Sent prompt pop</h1>
          <p>Send a prompt: it is in place at once and pops, past its size and back, from its trailing edge.</p>
        </div>
        <button type="button" className="ui-button" onClick={() => setSends((value) => value + 1)}>
          Send prompt
        </button>
      </header>
      <div className="message-entrance-gallery__transcript">
        <div className="acpmux-shell" style={{ height: "100%" }}>
          <VirtualTranscript
            rows={rows}
            sessionId={`send-pop-${variant}${attachment ? "-attachment" : ""}`}
            onToggleActivity={() => {}}
            expanded={new Set()}
            working
          />
        </div>
      </div>
    </main>
  );
}

export default componentEntry<{ variant: Variant; attachment?: boolean }>({
  id: "agent-pane.send-pop",
  title: "Sent prompt pop",
  area: "Agent pane",
  pane: true,
  height: 560,
  anchors: [{ selector: "[data-send-pop-gallery]" }],
  covers: [
    "agent-session/acpmux/conversation/conversation.css#SEND-POP",
    "agent-session/acpmux/conversation/entranceClock.ts",
  ],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../composerAttachments.css"),
      import("./MessageEntrance.gallery.css"),
    ]),
  load: async () => SendPopGallery,
  variants: {
    claude: {
      props: { variant: "claude" },
      note: "Selected: Claude's cds-um-enter. Scale .92 and 6px low to rest on cubic-bezier(.34, 1.3, .64, 1) over 450 ms; passes 1 by 0.24% at 300 ms.",
    },
    "claude-attachment": {
      props: { variant: "claude", attachment: true },
      note: "Selected, with a picture: the picture and the bubble pop together, as Claude's message block does.",
    },
    "claude-fade": {
      props: { variant: "claude-fade" },
      note: "Claude's earlier build: the same pop with a fade from 0.",
    },
    spring: { props: { variant: "spring" }, note: "A damped spring (zeta 0.72) from .94 and 4px low; 3.7% past." },
    none: { props: { variant: "none" }, note: "Before: the instant send (#42669)." },
  },
});
