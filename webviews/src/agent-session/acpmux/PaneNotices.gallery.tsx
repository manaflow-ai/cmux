// l10n-allow-file: gallery fixtures, not shipped UI.
//
// The app's peer-approvals notice above the composer (AgentPaneView+RemoteApprovals.swift) through
// a one-click Allow or Trust folder on a chat on another machine that has not enrolled this Mac
// (Leo, 2026-11-04: "it doesnt let me trust on click"): the click enrolls this Mac there and its
// answer goes again, so the notice only says so; it offers Enroll this Mac only when enrolling failed.
import { componentEntry } from "../../gallery/format";
import type { PaneNotice } from "./paneNoticeStore";

type Props = { notice: PaneNotice | undefined };

const peer = "devbox";

export default componentEntry<Props>({
  id: "agent-pane.peer-approvals-notice",
  title: "Peer approvals notice",
  area: "Agent pane",
  pane: true,
  height: 120,
  widths: { narrow: 360, normal: 560, wide: 760 },
  covers: ["agent-session/acpmux/PaneNotices.tsx#PaneNoticeCard"],
  load: async () => {
    const { PaneNoticeCard } = await import("./PaneNotices");
    return function GalleryPeerApprovalsNotice({ notice }: Props) {
      return <div className="acpmux-shell">{notice && <PaneNoticeCard notice={notice} onAction={() => {}} />}</div>;
    };
  },
  styles: () => import("./styles.css"),
  variants: {
    idle: {
      note: "Before any click: no notice. The Trust folder card answers on its own click.",
      props: { notice: undefined },
    },
    enrolling: {
      note: "After the click, while this Mac enrolls there: no button, the answer goes once it's done.",
      props: {
        notice: {
          id: "remoteApprovals",
          title: `Enrolling this Mac on ${peer}…`,
          detail: "Your answer goes as soon as it's done.",
        },
      },
    },
    "enroll-failed": {
      note: "Enrolling failed: the card shows the refusal, and the notice says why with Enroll this Mac.",
      props: {
        notice: {
          id: "remoteApprovals",
          title: `Enroll this Mac on ${peer} to allow from here`,
          detail: `Could not enroll this Mac on ${peer}: ssh: connect to host ${peer}: Operation timed out`,
          button: "Enroll this Mac",
          enabled: true,
        },
      },
    },
  },
});
