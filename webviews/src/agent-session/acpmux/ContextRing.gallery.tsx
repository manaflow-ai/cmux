// l10n-allow-file: gallery fixtures exercise the stable automation label, not shipped copy.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { useT } from "./i18n";
import { ContextRing } from "./ComposerPickers";
import { openPicker } from "./pickerOpeners";

type Props = { used?: number; size?: number; setup?: number };

function GalleryContextRing(props: Props) {
  const t = useT();
  const [requested, setRequested] = useState(false);
  return (
    <div className="context-ring-gallery" data-context-automation={requested ? "requested" : "idle"}>
      <ContextRing {...props} />
      <button
        type="button"
        className="context-ring-gallery-opener"
        onClick={() => {
          setRequested(true);
          openPicker(t("context.title"));
        }}
      >
        Open by automation
      </button>
    </div>
  );
}

const openByAutomation: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open by automation" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-context-automation="requested"]') !== null);
};

const openKnownByAutomation: Play = async (ctx) => {
  await openByAutomation(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-context-pop") !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.context-ring",
  title: "Context usage ring",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: ".acpmux-context" }],
  covers: ["agent-session/acpmux/ComposerPickers.tsx#ContextRing"],
  styles: () => Promise.all([import("./styles.css"), import("./composerControls.css")]),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Opening context details must leave the ring's trigger geometry fixed.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "The usage details render in a portal and must not add flow around the ring.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Context details are a local popover and should open within one display frame.",
    },
  },
  load: async () => GalleryContextRing,
  variants: {
    "unknown-usage": {
      note: "Before the first usage report the ring keeps its place, and automation cannot open an empty 0% surface.",
      props: {},
      play: openByAutomation,
    },
    "known-usage": {
      note: "Once usage is known, the same automation path opens the anchored usage details.",
      props: { used: 33551, size: 200000, setup: 12000 },
      play: openKnownByAutomation,
    },
  },
});
