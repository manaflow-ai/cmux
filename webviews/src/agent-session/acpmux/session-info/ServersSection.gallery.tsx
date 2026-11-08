// l10n-allow-file: gallery fixtures (sample server commands), not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { Play } from "../../../gallery/play";
import { SessionInfo, SessionInfoPanel } from "./SessionInfo";

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
      <SessionInfoPanel width={260} placement="overlay">
        <SessionInfo
          machineName="Studio"
          processes={[{ id: "gallery-server", command, startedAt: minutesAgo(5), state: "running" }]}
          onOpenUrl={setOpened}
          onStopProcess={async (id) => setStopped(id)}
        />
      </SessionInfoPanel>
    </div>
  );
}

const portsFit =
  (count: number): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-session-info-port").length === count);
    const line = ctx.find({ selector: ".acpmux-session-info-server__line" }).getBoundingClientRect();
    for (const port of ctx.document.querySelectorAll(".acpmux-session-info-port")) {
      const box = port.getBoundingClientRect();
      if (box.left < line.left - 0.5 || box.right > line.right + 0.5 || box.bottom > line.bottom + 0.5) {
        throw new Error(`Port ${port.textContent} extends outside the server detail line`);
      }
      const hit = ctx.document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
      if (!hit || !port.contains(hit)) throw new Error(`Port ${port.textContent} is covered or clipped`);
    }
  };

export default componentEntry<Props>({
  id: "agent-pane.session-info-server-ports",
  title: "Session Info server ports at minimum width",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 284, normal: 320 },
  covers: ["agent-session/acpmux/session-info/ServersSection.tsx", "agent-session/acpmux/session-info/sessionInfo.css"],
  load: async () => ServerPorts,
  variants: {
    "six-ports": {
      note: "A long development command exposing six local services in a 260px Session Info panel.",
      props: { ports: 6 },
      play: portsFit(6),
    },
    "single-port": {
      note: "The same long command with one port, keeping the ordinary server row compact.",
      props: { ports: 1 },
      play: portsFit(1),
    },
  },
});
