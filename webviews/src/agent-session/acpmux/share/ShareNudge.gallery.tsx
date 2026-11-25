// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { ShareNudgeLook } from "./ShareNudge";

type Props = { look: ShareNudgeLook; open: boolean };

export default componentEntry<Props>({
  id: "agent-pane.share-nudge",
  title: "Share nudge after the first reply",
  area: "Agent pane",
  pane: true,
  height: 120,
  widths: { narrow: 320, normal: 720, wide: 900 },
  covers: ["agent-session/acpmux/share/ShareNudge.tsx", "agent-session/acpmux/share/shareNudgeModel.ts"],
  load: async () => {
    const { ShareNudge } = await import("./ShareNudge");
    return function GalleryShareNudge({ look, open }: Props) {
      const none = () => {};
      return (
        <div className="acpmux-shell">
          <ShareNudge open={open} look={look} onShare={none} onInvite={none} onDismiss={none} />
        </div>
      );
    };
  },
  styles: () => import("../styles.css"),
  variants: {
    line: {
      note: "Shipped. One muted line over the composer, centered in the chat column, with Share…, Invite people… and an x. Quietest: no fill, no border, one row of height, and it lives in the notice slot, so errors and running steps draw first.",
      props: { look: "line", open: true },
    },
    card: {
      note: "Alternative: the harness notice's tinted card with a title over the line. Reads as a banner and doubles the height; too loud for a one-time hint.",
      props: { look: "card", open: true },
    },
    reply: {
      note: "Alternative: left-aligned in the transcript's text column, as if under the reply. Closer to the reply, but over the composer it reads as a stray transcript row, and drawing it inside the transcript would add a row the virtual list measures.",
      props: { look: "reply", open: true },
    },
    gone: { note: "Dismissed, used, or the moment passed: nothing draws.", props: { look: "line", open: false } },
  },
});
