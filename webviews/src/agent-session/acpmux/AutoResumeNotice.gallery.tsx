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
    "rate-limited": {
      note: "acpmux holds the chat on its account's rate limit until 14:05 UTC: the notice says until when.",
      props: { state: { rateLimitedUntil: Date.UTC(2026, 10, 17, 14, 5) } },
    },
    "rate-limited-retry": {
      note: "A held chat whose failed turn also waits to retry: the hold's time reads, not the retry's count.",
      props: {
        state: {
          retry: { attempt: 1, of: 4, reason: "rate_limit" },
          rateLimitedUntil: Date.UTC(2026, 10, 17, 14, 5),
        },
      },
    },
    "rate-limit-retry": {
      note: "A retry after a rate limit with no hold.",
      props: { state: { retry: { attempt: 2, of: 4, reason: "rate_limit" } } },
    },
    cleared: { props: { state: undefined } },
  },
});
