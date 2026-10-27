// l10n-allow-file: gallery fixtures (a sample app name and drawn frames), not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { ComputerUsePreviewCard } from "./ComputerUsePreviewCard";
import { useComputerUsePreviewRoom, type ComputerUsePreview } from "./computerUsePreview";

/// A drawn stand-in for the helper's thumbnail of a calculator window (320 px wide, as the helper's are).
const frame = `data:image/svg+xml,${encodeURIComponent(
  `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="480" viewBox="0 0 320 480">` +
    `<rect width="320" height="480" rx="24" fill="#2b2b2d"/>` +
    `<text x="296" y="120" fill="#fff" font-family="-apple-system,sans-serif" font-size="44" text-anchor="end">5,888</text>` +
    Array.from({ length: 20 }, (_, i) => {
      const x = 20 + (i % 4) * 72;
      const y = 160 + Math.floor(i / 4) * 62;
      const fill = i % 4 === 3 ? "#ff9f0a" : i < 4 ? "#5b5b5e" : "#3a3a3c";
      return `<circle cx="${x + 30}" cy="${y + 26}" r="26" fill="${fill}"/>`;
    }).join("") +
    `</svg>`,
)}`;

/// A drawn stand-in for the app's icon.
const icon = `data:image/svg+xml,${encodeURIComponent(
  `<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">` +
    `<rect x="8" y="8" width="80" height="80" rx="18" fill="#e9e9ec"/>` +
    `<rect x="22" y="20" width="52" height="16" rx="3" fill="#3a3a3c"/>` +
    `<g fill="#ff9f0a"><rect x="22" y="44" width="14" height="10" rx="2"/><rect x="41" y="44" width="14" height="10" rx="2"/>` +
    `<rect x="60" y="44" width="14" height="10" rx="2"/><rect x="22" y="60" width="14" height="10" rx="2"/>` +
    `<rect x="41" y="60" width="14" height="10" rx="2"/><rect x="60" y="60" width="14" height="10" rx="2"/></g>` +
    `</svg>`,
)}`;

const running: ComputerUsePreview = { session: "cua_native_1", app: "Calculator", done: false, frame };
const done: ComputerUsePreview = { ...running, done: true, icon };

type Props = { preview: ComputerUsePreview; chat?: boolean };

/// A prompt long enough to reach the card's side: with the column's room kept, it wraps before the card.
const prompt =
  "Use cmux Computer Use to open the Calculator app and compute 128 x 46 by clicking its buttons. Do not use the shell. When done, say the result.";

function GalleryComputerUsePreview({ preview, chat }: Props) {
  const [closed, setClosed] = useState(false);
  // As the pane does (App.tsx): no card in a pane too narrow to keep its room.
  const room = useComputerUsePreviewRoom();
  const shown = room && !closed ? preview : null;
  return (
    <div className="acpmux-shell" data-cu-preview-fixture style={{ position: "relative", height: "100%" }}>
      <div className="acpmux-main" data-cu-preview={shown ? "" : undefined}>
        <div className="acpmux-stage" style={{ height: "100%" }}>
          <ComputerUsePreviewCard preview={shown} onOpen={() => {}} onClose={() => setClosed(true)} />
          {chat && (
            <div style={{ position: "relative", flex: 1, marginTop: 52 }}>
              <div className="acpmux-row acpmux-user" style={{ top: 0 }}>
                <div className="acpmux-user-bubble">{prompt}</div>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

const close: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Hide Preview" });
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-cu-preview"));
};

export default componentEntry<Props>({
  id: "agent-pane.computer-use-preview",
  title: "Computer use live preview",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 360, normal: 640, wide: 900 },
  anchors: [{ selector: "[data-cu-preview-fixture]" }],
  covers: ["agent-session/acpmux/computerUse/ComputerUsePreviewCard.tsx#ComputerUsePreviewCard"],
  styles: () =>
    Promise.all([
      import("../../../ui/glass/glass.css"),
      import("../styles.css"),
      import("../conversation/conversation.css"),
    ]),
  load: async () => GalleryComputerUsePreview,
  variants: {
    running: { note: "While the agent uses the app: its newest frame and its name.", props: { preview: running } },
    done: {
      note: "After the session ended: the last frame dimmed, the app's icon centered, a check on its corner.",
      props: { preview: done },
    },
    "done-no-icon": {
      note: "Done, with no icon found: the check alone.",
      props: { preview: { ...done, icon: undefined } },
    },
    "no-app-name": {
      note: "No name and no window title: no title row, never Unknown app.",
      props: { preview: { ...running, app: "" } },
    },
    "beside-chat": {
      note: "The column keeps the card's room: the prompt wraps before the card, nothing runs under it. Narrow panes show no card.",
      props: { preview: running, chat: true },
    },
    close: { props: { preview: running }, play: close },
  },
});
