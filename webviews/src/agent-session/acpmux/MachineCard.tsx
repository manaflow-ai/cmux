// The machine card of a chat on a Cloud machine: the location chip's popover opens on it
// (EnvironmentPicker `card`), over Continue on. It names the machine and its size, says whether it
// is awake, and shows its last load and memory reading; asleep, it offers Wake machine instead.
// What it reads is machineCardModel.ts's; it reads nothing itself and runs no timer: the readings
// are acpmux's cached one-minute health of the machine, which the open picker already asks for again
// while it stays open (environmentPickerModel.ts useMachineRefresh).
//
// References: claude/live/usage-status-popover and claude/live/sidebar-usage-limits-card (labelled
// rows, the number at the end, a thin bar under each; this pane's PlanUsageCard rows and bar, reused
// as is), cursor/web/local-cloud-handoff-control (the chip's own menu is where the chat goes next,
// so Continue on is that menu's list), chatgpt/live/sidebar-machine-details-hover-card (the machine
// and its status dot together at the top) and claude/live/sidebar-project-groups-status-dots (a
// dot, words only where there is something to read).
import { useMemo } from "react";
import { Spinner } from "./conversation/icons";
import { useT, type Translate } from "./i18n";
import { peerCloudMachine } from "./peerCloudMachine";
import { runCloudMachine, useCloudMachines, type CloudMachine } from "./cloudMachines";
import { postNative } from "./native";
import type { MachineResources } from "./machineResources";
import {
  machineCard,
  machineCardDot,
  type MachineCardModel,
  type MachineCardStatus,
  type PickerCard,
} from "./machineCardModel";
import "./planUsageCard.css";
import "./machineCard.css";

/// The status's word: Awake and Asleep, as the person says it of a machine.
export function machineStatusWord(status: MachineCardStatus, t: Translate): string {
  switch (status) {
    case "awake":
      return t("machineCard.awake");
    case "paused":
      return t("machineCard.asleep");
    case "starting":
      return t("machineCard.waking");
    case "failed":
      return t("machineCard.failed");
  }
}

const formatNumber = (value: number) =>
  value.toLocaleString(globalThis.document?.documentElement?.lang || undefined, { maximumFractionDigits: 1 });

/// "4 vCPU · 16 GB · 64 GB disk", or as much of it as the record says.
export function machineSpecsText(specs: MachineCardModel["specs"], t: Translate): string | undefined {
  if (!specs) return undefined;
  const parts = [
    specs.cpu !== undefined ? t("machineCard.specCpu", { n: formatNumber(specs.cpu) }) : undefined,
    specs.memoryGB !== undefined ? t("machineCard.specMemory", { n: formatNumber(specs.memoryGB) }) : undefined,
    specs.diskGB !== undefined ? t("machineCard.specDisk", { n: formatNumber(specs.diskGB) }) : undefined,
  ].filter((part): part is string => part !== undefined);
  return parts.length > 0 ? parts.join(" · ") : undefined;
}

/// The card itself, from its model. No control of its own: its rows are the picker's (keyboard and
/// pointer as every other row), so it is a labelled group of text and meters.
export function MachineCard({ model }: { model: MachineCardModel }) {
  const t = useT();
  const specs = machineSpecsText(model.specs, t);
  const { usage } = model;
  return (
    <section className="acpmux-machine-card" aria-label={t("machineCard.label")} data-status={model.status}>
      <div className="acpmux-machine-card-head">
        <div className="acpmux-machine-card-title">
          <span className="acpmux-machine-card-name">{model.name}</span>
          {specs && <span className="acpmux-machine-card-specs">{specs}</span>}
        </div>
        {model.status && (
          <span className="acpmux-machine-card-status" data-status={model.status}>
            <span className="acpmux-machine-card-mark" aria-hidden="true">
              {model.status === "starting" ? (
                <Spinner size={12} loading className="acpmux-machine-card-spinner" />
              ) : (
                <span className="acpmux-machine-card-dot" />
              )}
            </span>
            {machineStatusWord(model.status, t)}
          </span>
        )}
      </div>
      {usage.kind === "readings" && (
        <ul className="acpmux-plan-usage-rows acpmux-machine-card-usage">
          {usage.load && (
            <UsageRow
              name={t("machineCard.load")}
              value={t("machineCard.loadValue", {
                load: formatNumber(usage.load.load),
                cores: formatNumber(usage.load.cores),
              })}
              fraction={usage.load.fraction}
            />
          )}
          {usage.memory && (
            <UsageRow
              name={t("machineCard.memory")}
              value={
                usage.memory.totalGB !== undefined
                  ? t("machineCard.memoryFreeOf", {
                      free: formatNumber(usage.memory.freeGB),
                      total: formatNumber(usage.memory.totalGB),
                    })
                  : t("machineCard.memoryFree", { free: formatNumber(usage.memory.freeGB) })
              }
              fraction={usage.memory.fraction}
            />
          )}
        </ul>
      )}
      {usage.kind === "unread" && <p className="acpmux-machine-card-note">{t("machineCard.usageUnread")}</p>}
    </section>
  );
}

function UsageRow({ name, value, fraction }: { name: string; value: string; fraction: number | undefined }) {
  return (
    <li className="acpmux-plan-usage-window">
      <div className="acpmux-plan-usage-row">
        <span className="acpmux-plan-usage-name">{name}</span>
        <span className="acpmux-plan-usage-value">{value}</span>
      </div>
      {fraction !== undefined && (
        <progress
          className="acpmux-plan-usage-bar"
          aria-label={name}
          aria-valuetext={value}
          value={Math.round(fraction * 100)}
          max={100}
        />
      )}
    </li>
  );
}

/// The Wake machine row's mark: a play triangle, in the env rows' icon box.
export function WakeIcon() {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon acpmux-env-icon ui-ghost-icon"
      data-kind="wake"
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M5 3.5v9l7.5-4.5z" />
    </svg>
  );
}

/// The chip's machine, as ComposerContext knows it (its `Computer` row).
export type MachineCardComputer = {
  id: string;
  label: string;
  kind: string;
  connected?: boolean;
  resources?: MachineResources;
  cloudMachine?: CloudMachine;
};

type Call = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// The card and chip dot for a started chat on a Cloud machine (`computer`), nothing for any other
/// chat. The account's record of the machine is its own row's, else the one named as the chat's
/// peer (peerCloudMachine: one machine of that name, never a guess between two). Wake machine runs
/// the app's Resume for that machine (`cloudMachine.resume`, the `cloudResumeMachine` action, on the
/// row's own click), and the list shows it waking at once (runCloudMachine).
export function useMachineCard(
  computer: MachineCardComputer | undefined,
  enabled: boolean,
  call: Call = postNative,
): { card?: PickerCard; dot?: { live: boolean; sleep?: "paused" | "resuming"; words: string } } {
  const t = useT();
  const machines = useCloudMachines();
  const cloud = enabled && computer?.kind === "cloud" ? computer : undefined;
  const machine = cloud
    ? (cloud.cloudMachine ?? peerCloudMachine(machines, cloud.id) ?? peerCloudMachine(machines, cloud.label))
    : undefined;
  const model = useMemo(
    () =>
      cloud
        ? machineCard({
            name: cloud.label,
            ...(machine ? { machine } : {}),
            ...(cloud.connected !== undefined ? { connected: cloud.connected } : {}),
            ...(cloud.resources ? { resources: cloud.resources } : {}),
          })
        : undefined,
    [cloud, machine],
  );
  if (!model) return {};
  const dot = machineCardDot(model.status);
  const wake =
    machine && model.status === "paused"
      ? [
          {
            id: "wake",
            text: t("machineCard.wake"),
            icon: <WakeIcon />,
            run: () => void runCloudMachine(machine, call),
          },
        ]
      : [];
  return {
    card: { header: <MachineCard model={model} />, actions: wake, continueOn: t("machineCard.continueOn") },
    ...(dot && model.status ? { dot: { ...dot, words: machineStatusWord(model.status, t) } } : {}),
  };
}
