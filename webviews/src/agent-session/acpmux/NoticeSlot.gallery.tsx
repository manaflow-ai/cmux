// l10n-allow-file: gallery fixture notice text, not shipped UI.
//
// The composer's notice slot (hq#2569 #12): several notices want the line above the composer at
// once, and only the highest tier draws. Dismissing the error lets the next one through.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { Notice, NoticeSlot, type NoticeTier } from "./NoticeSlot";

type Props = { lines: { id: string; tier: NoticeTier; text: string }[] };

function GalleryNoticeSlot({ lines }: Props) {
  const [gone, setGone] = useState<string[]>([]);
  return (
    <div className="notice-slot-gallery">
      <NoticeSlot>
        {lines.map(({ id, tier, text }) => (
          <Notice key={id} id={id} tier={tier} when={!gone.includes(id)}>
            <div className="acpmux-host-error" data-notice-line={id}>
              <div className="acpmux-host-error-card">
                <p className="acpmux-host-error-message">{text}</p>
                <div className="acpmux-host-error-actions">
                  <button type="button" data-notice-action="dismiss" onClick={() => setGone([...gone, id])}>
                    Dismiss
                  </button>
                </div>
              </div>
            </div>
          </Notice>
        ))}
      </NoticeSlot>
    </div>
  );
}

const stacked: Props = {
  lines: [
    { id: "update", tier: "update", text: "Updating Claude Code…" },
    { id: "hint", tier: "hint", text: "Choose a folder for this chat." },
    { id: "error", tier: "error", text: "Couldn't reach this Mac's agent. Retrying…" },
  ],
};

const clearError: Play = async (ctx) => {
  await ctx.click({ selector: '[data-notice-line="error"] [data-notice-action="dismiss"]' });
  await ctx.waitFor(() => ctx.document.querySelector('[data-notice-line="hint"]') !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.notice-slot",
  title: "Composer notice slot",
  area: "Agent pane",
  pane: true,
  height: 120,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: ".notice-slot-gallery" }],
  covers: ["agent-session/acpmux/NoticeSlot.tsx#NoticeSlot", "agent-session/acpmux/NoticeSlot.tsx#Notice"],
  styles: () => import("./styles.css"),
  load: async () => GalleryNoticeSlot,
  variants: {
    stacked: {
      note: "An error, a hint and an update in progress all want the line: only the error draws.",
      props: stacked,
    },
    "error-cleared": {
      note: "Dismissing the error lets the hint through; the update in progress still waits below it.",
      props: stacked,
      play: clearError,
    },
  },
});
