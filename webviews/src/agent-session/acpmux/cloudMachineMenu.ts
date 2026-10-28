// Pause and Resume for a chat's Cloud machine, in the chat menu (cmuxterm-hq#4755: "Pause/resume
// with acpmux and the GUI chat"). A chat on one of the account's Cloud machines (the chat's peer,
// matched by name as the app matches a peer to a Cloud machine) offers Pause Machine while the
// machine runs, and Resume Machine while it is paused. Pausing while the chat's turn runs stops
// the turn first and says so in the row ("Stop and Pause Machine"): a paused machine freezes the
// turn mid-call, and a stopped turn ends on the chat's hand-off as stopped (acpmux reports it,
// daemon/cloud_handoff.rs) instead of reading as running while the machine sleeps.
import type { ChatMenuItem } from "./header/ChatHeaderTools";
import type { CloudMachine } from "./cloudMachines";
import type { Translate } from "./i18n";

type Call = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// The account's machine the chat runs on: a Cloud chat whose peer is one of the account's
/// machines by name (any case).
export function chatCloudMachine(
  summary: { peer?: unknown; host?: unknown; hostKind?: unknown } | undefined,
  machines: readonly CloudMachine[],
): CloudMachine | undefined {
  if (summary?.hostKind !== "cloud") return undefined;
  const name = typeof summary.peer === "string" && summary.peer ? summary.peer : summary.host;
  if (typeof name !== "string" || !name) return undefined;
  const lower = name.toLowerCase();
  return machines.find((machine) => machine.name.toLowerCase() === lower);
}

/// The menu rows for the chat's machine: Pause while it runs (stopping a running turn first),
/// Resume while it is paused, none while it starts, fails or is not one of the account's.
/// Each row's pick is the person's click (the app runs it only on a gesture); `after` reads the
/// account's list again so the next look shows the machine's new stage.
export function cloudMachineRows(
  machine: CloudMachine | undefined,
  working: boolean,
  t: Translate,
  call: Call,
  after: () => void,
): ChatMenuItem[] {
  if (!machine) return [];
  const run = (method: string) => () =>
    void (async () => {
      try {
        if (method === "cloudMachine.pause" && working) await call("chat.cancel");
        await call(method, { id: machine.id });
      } catch {
        // The app refused (no gesture, the machine moved on): the list read shows its stage.
      }
      after();
    })();
  if (machine.stage === "ready") {
    return [
      {
        key: "pauseMachine",
        label: t(working ? "chatMenu.stopAndPauseMachine" : "chatMenu.pauseMachine"),
        icon: "action.pause",
        onSelect: run("cloudMachine.pause"),
      },
    ];
  }
  if (machine.stage === "paused") {
    return [
      {
        key: "resumeMachine",
        label: t("chatMenu.resumeMachine"),
        icon: "action.resume",
        onSelect: run("cloudMachine.resume"),
      },
    ];
  }
  return [];
}
