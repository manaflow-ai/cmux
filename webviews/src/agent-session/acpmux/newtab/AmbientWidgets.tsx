// The New Tab page's ambient widgets (`tabs.newTabWidgets.weather|machines`, ambient.ts): one quiet
// row under the composer in the greeting's dim color. The row takes its own height below the field,
// so the field never moves when a widget turns on or a reading arrives.
import { Icon } from "../icons/Icon";
import { useEffect } from "react";
import { type CloudMachine, refreshCloudMachines, useCloudMachines } from "../cloudMachines";
import { environmentStateLabel } from "../EnvironmentPicker";
import { experimentArm } from "../../../experiments/experiment";
import { translate as t } from "../i18n";
import { linkWords, MachineLinkMark } from "../machineLink";
import type { AcpmuxSnapshot } from "../model";
import { PlusIcon } from "../ComposerPickers";
import { Tooltip } from "../../../ui/Tooltip";
import { degrees, machinePress, newTabMachines, type NewTabMachine, type NewTabWeather, weatherGlyph, weatherIsStale } from "./ambient";
import { newTabMachinesLook } from "./machinesLook.experiment";
import { useNt } from "./strings";

const MACHINE_ICONS = { local: "machine.mac", ssh: "machine.remote", cloud: "cloud" } as const;

/// What the machines' buttons do (NewTabScreen): pick a machine for the next chat, reconnect a down
/// one as it is picked, resume or open an account Cloud machine, and Add Machine… (`device.add`).
export type MachineButtons = {
  /// The machine the next chat starts on (`local`: this Mac); its button reads pressed.
  current: string;
  onPick(id: string): void;
  onReconnect(id: string): void;
  onCloudMachine(machine: CloudMachine): void;
  onAddMachine?(): void;
};

export function AmbientWidgets({
  weather,
  machines,
  snapshot,
  localName,
  now,
  buttons,
  cloudMachines,
}: {
  /// The weather widget's last reading; undefined draws no weather (off, or none yet).
  weather?: NewTabWeather;
  /// The machines widget is on.
  machines: boolean;
  snapshot: Pick<AcpmuxSnapshot, "sessions" | "peers" | "peerKinds" | "peerConnected" | "peerStates" | "peersUnlisted">;
  localName: string;
  now: number;
  /// The machines are buttons; without them they are the quiet labels they were.
  buttons?: MachineButtons;
  /// The account's Cloud machines (tests and the gallery); the page's shared list otherwise.
  cloudMachines?: readonly CloudMachine[];
}) {
  const nt = useNt();
  const accountMachines = useCloudMachines();
  // The account's Cloud machines are read once as the widget shows (no timer): a paused one shows
  // with its stage, and a press resumes it.
  const reads = machines && !!buttons && !cloudMachines;
  useEffect(() => {
    if (reads) void refreshCloudMachines();
  }, [reads]);
  const list = machines
    ? newTabMachines(snapshot, snapshot.peerKinds ?? {}, localName, cloudMachines ?? accountMachines)
    : [];
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
      {list.length > 0 &&
        (buttons ? (
          <MachineButtonRow list={list} buttons={buttons} />
        ) : (
          <section className="nt-ambient-machines" aria-label={nt("widgets.machines")}>
            {list.map((machine) => (
              <Tooltip
                key={machine.id}
                label={`${machine.label}: ${nt(machine.online ? "widgets.online" : "widgets.offline")}`}
              >
                <span className="nt-ambient-machine" data-online={machine.online || undefined}>
                  <MachineFace machine={machine} />
                  <span className="nt-ambient-dot" aria-hidden="true" />
                </span>
              </Tooltip>
            ))}
          </section>
        ))}
    </div>
  );
}

function MachineFace({ machine }: { machine: NewTabMachine }) {
  return (
    <>
      <span className="nt-ambient-machine-icon" style={machine.color ? { color: machine.color } : undefined}>
        <Icon name={MACHINE_ICONS[machine.kind]} size={14} />
      </span>
      <span className="nt-ambient-machine-name">{machine.label}</span>
    </>
  );
}

/// A press on a machine's button: a peer that is down reconnects and is picked (the send then waits
/// for its link), any other peer and this Mac are picked, an account Cloud machine resumes or opens,
/// and an older chat's host acpmux no longer lists does nothing.
export function pressMachine(machine: NewTabMachine, buttons: MachineButtons): void {
  switch (machinePress(machine)) {
    case "cloud":
      if (machine.cloudMachine) buttons.onCloudMachine(machine.cloudMachine);
      return;
    case "reconnect":
      buttons.onReconnect(machine.id);
      buttons.onPick(machine.id);
      return;
    case "pick":
      buttons.onPick(machine.id);
      return;
    case "none":
      return;
  }
}

/// A machine's state in words: its link's (Connected, Reconnecting, Not connected), a Cloud
/// machine's stage and what a press does (Paused · Resume), or nothing for this Mac.
function machineWords(machine: NewTabMachine): string | undefined {
  if (machine.cloudMachine) return environmentStateLabel({ ...machine, cloudMachine: machine.cloudMachine });
  if (machine.link) return linkWords(machine.link);
  if (machine.kind !== "local") return t("composer.envNotConnected");
  return undefined;
}

/// The machines as buttons (Leo, 2026-10-26: "buttons for connected cloud machines? and adding new
/// stuff ... the buttons should at least be displaying well and able to send you to the nicest
/// easiest places"): each with its live link (a dot, the spinner while it connects), a press that
/// starts the next chat there, and Add Machine… last. Each button highlights alone on hover.
function MachineButtonRow({ list, buttons }: { list: NewTabMachine[]; buttons: MachineButtons }) {
  const nt = useNt();
  const look = experimentArm(newTabMachinesLook);
  const press = (machine: NewTabMachine) => pressMachine(machine, buttons);
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a group of buttons, named for VoiceOver
    <div className="nt-machines" data-look={look} role="group" aria-label={nt("widgets.machines")}>
      {list.map((machine) => {
        const words = machineWords(machine);
        const inert = machinePress(machine) === "none";
        const label = words ? `${machine.label}: ${words}` : machine.label;
        return (
          <Tooltip key={machine.id} label={label}>
            <button
              type="button"
              className="nt-machine"
              data-machine={machine.id}
              data-link={machine.link}
              aria-label={label}
              aria-pressed={machine.cloudMachine ? undefined : buttons.current === machine.id}
              aria-disabled={inert || undefined}
              onClick={() => press(machine)}
            >
              <span className="nt-machine-face">
                <MachineFace machine={machine} />
                {machine.link && <MachineLinkMark link={machine.link} {...(words ? { words } : {})} />}
              </span>
              {look === "tiles" && <span className="nt-machine-state">{words ?? nt("widgets.online")}</span>}
            </button>
          </Tooltip>
        );
      })}
      {buttons.onAddMachine && (
        <button type="button" className="nt-machine nt-machine-add" data-machine-add onClick={buttons.onAddMachine}>
          <span className="nt-machine-face">
            <span className="nt-ambient-machine-icon" aria-hidden="true">
              <PlusIcon />
            </span>
            <span className="nt-ambient-machine-name">{t("composer.addMachine")}</span>
          </span>
        </button>
      )}
    </div>
  );
}
