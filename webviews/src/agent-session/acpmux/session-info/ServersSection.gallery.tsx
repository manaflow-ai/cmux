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

/// A server is one Background tasks row (ServersSection.tsx): the globe, the first port's address,
/// then the command in grey, cut to the row. The address stays whole and in view; the command ends
/// before the time.
const portsFit =
  (count: number): Play =>
  async (ctx) => {
    const row = '.acpmux-session-info-task--command[data-kind="server"]';
    await ctx.waitFor(() => ctx.document.querySelector(`${row} .acpmux-session-info-task__address`));
    const box = ctx.find({ selector: row }).getBoundingClientRect();
    const address = ctx.find({ selector: `${row} .acpmux-session-info-task__address` });
    if (address.textContent !== "localhost:3000") throw new Error(`The row names ${address.textContent}`);
    const own = address.getBoundingClientRect();
    if (own.left < box.left - 0.5 || own.right > box.right + 0.5) throw new Error("The address leaves its row");
    const hit = ctx.document.elementFromPoint(own.left + own.width / 2, own.top + own.height / 2);
    if (!hit || !address.contains(hit)) throw new Error("The address is covered or clipped");
    const command = ctx.find({ selector: `${row} .acpmux-session-info-task__command` }).getBoundingClientRect();
    const time = ctx.find({ selector: `${row} .acpmux-session-info-task__time` }).getBoundingClientRect();
    if (command.right > time.left + 0.5) throw new Error("The command runs under the time");
    // One row, whatever the number of ports the command names.
    if (ctx.document.querySelectorAll(row).length !== 1) throw new Error(`${count} ports drew more than one row`);
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
      note: "A long development command exposing six local services in a 260px Session Info panel: one Background tasks row with the first address, the command cut before the time.",
      props: { ports: 6 },
      play: portsFit(6),
    },
    "single-port": {
      note: "The same long command with one port: the same one row.",
      props: { ports: 1 },
      play: portsFit(1),
    },
  },
});
