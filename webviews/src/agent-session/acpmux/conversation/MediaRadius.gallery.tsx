// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// One media radius for the transcript's images (`--cv-media-radius`, conversation.css): a sent
// prompt's thumbnails above its bubble (UserBubble.tsx SentImages) and an image in a reply
// (Markdown.tsx `.cv-img`). Each arm draws a prompt with an image and the reply with one, and
// `compare` draws the three arms side by side. Shipped: all 8 (Claude's composer thumbnails,
// cmux-design-references claude/live/composer-image-attachments-grid, round at about 5% of the
// tile, and a reply's video, chips.css `.cv-media`, already draws at 8).
import { useState, type CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import { ImageViewerContext } from "./imageViewerContext";
import { TurnActionsContext } from "./turnActions";
import { SentImages } from "./UserBubble";

type Arm = "all-12" | "all-8" | "sent-12-reply-8";
type Props = { arms: Arm[] };

const RADII: Record<Arm, { sent: string; reply: string; label: string }> = {
  "all-12": { sent: "12px", reply: "12px", label: "All 12" },
  "all-8": { sent: "8px", reply: "8px", label: "All 8 (shipped)" },
  "sent-12-reply-8": { sent: "12px", reply: "8px", label: "Sent 12, reply 8 (before)" },
};

/// A screenshot-like image: a title bar, a sidebar and lines of text.
function paint(width: number, height: number, hue: number): string {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ink = canvas.getContext("2d")!;
  ink.fillStyle = `hsl(${hue} 30% 16%)`;
  ink.fillRect(0, 0, width, height);
  ink.fillStyle = `hsl(${hue} 30% 24%)`;
  ink.fillRect(0, 0, width, height * 0.07);
  ink.fillRect(0, 0, width * 0.22, height);
  ink.fillStyle = `hsl(${hue} 70% 62%)`;
  for (let line = 0; line < 9; line += 1)
    ink.fillRect(width * 0.27, height * (0.14 + line * 0.08), width * (0.3 + ((line * 37) % 40) / 100), height * 0.025);
  return canvas.toDataURL("image/png");
}

const SENT = [
  { id: "media-radius-a", mimeType: "image/png", name: "sidebar.png", width: 1440, height: 900 },
  { id: "media-radius-b", mimeType: "image/png", name: "toolbar.png", width: 900, height: 900 },
];

function Pair({ arm }: { arm: Arm }) {
  const [urls] = useState(
    () =>
      new Map([
        ["media-radius-a", paint(1440, 900, 220)],
        ["media-radius-b", paint(900, 900, 150)],
        ["reply", paint(1200, 700, 30)],
      ]),
  );
  const [actions] = useState(() => ({ promptImage: (id: string) => Promise.resolve(urls.get(id)) }));
  const radii = RADII[arm];
  return (
    <TurnActionsContext.Provider value={actions}>
      <div style={{ display: "flex", flexDirection: "column", gap: 16, minWidth: 0 }}>
        <div className="cv-user" style={{ "--cv-media-radius": radii.sent } as CSSProperties}>
          <SentImages images={SENT} />
          <div className="ui-glass cv-user__bubble">Why does the sidebar overlap the toolbar here?</div>
        </div>
        <div className="cv-md" style={{ "--cv-media-radius": radii.reply } as CSSProperties}>
          <p>The toolbar draws before the sidebar measures itself:</p>
          <img className="cv-img" src={urls.get("reply")} alt="" />
        </div>
        <div style={{ color: "var(--cv-text-muted)", fontSize: "var(--text-caption)" }}>{radii.label}</div>
      </div>
    </TurnActionsContext.Provider>
  );
}

function MediaRadius({ arms }: Props) {
  return (
    <ImageViewerContext.Provider value={() => {}}>
      <div
        className="acpmux-shell"
        style={{
          padding: 16,
          display: "grid",
          gridTemplateColumns: `repeat(${arms.length}, minmax(0, 1fr))`,
          gap: 32,
        }}
      >
        {arms.map((arm) => (
          <Pair key={arm} arm={arm} />
        ))}
      </div>
    </ImageViewerContext.Provider>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.media-radius",
  title: "Transcript media radius",
  area: "Agent pane",
  pane: true,
  height: 460,
  widths: { narrow: 480, normal: 1100, wide: 1400 },
  covers: ["agent-session/acpmux/conversation/UserBubble.tsx#SentImages"],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => MediaRadius,
  variants: {
    compare: {
      note: "The three arms side by side: all 12, all 8 (shipped), and sent 12 with reply 8 (before).",
      props: { arms: ["all-12", "all-8", "sent-12-reply-8"] },
    },
    "all-8": { note: "Shipped: thumbnails and reply images at 8, as a reply's video.", props: { arms: ["all-8"] } },
    "all-12": { note: "Everything at the cards' 12, the prompt bubble's radius.", props: { arms: ["all-12"] } },
    "sent-12-reply-8": {
      note: "Before: sent thumbnails at 12, a reply's image at 8.",
      props: { arms: ["sent-12-reply-8"] },
    },
  },
});
