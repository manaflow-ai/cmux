// l10n-allow-file: gallery fixtures (sample machine names), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { MissingChat } from "./MissingChat";

type Props = Parameters<typeof MissingChat>[0];

const act = () => undefined;

export default componentEntry<Props>({
  id: "agent-pane.missing-chat",
  title: "Chat isn't available",
  area: "Agent pane",
  height: 160,
  covers: ["agent-session/acpmux/MissingChat.tsx#MissingChat"],
  pane: true,
  load: () => import("./MissingChat").then((module) => module.MissingChat),
  variants: {
    "this-mac": {
      props: {
        session: "01a1201b-d3c3-7be1-8c40-1f1cbc87b8dc",
        machine: "Lawrence's MacBook Pro",
        onResume: act,
        onClose: act,
      },
      note: "Names the machine and session; Resume from Transcript opens All Chats",
    },
    "no-machine": { props: { session: "01a1201b-d3c3-7be1-8c40-1f1cbc87b8dc", onResume: act, onClose: act } },
  },
});
