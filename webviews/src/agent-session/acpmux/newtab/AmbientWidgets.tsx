// The New Tab page's ambient widgets (`tabs.newTabWidgets.weather|machines`, ambient.ts): one quiet
// row under the composer in the greeting's dim color. The row takes its own height below the field,
// so the field never moves when a widget turns on or a reading arrives.
import { Icon } from "../icons/Icon";
import type { AcpmuxSnapshot } from "../model";
import { Tooltip } from "../../../ui/Tooltip";
import {
  degrees,
  newTabMachines,
  type NewTabWeather,
  type NewTabMachine,
  weatherGlyph,
  weatherIsStale,
} from "./ambient";
import { useNt } from "./strings";
import { translate as t } from "../i18n";

const MACHINE_ICONS = { local: "machine.mac", ssh: "machine.remote", cloud: "cloud" } as const;

export function AmbientWidgets({
  weather,
  machines,
  snapshot,
  localName,
  now,
  onAddMachine,
  onPickMachine,
}: {
  /// The weather widget's last reading; undefined draws no weather (off, or none yet).
  weather?: NewTabWeather;
  /// The machines widget is on.
  machines: boolean;
  snapshot: Pick<AcpmuxSnapshot, "sessions" | "peers" | "peerKinds" | "peerStatus" | "machines" | "peerConnected">;
  localName: string;
  now: number;
  onAddMachine?(kind: "pair" | "cloud"): void;
  onPickMachine?(machine: NewTabMachine): void;
}) {
  const nt = useNt();
  const list = machines ? newTabMachines(snapshot, snapshot.peerKinds ?? {}, localName) : [];
  const hasCloud = list.some((machine) => machine.kind === "cloud");
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
              key={`${machine.native ? "native" : "peer"}:${machine.id}`}
              label={
                machine.status
                  ? `${machine.label}: ${machineStateLabel(machine.status)}`
                  : machine.online === undefined
                    ? machine.label
                    : `${machine.label}: ${nt(machine.online ? "widgets.online" : "widgets.offline")}`
              }
            >
              <button
                type="button"
                className="nt-ambient-machine"
                data-online={machine.online || undefined}
                disabled={!onPickMachine}
                onClick={() => onPickMachine?.(machine)}
              >
                <span className="nt-ambient-machine-icon" style={machine.color ? { color: machine.color } : undefined}>
                  <Icon name={MACHINE_ICONS[machine.kind]} size={14} />
                </span>
                <span className="nt-ambient-machine-name">{machine.label}</span>
                {machine.status && (
                  <span className="nt-ambient-machine-state">{machineStateLabel(machine.status)}</span>
                )}
                <span className="nt-ambient-dot" aria-hidden="true" />
              </button>
            </Tooltip>
          ))}
          {onAddMachine && (
            <button
              type="button"
              className="nt-ambient-machine nt-ambient-machine-add"
              onClick={() => onAddMachine(hasCloud ? "pair" : "cloud")}
            >
              <span className="nt-ambient-machine-icon" aria-hidden="true">
                +
              </span>
              <span className="nt-ambient-machine-name">
                {hasCloud ? t("composer.add") : t("composer.newCloudMachine")}
              </span>
            </button>
          )}
        </section>
      )}
    </div>
  );
}

function machineStateLabel(status: NonNullable<import("./ambient").NewTabMachine["status"]>): string {
  switch (status) {
    case "connected":
      return t("composer.envConnected");
    case "connecting":
      return t("rail.connectorPending");
    case "paused":
      return t("goal.paused");
    case "offline":
      return t("composer.envOffline");
    case "unreachable":
      return t("composer.envUnreachable");
    case "needsUpdate":
      return t("composer.envNeedsUpdate");
    case "needsLogin":
      return t("composer.envNeedsLogin");
  }
}
