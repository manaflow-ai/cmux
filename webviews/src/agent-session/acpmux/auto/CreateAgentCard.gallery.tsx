// l10n-allow-file: gallery captions and the static stand-in for RFD 0078's button, not shipped copy.
//
// RFD 0080 "The create flow": the create card has no machine field. AUTO chooses the computer beside
// the model's first answer; the place button is RFD 0078's.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { CreateAgentCard } from "./CreateAgentCard";

type Props = { task: string };

const noop = () => undefined;

function Card({ task: initial }: Props) {
  const [task, setTask] = useState(initial);
  return (
    <div className="auto-computer-board">
      <CreateAgentCard
        task={task}
        project="cmux"
        agent="Claude"
        placeButton={
          <button type="button" className="auto-computer-place">
            Hybrid <span aria-hidden="true">▾</span>
          </button>
        }
        onTask={setTask}
        onProject={noop}
        onAgent={noop}
        onStart={noop}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.auto-create-card",
  title: "AUTO computer: create card",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/auto/CreateAgentCard.tsx#CreateAgentCard"],
  styles: () =>
    Promise.all([
      import("../../../ui/ghost.css"),
      import("../styles.css"),
      import("./computerAuto.css"),
      import("./AutoComputer.gallery.css"),
    ]),
  load: async () => Card,
  widths: { normal: 560 },
  height: 200,
  anchors: [{ selector: ".acpmux-create-card" }],
  variants: {
    filled: {
      note: "A task typed: Start is ready. No machine field.",
      props: { task: "Fix the login redirect loop on Safari" },
    },
    empty: { note: "Empty: Start waits.", props: { task: "" } },
  },
});
