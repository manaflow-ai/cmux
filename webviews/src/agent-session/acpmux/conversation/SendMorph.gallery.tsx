// l10n-allow-file: deterministic gallery fixture labels, not shipped copy.
// Leo, 2026-11-08 (ask-157340f908): "if you're at the bottom or something, then the transformation
// applies whatever's in your composer into your depicted message." A composer card holds typed words
// and a screenshot's chip; Send hands them to the real transcript at its latest row, and what the card
// drew becomes the sent message (sendMorph.ts) on the send motion while the thread rises. `shell` is
// the product's: a bubble's glass grows out of the card around the words and settles as the sent
// bubble while the screenshot moves from its chip to its slot. `lift` moves the words up into the
// bubble, whose glass fills in behind them where it lands; `inplace` is the before (#38159): the
// composer empties and the prompt fades in where it lands.
import { useMemo, useRef, useState } from "react";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import { componentEntry } from "../../../gallery/format";
import { VirtualTranscript } from "../App";
import type { AcpmuxRow, PromptImage } from "../model";
import { chipRef, noteSendOrigins, type SendMorphStyle } from "./sendMorph";
import { THINKING } from "./turns";

const TYPED = "why does the sidebar jump when I open this?";
const SHOT_ID = "send-morph-shot";

const row = (id: string, kind: "user" | "assistant", text: string, at: number): AcpmuxRow => ({
  id,
  kind,
  text,
  version: 1,
  at,
});

const HISTORY: AcpmuxRow[] = [
  row("morph-history-user-1", "user", "Can you look at why the nightly failed?", minutesAgo(9)),
  row("morph-history-answer-1", "assistant", "The notarize step timed out; the build itself passed.", minutesAgo(8)),
  row("morph-history-user-2", "user", "ok and now about now", minutesAgo(3)),
  row("morph-history-answer-2", "assistant", "Everything on the board is green again.", minutesAgo(2)),
];

/// A 1440x900 screenshot: a solid PNG the page draws, so its header names its size.
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

function SendMorphGallery({ variant }: { variant: SendMorphStyle }) {
  const [shot] = useState(screenshot);
  const [sends, setSends] = useState(0);
  const [drafted, setDrafted] = useState(true);
  const card = useRef<HTMLDivElement>(null);
  const rows = useMemo(() => {
    const sent: AcpmuxRow[] = [];
    for (let index = 1; index <= sends; index += 1) {
      const image: PromptImage = {
        id: `${SHOT_ID}-${index}`,
        mimeType: "image/png",
        name: "Screenshot.png",
        src: shot,
      };
      sent.push({ ...row(`local-morph-${index}`, "user", TYPED, GALLERY_NOW), images: [image] });
    }
    return [
      ...HISTORY,
      ...sent,
      ...(sends > 0
        ? [{ id: "morph-thinking", version: 1, at: GALLERY_NOW, kind: THINKING, below: true } as AcpmuxRow]
        : []),
    ];
  }, [sends, shot]);
  const send = () => {
    // As the composer does (Composer.tsx send): note what the card draws, then let it go.
    noteSendOrigins([{ id: `${SHOT_ID}-${sends + 1}` }], card.current);
    setDrafted(false);
    setSends((value) => value + 1);
  };
  return (
    <main className="message-entrance-gallery" data-send-morph={variant} data-send-morph-gallery>
      <header className="message-entrance-gallery__header">
        <div>
          <h1>Sent prompt from the composer</h1>
          <p>At the latest row, what the composer holds becomes the sent message on the send motion.</p>
        </div>
        <button type="button" className="ui-button" data-send onClick={drafted ? send : () => setDrafted(true)}>
          {drafted ? "Send" : "Type again"}
        </button>
      </header>
      <div className="message-entrance-gallery__transcript">
        {/* The shell lays its scroller and the composer's card out in a column, as the pane's dock does. */}
        <div className="acpmux-shell" style={{ height: "100%", flexDirection: "column" }}>
          <VirtualTranscript
            rows={rows}
            sessionId={`send-morph-${variant}`}
            onToggleActivity={() => {}}
            expanded={new Set()}
            working={sends > 0}
            sends={sends}
          />
          <div
            ref={card}
            className="ui-glass ui-glass-floats ui-glass-material acpmux-composer-box"
            style={{
              flex: "none",
              margin: "8px 16px 16px",
              padding: "var(--ds-space-2) var(--ds-space-3)",
              borderRadius: 12,
            }}
          >
            {drafted && (
              <fieldset className="acpmux-attachments">
                <div className="acpmux-attachment-slot" ref={chipRef(`${SHOT_ID}-${sends + 1}`)}>
                  <div className="acpmux-attachment acpmux-attachment-image">
                    <img alt="Screenshot" src={shot} />
                  </div>
                </div>
              </fieldset>
            )}
            <div className="acpmux-md-field acpmux-composer-prompt">
              <div contentEditable={false} className="acpmux-md" style={{ minHeight: 22 }}>
                {drafted ? <p style={{ margin: 0 }}>{TYPED}</p> : <p style={{ margin: 0 }} />}
              </div>
            </div>
          </div>
        </div>
      </div>
    </main>
  );
}

export default componentEntry<{ variant: SendMorphStyle }>({
  id: "agent-pane.send-morph",
  title: "Sent prompt from the composer",
  area: "Agent pane",
  pane: true,
  experimental: true,
  height: 600,
  anchors: [{ selector: "[data-send-morph-gallery]" }],
  covers: [
    "agent-session/acpmux/conversation/sendMorph.ts",
    "agent-session/acpmux/conversation/conversation.css#SEND-ENTRANCE",
  ],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../composerAttachments.css"),
      import("./MessageEntrance.gallery.css"),
    ]),
  load: async () => SendMorphGallery,
  variants: {
    shell: {
      props: { variant: "shell" },
      note: "Selected: a bubble's glass grows out of the composer's card around the words and settles as the sent bubble; the screenshot moves from its chip to its slot. One clock with the thread's rise.",
    },
    lift: {
      props: { variant: "lift" },
      note: "The words and the screenshot move up into place; the bubble's glass fills in behind them where it is.",
    },
    inplace: {
      props: { variant: "inplace" },
      note: "Before (#38159): the composer empties and the prompt fades in where it lands.",
    },
  },
});
