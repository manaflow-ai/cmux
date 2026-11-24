import { useMemo } from "react";
import { useT } from "./i18n";
import { peerCloudMachine } from "./peerCloudMachine";
import { runCloudMachine, useCloudMachines, type CloudMachine } from "./cloudMachines";
import { postNative } from "./native";
import type { MachineResources } from "./machineResources";
import { machineCard, machineCardDot, type PickerCard } from "./machineCardModel";
import { MachineCard, WakeIcon } from "./MachineCard";
import { machineStatusWord } from "./machineCardText";

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
