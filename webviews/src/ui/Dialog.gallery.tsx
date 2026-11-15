// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Dialog, DialogDescription, DialogTitle } from "./Dialog";

function DialogGallery({ titled = false, alert = false }: { titled?: boolean; alert?: boolean }) {
  const [open, setOpen] = useState(false);
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
  },
});
