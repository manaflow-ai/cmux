// l10n-allow-file: deterministic gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import { StuckBanner } from "./StuckBanner";

export default componentEntry({
  id: "agent-pane.stuck-banner",
  title: "Stuck agent attention",
  area: "Agent pane",
  pane: true,
  height: 240,
  widths: { narrow: 420, normal: 680, wide: 960 },
  covers: ["agent-session/acpmux/StuckBanner.tsx#StuckBanner"],
  styles: () => import("./styles.css"),
  load: async () => StuckBanner,
  variants: {
    baseline: {
      note: "Calm amber attention with a concise repeated-failure diagnosis and editable nudge.",
      props: { diagnosis: "Repeated cargo test -p acpmux 3 times; the same call keeps failing", onNudge: () => undefined },
    },
    "edit-cycle": {
      note: "The same fixed slot holds a longer apply/revert diagnosis without shifting the action.",
      props: { diagnosis: "Applied and reverted the same edit in auth.rs 2 times", onNudge: () => undefined },
    },
    "narrow-copy": {
      note: "A narrow diagnosis truncates in the fixed row while the nudge remains reachable.",
      props: {
        diagnosis: "Repeated cargo test --workspace --all-features --locked 3 times; the same call keeps failing",
        onNudge: () => undefined,
      },
    },
  },
});
