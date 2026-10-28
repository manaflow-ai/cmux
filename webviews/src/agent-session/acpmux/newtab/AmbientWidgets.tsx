// The New Tab page's ambient widgets (`tabs.newTabWidgets.weather|machines`, ambient.ts): one quiet
// row under the composer in the greeting's dim color. The row takes its own height below the field,
// so the field never moves when a widget turns on or a reading arrives.
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
}: {
  /// The weather widget's last reading; undefined draws no weather (off, or none yet).
  weather?: NewTabWeather;
  /// The machines widget is on.
  machines: boolean;
  snapshot: Pick<AcpmuxSnapshot, "sessions" | "peers" | "peerKinds">;
  localName: string;
  now: number;
}) {
  const nt = useNt();
  const list = machines ? newTabMachines(snapshot, snapshot.peerKinds ?? {}, localName) : [];
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
          {list.map((machine) => (
            <Tooltip
              key={machine.id}
              label={`${machine.label}: ${nt(machine.online ? "widgets.online" : "widgets.offline")}`}
            >
              <span className="nt-ambient-machine" data-online={machine.online || undefined}>
                <span className="nt-ambient-machine-icon" style={machine.color ? { color: machine.color } : undefined}>
                  <Icon name={MACHINE_ICONS[machine.kind]} size={14} />
                </span>
                <span className="nt-ambient-machine-name">{machine.label}</span>
                <span className="nt-ambient-dot" aria-hidden="true" />
              </span>
            </Tooltip>
          ))}
        </section>
      )}
    </div>
  );
}
