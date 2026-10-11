// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { useRef, useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Dialog } from "./Dialog";
import { UiProvider } from "./UiProvider";

type Props = {
  initialFocus?: "field" | false;
};

function DialogGallery({ initialFocus = "field" }: Props) {
  const [container, setContainer] = useState<HTMLDivElement | null>(null);
  const [open, setOpen] = useState(false);
  const [event, setEvent] = useState("Ready");
  const field = useRef<HTMLInputElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);

  const close = (reason: string) => {
    setEvent(reason);
    setOpen(false);
  };

  return (
    <div ref={setContainer} className="dialog-gallery-stage">
      <UiProvider container={container}>
        <div className="dialog-gallery-copy">
          <strong>Deployment approval</strong>
          <span>Modal focus, dismissal, and action feedback.</span>
        </div>
        <button
          ref={trigger}
          type="button"
          className="ui-button dialog-gallery-trigger"
          aria-expanded={open}
          onClick={() => {
            setEvent("Opened");
            setOpen(true);
          }}
        >
          Open dialog
        </button>
        <button
          type="button"
          className="ui-button dialog-gallery-outside"
          data-testid="dialog-gallery-outside"
          onClick={() => close("Dismissed outside")}
        >
          Behind dialog
        </button>
        <Dialog
          open={open}
          onOpenChange={(next) => {
            setOpen(next);
            if (!next) setEvent("Dismissed");
          }}
          label="Deploy preview"
          className="dialog-gallery-dialog"
          backdropClassName="dialog-gallery-backdrop"
          initialFocus={initialFocus === "field" ? field : false}
        >
          <div className="dialog-gallery-content">
            <div>
              <h2>Deploy preview</h2>
              <p>Choose an environment for the next preview build.</p>
            </div>
            <label className="dialog-gallery-label">
              Environment
              <input ref={field} aria-label="Environment" defaultValue="staging" />
            </label>
            <div className="dialog-gallery-actions">
              <button type="button" className="ui-button" onClick={() => close("Cancelled")}>
                Cancel
              </button>
              <button type="button" className="ui-button dialog-gallery-primary" onClick={() => close("Deployed")}>
                Deploy
              </button>
            </div>
          </div>
        </Dialog>
        <output className="dialog-gallery-receipt" data-testid="dialog-gallery-receipt" aria-live="polite">
          {event}
        </output>
      </UiProvider>
    </div>
  );
}

const openDialog: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open dialog" });
  await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Deploy preview" }));
};

const openClose: Play = async (ctx) => {
  await openDialog(ctx);
  await ctx.click({ role: "button", name: "Cancel" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"][aria-label="Deploy preview"]') === null);
};

const escapeFocus: Play = async (ctx) => {
  await openDialog(ctx);
  await ctx.waitFor(() => ctx.document.activeElement === ctx.find({ role: "textbox", name: "Environment" }));
  await ctx.press("Escape");
  await ctx.waitFor(() => {
    const trigger = ctx.find({ role: "button", name: "Open dialog" });
    return (
      ctx.document.querySelector('[role="dialog"][aria-label="Deploy preview"]') === null &&
      ctx.document.activeElement === trigger
    );
  });
};

const focusTrap: Play = async (ctx) => {
  await openDialog(ctx);
  const field = ctx.find({ role: "textbox", name: "Environment" });
  const cancel = ctx.find({ role: "button", name: "Cancel" });
  await ctx.waitFor(() => ctx.document.activeElement === field);
  await ctx.press("Tab");
  await ctx.waitFor(() => ctx.document.activeElement === cancel);
  await ctx.press("Shift+Tab");
  await ctx.waitFor(() => ctx.document.activeElement === field);
};

const chordEscape: Play = async (ctx) => {
  await openDialog(ctx);
  await ctx.press("Meta+Escape");
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"][aria-label="Deploy preview"]') !== null);
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"][aria-label="Deploy preview"]') === null);
};

const outsideDismiss: Play = async (ctx) => {
  await openDialog(ctx);
  await ctx.click({ testId: "dialog-gallery-outside" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"][aria-label="Deploy preview"]') === null);
};

const confirm: Play = async (ctx) => {
  await openDialog(ctx);
  await ctx.click({ role: "button", name: "Deploy" });
  await ctx.waitFor(() => ctx.find({ testId: "dialog-gallery-receipt" }).textContent === "Deployed");
};

export default componentEntry<Props>({
  id: "ui.dialog",
  title: "Modal dialog",
  area: "UI primitives",
  height: 420,
  widths: { narrow: 360, normal: 560, wide: 820 },
  anchors: [{ selector: ".dialog-gallery-receipt" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Opening and dismissing a portaled modal must not move the receipt anchor." },
    layoutShiftMax: { value: 0, reason: "The dialog is portaled and must not add page flow." },
    popupLayer: { value: true, reason: "The modal backdrop and dialog must remain opaque, topmost, and unclipped." },
    longFrameFailMs: { value: 33, reason: "Modal focus and dismissal should stay within two display frames." },
    settleMaxMs: { value: 250, reason: "Opening, focus changes, and dismissal are local interactions." },
  },
  covers: ["ui/Dialog.tsx#Dialog"],
  load: async () => DialogGallery,
  styles: () => Promise.all([import("./ui.css"), import("./Dialog.gallery.css")]),
  variants: {
    closed: { props: {} },
    open: { props: {}, play: openDialog },
    "open-close": { props: {}, play: openClose },
    "escape-focus": { props: {}, play: escapeFocus },
    "focus-trap": { props: {}, play: focusTrap },
    "chord-escape": { props: {}, play: chordEscape },
    "outside-dismiss": { props: {}, play: outsideDismiss },
    confirm: { props: {}, play: confirm },
    "browser-focus": { props: { initialFocus: false }, play: openDialog },
  },
});
