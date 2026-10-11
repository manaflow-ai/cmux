// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { useRef, useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Sheet, type SheetProps } from "./Sheet";
import { UiProvider } from "./UiProvider";

type Props = {
  side?: SheetProps["side"];
  initialFocus?: "field" | false;
};

function SheetGallery({ side = "bottom", initialFocus = "field" }: Props) {
  const [container, setContainer] = useState<HTMLDivElement | null>(null);
  const [open, setOpen] = useState(false);
  const [event, setEvent] = useState("Ready");
  const field = useRef<HTMLInputElement>(null);

  const close = (reason: string) => {
    setEvent(reason);
    setOpen(false);
  };

  return (
    <div ref={setContainer} className="sheet-gallery-stage">
      <UiProvider container={container}>
        <div className="sheet-gallery-copy">
          <strong>Session details</strong>
          <span>A responsive sheet that keeps its focus and placement contract.</span>
        </div>
        <button
          type="button"
          className="ui-button sheet-gallery-trigger"
          aria-expanded={open}
          onClick={() => {
            setEvent("Opened");
            setOpen(true);
          }}
        >
          Open sheet
        </button>
        <output className="sheet-gallery-receipt" data-testid="sheet-gallery-receipt" aria-live="polite">
          {event}
        </output>
        <Sheet
          open={open}
          onOpenChange={(next) => {
            setOpen(next);
            if (!next) setEvent("Dismissed");
          }}
          label="Session details"
          side={side}
          className="sheet-gallery-sheet"
          initialFocus={initialFocus === "field" ? field : false}
        >
          <div className="sheet-gallery-content">
            <div className="sheet-gallery-handle" aria-hidden="true" />
            <div>
              <h2>Session details</h2>
              <p>Keep the current workspace available while adjusting the session.</p>
            </div>
            <label className="sheet-gallery-label">
              Session name
              <input ref={field} aria-label="Session name" defaultValue="Design review" />
            </label>
            <label className="sheet-gallery-toggle">
              <input type="checkbox" aria-label="Keep session pinned" defaultChecked />
              Keep session pinned
            </label>
            <div className="sheet-gallery-actions">
              <button type="button" className="ui-button" onClick={() => close("Cancelled")}>
                Cancel
              </button>
              <button type="button" className="ui-button sheet-gallery-primary" onClick={() => close("Saved")}>
                Save
              </button>
            </div>
          </div>
        </Sheet>
      </UiProvider>
    </div>
  );
}

const openSheet: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open sheet" });
  await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Session details" }));
};

const placement =
  (side: NonNullable<Props["side"]>): Play =>
  async (ctx) => {
    await openSheet(ctx);
    await ctx.waitFor(() =>
      ctx.find({ role: "dialog", name: "Session details" }).classList.contains(`ui-sheet-${side}`),
    );
  };

const escapeFocus: Play = async (ctx) => {
  await openSheet(ctx);
  await ctx.waitFor(() => ctx.document.activeElement === ctx.find({ role: "textbox", name: "Session name" }));
  await ctx.press("Escape");
  await ctx.waitFor(() => {
    const trigger = ctx.find({ role: "button", name: "Open sheet" });
    return (
      ctx.document.querySelector('[role="dialog"][aria-label="Session details"]') === null &&
      ctx.document.activeElement === trigger
    );
  });
};

const focusTrap: Play = async (ctx) => {
  await openSheet(ctx);
  const field = ctx.find({ role: "textbox", name: "Session name" });
  const checkbox = ctx.find({ role: "checkbox", name: "Keep session pinned" });
  await ctx.waitFor(() => ctx.document.activeElement === field);
  await ctx.press("Tab");
  await ctx.waitFor(() => ctx.document.activeElement === checkbox);
  await ctx.press("Shift+Tab");
  await ctx.waitFor(() => ctx.document.activeElement === field);
};

const save: Play = async (ctx) => {
  await openSheet(ctx);
  await ctx.click({ role: "button", name: "Save" });
  await ctx.waitFor(() => ctx.find({ testId: "sheet-gallery-receipt" }).textContent === "Saved");
};

export default componentEntry<Props>({
  id: "ui.sheet",
  title: "Modal sheet",
  area: "UI primitives",
  height: 440,
  widths: { narrow: 360, normal: 560, wide: 820 },
  anchors: [{ selector: ".sheet-gallery-receipt" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Opening and dismissing a sheet must not move the receipt anchor." },
    layoutShiftMax: { value: 0, reason: "The sheet is portaled and must not add page flow." },
    popupLayer: { value: true, reason: "The sheet and backdrop must stay topmost, opaque, and inside the viewport." },
    longFrameFailMs: {
      value: 33,
      reason: "Sheet focus and placement transitions should stay within two display frames.",
    },
    settleMaxMs: { value: 250, reason: "Sheet opening, focus, and dismissal are local interactions." },
  },
  covers: ["ui/Sheet.tsx#Sheet"],
  load: async () => SheetGallery,
  styles: () => Promise.all([import("./ui.css"), import("./Sheet.gallery.css")]),
  variants: {
    closed: { props: {} },
    bottom: { props: { side: "bottom" }, play: placement("bottom") },
    top: { props: { side: "top" }, play: placement("top") },
    leading: { props: { side: "leading" }, play: placement("leading") },
    trailing: { props: { side: "trailing" }, play: placement("trailing") },
    "escape-focus": { props: {}, play: escapeFocus },
    "focus-trap": { props: {}, play: focusTrap },
    save: { props: {}, play: save },
    "browser-focus": { props: { initialFocus: false }, play: openSheet },
  },
});
