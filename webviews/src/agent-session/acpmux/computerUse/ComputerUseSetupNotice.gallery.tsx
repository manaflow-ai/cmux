// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { ComputerUseSetupNotice } from "./ComputerUseSetupNotice";
import type { ComputerUseHold } from "./computerUseState";

export default componentEntry<{ hold: ComputerUseHold }>({
  id: "agent-pane.computer-use-setup-notice",
  title: "Computer use setup notice",
  area: "Agent pane",
  pane: true,
  height: 120,
  widths: { narrow: 360, normal: 560, wide: 760 },
  covers: ["agent-session/acpmux/computerUse/ComputerUseSetupNotice.tsx#ComputerUseSetupNotice"],
  load: async () =>
    function GalleryComputerUseSetup(props: { hold: ComputerUseHold }) {
      return <ComputerUseSetupNotice hold={props.hold} onSetUp={() => undefined} onDismiss={() => undefined} />;
    },
  styles: () => import("../../../ui/notice.css"),
  variants: {
    "needs-setup": {
      note: "A send named @computer-use before Computer Use was set up: the message stays, Set Up Computer Use opens the onboarding step.",
      props: { hold: "setup" },
    },
    disabled: {
      note: "The organization turned Computer Use off: no setup button, only the reason and the dismiss.",
      props: { hold: "disabled" },
    },
    unavailable: {
      note: "This build has no cmux Remote (a dev build), or one of another version: no setup button, only the reason and the dismiss.",
      props: { hold: "unavailable" },
    },
    cloud: {
      note: "A send named @computer-use in a Cloud or Sandboxed chat, which has no Computer Use tools: only the reason and the dismiss.",
      props: { hold: "cloud" },
    },
    machine: {
      note: "A send named @computer-use in a chat on another machine (a peer, an SSH host): only the reason and the dismiss.",
      props: { hold: "machine" },
    },
  },
});
