// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { AutoResumeStatus } from "./autoResumeStatus";

type Props = { state: AutoResumeStatus | undefined };

export default componentEntry<Props>({
  id: "agent-pane.auto-resume",
  title: "Automatic turn recovery",
  area: "Agent pane",
  pane: true,
  height: 100,
  widths: { narrow: 320, normal: 720, wide: 900 },
  covers: ["agent-session/acpmux/AutoResumeNotice.tsx"],
  load: async () => {
    const { AutoResumeNotice } = await import("./AutoResumeNotice");
    return function GalleryAutoResume({ state }: Props) {
      return (
        <div className="acpmux-shell">
          <AutoResumeNotice state={state} />
        </div>
      );
    };
  },
  styles: () => import("./styles.css"),
  variants: {
    "capacity-wait": { props: { state: { retry: { attempt: 1, of: 4, reason: "capacity" } } } },
    "connection-wait": {
      props: { state: { retry: { attempt: 2, of: 4, reason: "transport" }, attempt: 1 } },
    },
    resumed: { props: { state: { attempt: 2 } } },
    cleared: { props: { state: undefined } },
  },
});
