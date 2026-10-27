// l10n-allow-file: gallery fixtures (a sample app name and drawn frames), not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { ComputerUsePreviewCard } from "./ComputerUsePreviewCard";
import type { ComputerUsePreview } from "./computerUsePreview";

type Props = { preview: ComputerUsePreview };

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

function GalleryComputerUsePreview({ preview }: Props) {
  const [shown, setShown] = useState<ComputerUsePreview | null>(preview);
  return (
    <div className="acpmux-shell" data-cu-preview-fixture style={{ position: "relative", height: "100%" }}>
      <div className="acpmux-stage" style={{ height: "100%" }}>
        <ComputerUsePreviewCard preview={shown} onOpen={() => {}} onClose={() => setShown(null)} />
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
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-cu-preview-fixture]" }],
  covers: ["agent-session/acpmux/computerUse/ComputerUsePreviewCard.tsx#ComputerUsePreviewCard"],
  styles: () => import("../styles.css"),
  load: async () => GalleryComputerUsePreview,
  variants: {
    running: { note: "While the agent uses the app: its newest frame and its name.", props: { preview: running } },
    done: {
      note: "After the session ended: the last frame dimmed, the app's icon and a check.",
      props: { preview: done },
    },
    "no-app-name": { props: { preview: { ...running, app: "" } } },
    close: { props: { preview: running }, play: close },
  },
});
