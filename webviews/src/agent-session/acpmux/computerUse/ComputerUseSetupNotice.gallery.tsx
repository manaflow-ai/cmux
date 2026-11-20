// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { ComputerUseSetupNotice } from "./ComputerUseSetupNotice";

export default componentEntry<{ state: "needs_setup" | "disabled" }>({
  id: "agent-pane.computer-use-setup-notice",
  title: "Computer use setup notice",
  area: "Agent pane",
  pane: true,
  height: 120,
  widths: { narrow: 360, normal: 560, wide: 760 },
  covers: ["agent-session/acpmux/computerUse/ComputerUseSetupNotice.tsx#ComputerUseSetupNotice"],
  load: async () =>
    function GalleryComputerUseSetup(props: { state: "needs_setup" | "disabled" }) {
      return <ComputerUseSetupNotice state={props.state} onSetUp={() => undefined} onDismiss={() => undefined} />;
    },
  styles: () => import("../../../ui/notice.css"),
  variants: {
    "needs-setup": {
      note: "A send named @computer-use before Computer Use was set up: the message stays, Set Up Computer Use opens the onboarding step.",
      props: { state: "needs_setup" },
    },
    disabled: {
      note: "The organization turned Computer Use off: no setup button, only the reason and the dismiss.",
      props: { state: "disabled" },
    },
  },
});
