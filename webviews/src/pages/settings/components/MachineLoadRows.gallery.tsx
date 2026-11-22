// l10n-allow-file: gallery fixtures (sample machine names), not shipped UI.
// Settings > Machines' rows with each machine's load line (ui/MachineLoadLine.tsx), drawn from the
// same fixtures as the composer's machine picker (agent-pane.machine-load-row): the two show the same
// numbers and verdict from acpmux's `peers[].load`. Idle, busy, offline and a long list.
import { componentEntry } from "../../../gallery/format";
import type { MachineLoad } from "../../../ui/machineLoad";
import { busyLoad, idleLoad, manyMachines, offlineLoad, threeMachines } from "../../../ui/machineLoad.fixtures";

type Props = { loads: Record<string, MachineLoad> };

async function load() {
  const { installCatalog } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { sayLoad } = await import("./HostSections");
  const { MachineLoadLine } = await import("../../../ui/MachineLoadLine");
  return function MachineLoadRows({ loads }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <section className="group" data-card="machines">
          <div className="rows">
            {Object.entries(loads).map(([name, row]) => (
              <div className="row" key={name} data-host-row={name}>
                <div className="row-main">
                  <span className="host-avatar" aria-hidden="true">
                    {name.slice(0, 1).toUpperCase()}
                  </span>
                  <div className="row-label">
                    <div className="row-title">{name}</div>
                    <div className="row-help">
                      <MachineLoadLine load={row} say={sayLoad} />
                    </div>
                  </div>
                </div>
              </div>
            ))}
          </div>
        </section>
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.machine-load-rows",
  title: "Settings > Machines load rows",
  area: "Settings",
  height: 420,
  widths: { narrow: 420, normal: 720 },
  covers: ["pages/settings/components/HostSections.tsx#MachinesSection"],
  load,
  styles: () => import("../page.css"),
  variants: {
    idle: { note: "A machine with room: its numbers, then 'room for 5'.", props: { loads: { "gcp-3": idleLoad } } },
    busy: {
      note: "A machine over its budget reads 'busy' in the warning colour.",
      props: { loads: { "build-box": busyLoad } },
    },
    offline: { note: "A machine that dropped: how long, no numbers.", props: { loads: { "old-laptop": offlineLoad } } },
    mixed: { note: "The same three machines the picker's mixed state lists.", props: { loads: threeMachines } },
    "many-machines": { note: "40 machines, one row each.", props: { loads: manyMachines(40) } },
  },
});
