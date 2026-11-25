// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Dialog, DialogDescription, DialogTitle } from "./Dialog";

// The dialog's glass (hq RFD "Native or our own web view, per surface", build item 4; the dialog-glass
// experiment, ui/dialogGlass.experiment.ts). Shipped: `page`, the page's own sheet veil and blur
// (popupSurface.css, THE SHEET ROLE). `host`, behind `experiments.dialogGlass` (off by default): the App's
// own sheet glass under the page where the App draws it, the native dialog card's. A browser gallery has no
// App, so the two look alike here: the App's capture shows them.
type Glass = "host" | "page";
// Transcript-like text under the dialog: the glass has to keep it legible over busy content.
const BUSY_TEXT =
  "Read 14 files in webviews/src/ui. The shared dialog portals above the pane, so a confirm never pushes the " +
  "transcript or the composer when it opens. Ran the gallery capture for ui.dialog in light and dark; every " +
  "variant matched its last approved image except the dialogs the change is about. ".repeat(4);

function GlassDialog({ glass, busy = false }: { glass: Glass; busy?: boolean }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="menu-gallery-stage dialog-gallery-glass-stage">
      {busy && (
        <p className="dialog-gallery-busy" aria-hidden="true">
          {BUSY_TEXT}
        </p>
      )}
      <button type="button" className="menu-gallery-trigger" onClick={() => setOpen(true)}>
        Open demo dialog
      </button>
      <Dialog
        open={open}
        onOpenChange={setOpen}
        className="ui-glass ui-glass-floats dialog-gallery-glass"
        hostGlass={glass === "host"}
      >
        <DialogTitle className="dialog-gallery-title">Delete this chat?</DialogTitle>
        <DialogDescription className="dialog-gallery-description">
          Its messages and files go too. This cannot be undone.
        </DialogDescription>
        <button type="button" className="menu-gallery-trigger" onClick={() => setOpen(false)}>
          Cancel
        </button>
      </Dialog>
    </div>
  );
}

function DialogGallery({
  titled = false,
  alert = false,
  glass,
  busy,
}: {
  titled?: boolean;
  alert?: boolean;
  glass?: Glass;
  busy?: boolean;
}) {
  const [open, setOpen] = useState(false);
  if (glass) return <GlassDialog glass={glass} busy={busy} />;
  if (titled)
    return (
      <div className="menu-gallery-stage">
        <button type="button" className="menu-gallery-trigger" onClick={() => setOpen(true)}>
          Open demo dialog
        </button>
        <Dialog open={open} onOpenChange={setOpen} alert={alert} className="dialog-gallery-popup">
          <DialogTitle className="dialog-gallery-title">Delete this chat?</DialogTitle>
          <DialogDescription className="dialog-gallery-description">
            Its messages go too. VoiceOver reads this title as the name and this sentence as the description.
          </DialogDescription>
          <button type="button" className="menu-gallery-trigger" onClick={() => setOpen(false)}>
            Cancel
          </button>
        </Dialog>
      </div>
    );
  return (
    <div className="menu-gallery-stage">
      <button type="button" className="menu-gallery-trigger" onClick={() => setOpen(true)}>
        Open demo dialog
      </button>
      <Dialog open={open} onOpenChange={setOpen} label="Demo dialog" className="dialog-gallery-popup">
        <p>A modal dialog over the page: it and its backdrop fade in and out.</p>
        <button type="button" className="menu-gallery-trigger" onClick={() => setOpen(false)}>
          Close
        </button>
      </Dialog>
    </div>
  );
}

const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Open demo dialog" });
  await ctx.waitFor(() => ctx.find({ role: "dialog" }));
};

export default componentEntry({
  id: "ui.dialog",
  title: "Shared dialog primitive",
  area: "UI primitives",
  height: 360,
  widths: { narrow: 360, normal: 560, wide: 820 },
  covers: ["ui/Dialog.tsx#Dialog", "ui/Dialog.tsx#DialogTitle", "ui/Dialog.tsx#DialogDescription"],
  anchors: [{ selector: ".menu-gallery-trigger" }],
  load: async () => DialogGallery,
  styles: () =>
    Promise.all([
      import("./ui.css"),
      import("./popupSurface.css"),
      import("./Menu.gallery.css"),
      import("./Dialog.gallery.css"),
    ]),
  variants: {
    closed: { props: {} },
    open: { props: {}, play: open },
    titled: {
      props: { titled: true },
      play: open,
      note: "A visible DialogTitle and DialogDescription name and describe the dialog (aria-labelledby, aria-describedby).",
    },
    alert: {
      props: { titled: true, alert: true },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Open demo dialog" });
        await ctx.waitFor(() => ctx.find({ role: "alertdialog" }));
      },
      note: "alert: role alertdialog; a press outside does not dismiss it, Escape does.",
    },
    "glass-page": {
      props: { glass: "page" },
      play: open,
      note: "Shipped (the default): a glass dialog on the page's own sheet veil and blur, today's dialog.",
    },
    "glass-host": {
      props: { glass: "host" },
      play: open,
      note: "experiments.dialogGlass (off by default): the dialog on the App's own sheet glass under the page (data-host-glass, role sheet).",
    },
    "glass-host-busy": {
      props: { glass: "host", busy: true },
      play: open,
      note: "experiments.dialogGlass, over busy transcript text: the glass keeps the dialog legible.",
    },
  },
});
