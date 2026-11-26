// l10n-allow-file: gallery demo (made-up chat title), not shipped UI.
// The gallery's room strip (StripDemo.gallery.tsx): a chat header with the daemon's avatar strip
// and the activity line over the composer, as the pane draws them from one `_acpmux/room` note.
import { ActivityLine, StripStack } from "./Faces";
import type { RoomStrip } from "./roomStrip";

export type StripDemoProps = { strip: RoomStrip };

export function StripDemo({ strip }: StripDemoProps) {
  return (
    <div className="acpmux-root" style={{ padding: 16, display: "flex", flexDirection: "column", gap: 16 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <strong>Add retries to the uploader</strong>
        <StripStack strip={strip} />
      </div>
      <ActivityLine strip={strip} />
    </div>
  );
}
