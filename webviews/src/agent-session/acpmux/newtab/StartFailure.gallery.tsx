// l10n-allow-file: gallery fixtures use sample start errors.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { StartFailure } from "./StartFailure";

const base = {
  name: "Claude Code",
  onInstall: () => undefined,
  onDismiss: () => undefined,
};

const details: Play = async (ctx) => {
  await ctx.click({ text: "Details" });
};

export default componentEntry({
  id: "agent-pane.newtab-start-failure",
  title: "New Tab start failure",
  area: "Agent pane",
  covers: ["agent-session/acpmux/newtab/StartFailure.tsx#StartFailure"],
  load: () => Promise.resolve(StartFailure),
  styles: () => import("../styles.css"),
  widths: { narrow: 360, normal: 520, wide: 720 },
  height: 56,
  anchors: [{ selector: ".acpmux-start-failure" }],
  variants: {
    "not-installed": {
      note: "No Claude Code on this Mac: plain words, Install (Agents setup, then the draft sends), Retry and Dismiss.",
      props: {
        ...base,
        failure: { harness: "claude", error: "spawn claude-agent-acp ENOENT", local: true, retry: () => undefined },
      },
    },
    "not-installed-elsewhere": {
      note: "Not installed on another machine: no Install here, which would install on this Mac.",
      props: {
        ...base,
        failure: { harness: "claude", error: "claude: command not found", local: false, retry: () => undefined },
      },
    },
    unreachable: {
      note: "Any other failure reads as a failed turn does, with the raw words under Details.",
      props: {
        ...base,
        failure: {
          harness: "claude",
          error: "connect ECONNREFUSED 127.0.0.1:4317",
          local: true,
          retry: () => undefined,
        },
      },
      play: details,
    },
    "open-refused": {
      note: "A recent chat that would not open: the host's words, Retry and Dismiss.",
      props: { ...base, failure: { error: "Machine unavailable", local: true, retry: () => undefined } },
    },
  },
});
