// The New Tab page's ambient widgets (`tabs.newTabWidgets.weather|machines`, ambient.ts): one quiet
// row under the composer in the greeting's dim color. The row takes its own height below the field,
// so the field never moves when a widget turns on or a reading arrives.
import { useEffect } from "react";
import { cloudMachineAsleep, refreshCloudMachines, useCloudMachines, type CloudMachine } from "../cloudMachines";
import { Icon } from "../icons/Icon";
import type { AcpmuxSnapshot } from "../model";
import { Tooltip } from "../../../ui/Tooltip";
import { degrees, newTabMachines, type NewTabWeather, weatherGlyph, weatherIsStale } from "./ambient";
import { useNt } from "./strings";

const MACHINE_ICONS = { local: "machine.mac", ssh: "machine.remote", cloud: "cloud" } as const;

export function AmbientWidgets({
  weather,
  machines,
  snapshot,
  localName,
  now,
  cloudMachines,
}: {
  /// The weather widget's last reading; undefined draws no weather (off, or none yet).
  weather?: NewTabWeather;
  /// The machines widget is on.
  machines: boolean;
  snapshot: Pick<AcpmuxSnapshot, "sessions" | "peers" | "peerKinds" | "peerConnected" | "peerStates">;
  localName: string;
  now: number;
  /// Gallery seam; the app's Cloud account list (cloudMachines.ts) is used when omitted.
  cloudMachines?: readonly CloudMachine[];
}) {
  const nt = useNt();
  const list = machines ? newTabMachines(snapshot, snapshot.peerKinds ?? {}, localName) : [];
  // A Cloud machine acpmux has no link to may only be paused (Cloud machines pause on their own
  // when idle): the account's list says so, read once while such a machine is listed.
  const accountMachines = useCloudMachines();
  const shownMachines = cloudMachines ?? accountMachines;
  const asksAccount = !cloudMachines && list.some((machine) => machine.kind === "cloud" && !machine.online);
  useEffect(() => {
    if (asksAccount) void refreshCloudMachines();
  }, [asksAccount]);
  if (!weather && !list.length) return null;
  const stale = weather ? weatherIsStale(weather, now) : false;
  return (
    <div className="nt-ambient">
      {weather && (
        <Tooltip label={stale ? nt("widgets.weatherStale", { place: weather.place }) : weather.place}>
          <section className="nt-ambient-weather" aria-label={nt("widgets.weather")} data-stale={stale || undefined}>
            <span className="nt-ambient-glyph" aria-hidden="true">
              {weatherGlyph(weather.code)}
            </span>
            <span className="nt-ambient-temp">{degrees(weather.temperature)}</span>
            <span className="nt-ambient-range">
              {nt("widgets.weatherRange", { high: degrees(weather.high), low: degrees(weather.low) })}
            </span>
            <span className="nt-ambient-place">{weather.place}</span>
          </section>
        </Tooltip>
      )}
      {list.length > 0 && (
        <section className="nt-ambient-machines" aria-label={nt("widgets.machines")}>
          {list.map((machine) => {
            // A paused Cloud machine is a calm state, never "offline": its first use resumes it.
            const paused =
              machine.kind === "cloud" && !machine.online && cloudMachineAsleep(machine.label, shownMachines);
            const status = machine.online ? "widgets.online" : paused ? "widgets.paused" : "widgets.offline";
            return (
              <Tooltip key={machine.id} label={`${machine.label}: ${nt(status)}`}>
                <span
                  className="nt-ambient-machine"
                  data-online={machine.online || undefined}
                  data-paused={paused || undefined}
                >
                  <span
                    className="nt-ambient-machine-icon"
                    style={machine.color ? { color: machine.color } : undefined}
                  >
                    <Icon name={MACHINE_ICONS[machine.kind]} size={14} />
                  </span>
                  <span className="nt-ambient-machine-name">{machine.label}</span>
                  <span className="nt-ambient-dot" aria-hidden="true" />
                </span>
              </Tooltip>
            );
          })}
        </section>
      )}
    </div>
  );
}
