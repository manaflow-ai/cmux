// l10n-allow-file: gallery fixture labels, not shipped UI.
//
// Leo's Home (2026-11-19, his NIGHTLY, dark): one Needs you card for a tab an agent marked, the
// agent service's waiting line and the composer's Projects and This Mac pickers, from the shared
// scene (gallery/fixtures/HomeStateScene.tsx), which the golden scene draws too.
import { componentEntry } from "../../gallery/format";
import { HomeStateScene } from "../../gallery/fixtures/HomeStateScene";

type Props = { waitedMs?: number };

export default componentEntry<Props>({
  id: "agent-pane.home-state",
  title: "Home: Leo's Needs you card, service line and pickers",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 420, normal: 640, wide: 900 },
  anchors: [{ selector: ".home-state-scene" }],
  covers: ["agent-session/acpmux/HomeInbox.tsx#HomeInbox"],
  styles: () => import("./styles.css"),
  load: async () => HomeStateScene,
  variants: {
    leo: {
      note: "Leo's screenshot: one marked tab a day old, the agent service waited on for 0:26, ~/Projects on This Mac.",
      props: { waitedMs: 26_000 },
    },
  },
});
