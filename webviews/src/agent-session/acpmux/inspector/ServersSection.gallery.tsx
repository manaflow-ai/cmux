// l10n-allow-file: gallery fixtures (sample server commands), not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { ChatInspector, InspectorPanel } from "./ChatInspector";

type Props = { ports: number };

function ServerPorts({ ports }: Props) {
  const [opened, setOpened] = useState("");
  const [stopped, setStopped] = useState("");
  const command =
    "bun run dev --filter @atlas/customer-dashboard-with-local-service-proxies " +
    Array.from({ length: ports }, (_, index) => `--port ${3000 + index}`).join(" ");
  return (
    <div
      className="acpmux-shell"
      style={{ display: "flex", justifyContent: "flex-end", height: "100%" }}
      data-opened={opened}
      data-stopped={stopped}
    >
      <InspectorPanel width={260} placement="overlay">
        <ChatInspector
          machineName="Studio"
          processes={[{ id: "gallery-server", command, startedAt: minutesAgo(5), state: "running" }]}
          onOpenUrl={setOpened}
          onStopProcess={async (id) => setStopped(id)}
        />
      </InspectorPanel>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.session-info-server-ports",
  title: "Session Info server ports at minimum width",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 284, normal: 320 },
  covers: [
    "agent-session/acpmux/inspector/ServersSection.tsx",
    "agent-session/acpmux/inspector/inspector.css",
  ],
  load: async () => ServerPorts,
  variants: {
    "six-ports": {
      note: "A long development command exposing six local services in a 260px Session Info panel.",
      props: { ports: 6 },
    },
    "single-port": {
      note: "The same long command with one port, keeping the ordinary server row compact.",
      props: { ports: 1 },
    },
  },
});
