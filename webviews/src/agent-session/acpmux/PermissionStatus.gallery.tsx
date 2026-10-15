// l10n-allow-file: gallery fixture labels describe the visible permission state.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { PermissionStatus } from "./PermissionStatus";

function GalleryPermissionStatus() {
  const [trusted, setTrusted] = useState(true);
  const [chatAllowed, setChatAllowed] = useState(true);
  return (
    <div className="acpmux-composer-gallery-shell acpmux-permission-status-gallery">
      <div className="acpmux-composer-bar">
        <PermissionStatus
          trusted={trusted}
          chatAllowed={chatAllowed}
          onUndoTrust={() => setTrusted(false)}
          onRevoke={() => setChatAllowed(false)}
        />
      </div>
    </div>
  );
}

const openStatus: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Allow for this chat" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]') !== null);
  ctx.find({ role: "menuitem", name: "Revoke" });
  ctx.find({ role: "menuitem", name: "Undo" });
  await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
};

export default componentEntry<Record<string, never>>({
  id: "agent-pane.permission-status",
  title: "Granted permission status",
  area: "Agent pane",
  pane: true,
  height: 150,
  widths: { narrow: 400, normal: 640, wide: 860 },
  anchors: [{ selector: ".acpmux-permission-status-trigger" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Opening the status menu must not move the composer footer." },
    layoutShiftMax: { value: 0, reason: "Granted state is a portal menu, not a new transcript row." },
    longFrameFailMs: { value: 33, reason: "The compact status menu should open without a long frame." },
  },
  covers: ["agent-session/acpmux/PermissionStatus.tsx#PermissionStatus"],
  load: async () => GalleryPermissionStatus,
  styles: () => Promise.all([import("./styles.css"), import("./composerLocation.css")]),
  variants: {
    granted: { props: {}, play: openStatus },
  },
});
