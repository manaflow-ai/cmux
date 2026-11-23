import { componentEntry } from "../../gallery/format";
import { OpenAppCard } from "./OpenAppCard";
import type { CloudPreviewPort } from "./cloudPreviewPorts";
import { translate } from "./i18n";

const VITE: readonly CloudPreviewPort[] = [{ port: 3000, process: "vite" }];

function OpenAppCardGallery({ ports = VITE }: { ports?: readonly CloudPreviewPort[] }) {
  return (
    <div className="acpmux-stage" style={{ minHeight: 120, paddingTop: 24 }}>
      <OpenAppCard enabled ports={ports} onOpen={() => undefined} />
    </div>
  );
}

export default componentEntry({
  id: "agent-pane.cloud-open-app-card",
  title: translate("cloudPreview.openApp"),
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/OpenAppCard.tsx#OpenAppCard"],
  styles: () => import("./styles.css"),
  load: async () => OpenAppCardGallery,
  widths: { narrow: 400, normal: 620 },
  height: 180,
  variants: {
    vite: {
      note: "A newly discovered Cloud dev server appears inline with its port and process.",
      props: {},
    },
    ownMachine: {
      note: "A dev server a chat started on an own machine (joined by sign-in): its daemon names the port and program (machine_ports.rs).",
      props: { ports: [{ port: 5173, process: "node" }] },
    },
    ownMachineTwo: {
      note: "Two servers opened during one turn on an own machine: one card each, in port order.",
      props: {
        ports: [
          { port: 5173, process: "node" },
          { port: 8000, process: "python3" },
        ],
      },
    },
    ownMachineUnnamed: {
      note: "A listener the machine's table does not name a program for (another user's, or an unprivileged ss): the port alone.",
      props: { ports: [{ port: 8080 }] },
    },
  },
});
