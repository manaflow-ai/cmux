// l10n-allow-file: gallery-only sample chat names, not shipped UI.
// The inline rename form (experiments.elevationLadder, RenameForm.tsx) open under the chat's name in
// the header, as a double-click on the name opens it with the switch on: the title, the one line under
// it and the Name field holding the name, selected, in a popover whose notch points at the name.
// Return here only closes the form: the gallery has no chat to rename.
import { useLayoutEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { ELEVATION_LADDER_ATTRIBUTE } from "../../../ui/elevationLadder";
import { RenameForm } from "./RenameForm";
import { ThreadTitle } from "./ThreadTitle";

type Props = { title: string };

function RenameFormGallery({ title }: Props) {
  const [name, setName] = useState<HTMLElement | null>(null);
  const [open, setOpen] = useState(true);
  useLayoutEffect(() => {
    document.documentElement.setAttribute(ELEVATION_LADDER_ATTRIBUTE, "");
    return () => document.documentElement.removeAttribute(ELEVATION_LADDER_ATTRIBUTE);
  }, []);
  return (
    <div className="acpmux-shell acpmux-thread-title-gallery">
      <header className="acpmux-header">
        <div
          className="acpmux-header-status-slot"
          ref={(node) => {
            const span = node?.querySelector<HTMLElement>(".acpmux-thread-title") ?? null;
            if (span !== name) setName(span);
          }}
        >
          <ThreadTitle title={title} onRename={() => setOpen(true)} />
        </div>
      </header>
      <RenameForm
        open={open && name !== null}
        anchor={name}
        title={title}
        onCommit={() => setOpen(false)}
        onCancel={() => setOpen(false)}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.rename-form",
  title: "Rename form",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 280,
  widths: { narrow: 360, normal: 520, wide: 760 },
  covers: ["agent-session/acpmux/header/RenameForm.tsx#RenameForm"],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./header.css"),
      import("../../../ui/controls.css"),
      import("./ThreadTitle.gallery.css"),
    ]),
  load: async () => RenameFormGallery,
  variants: {
    open: {
      note: "Open under the chat's name: Rename chat, one line on where the name shows, and the Name field with the name selected. The notch on the popover's top edge points at the name; Return saves, Escape or a press outside cancels.",
      props: { title: "Phone to computer connection" },
    },
    "long-name": {
      note: "A long name: the field scrolls inside its width and the popover keeps its size.",
      props: { title: "Measure the rail's first paint against the transcript's settle on a busy coordinator" },
    },
  },
});
