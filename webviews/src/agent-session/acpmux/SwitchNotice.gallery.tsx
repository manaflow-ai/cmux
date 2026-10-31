// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { SwitchNotice } from "./SwitchNotice";

type Props = { error: string; code?: string };

function GallerySwitchNotice({ error, code }: Props) {
  const [ran, setRan] = useState<string>();
  return (
    <div className="acpmux-shell" data-switch-notice-fixture data-ran={ran}>
      <SwitchNotice
        switching={{ harness: "claude", name: "Claude Code", phase: "failed", error, ...(code && { code }) }}
        onRetry={() => setRan("retry")}
        onAction={(action) => setRan(action)}
      />
    </div>
  );
}

const newMachine: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "New Cloud Machine" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Retry" }) !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.switch-notice",
  title: "Agent start refused",
  area: "Agent pane",
  height: 160,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-switch-notice-fixture]" }],
  covers: ["agent-session/acpmux/SwitchNotice.tsx#SwitchNotice"],
  styles: () => Promise.all([import("./styles.css"), import("./conversation/conversation.css")]).then(() => undefined),
  load: async () => GallerySwitchNotice,
  variants: {
    teammateMachine: {
      props: {
        error:
          "build-box is a teammate's machine, so its owner starts chats there. Pick your own machine, or create one with New Cloud Machine.",
        code: "agent_session.team_vm_blocked",
      },
      play: newMachine,
      note: "A teammate's machine: the person's own new machine is one click away, beside Retry.",
    },
    noFolder: {
      props: {
        error: "build-box has no work folder to start in. Use Choose folder to pick one there.",
        code: "app.folder_needed",
      },
      note: "No folder and no work folder on the machine (an older cmux-tui): Choose Folder… beside Retry.",
    },
    plain: {
      props: { error: "build-box did not start the agent in time. Try again." },
      note: "A refusal with no way out but trying again: Retry only, as before.",
    },
  },
});
