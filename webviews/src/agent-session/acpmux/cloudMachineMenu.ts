// Pause and Resume for a chat's Cloud machine, in the chat menu (cmuxterm-hq#4755: "Pause/resume
// with acpmux and the GUI chat"). A chat on one of the account's Cloud machines (the chat's peer,
// matched by name as the app matches a peer to a Cloud machine) offers Pause Machine while the
// machine runs, and Resume Machine while it is paused. Pausing while the chat's turn runs stops
// the turn first and says so in the row ("Stop and Pause Machine"): a paused machine freezes the
// turn mid-call, and a stopped turn ends on the chat's hand-off as stopped (acpmux reports it,
// daemon/cloud_handoff.rs) instead of reading as running while the machine sleeps. A stop
// request returns before the turn stops, so the pause waits for the turn to end
// (`StopWaiter`) and is not sent if the turn still runs after STOP_WAIT_MS.
import type { ChatMenuItem } from "./header/ChatHeaderTools";
import type { CloudMachine } from "./cloudMachines";
import type { Translate } from "./i18n";

type Call = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// How long Stop and Pause waits for the chat's turn to end before it gives up on the pause.
export const STOP_WAIT_MS = 10_000;

/// Resolves waits for the chat's turn to end. The pane calls `ended` when its turn is no longer
/// running; each wait also ends after its own timeout, so none outlives STOP_WAIT_MS.
export type StopWaiter = {
  /// The chat's turn is no longer running: every wait resolves true.
  ended(): void;
  /// True once the turn ends (at once when `working()` is false), false after `ms`.
  wait(working: () => boolean, ms?: number): Promise<boolean>;
};

export function createStopWaiter(): StopWaiter {
  const waiting = new Set<() => void>();
  return {
    ended() {
      // A Set may lose its current entry while it is iterated (each wait removes itself).
      for (const done of waiting) done();
    },
    wait(working, ms = STOP_WAIT_MS) {
      if (!working()) return Promise.resolve(true);
      return new Promise((resolve) => {
        const finish = (stopped: boolean) => {
          clearTimeout(timer);
          waiting.delete(onEnded);
          resolve(stopped);
        };
        const onEnded = () => finish(true);
        const timer = setTimeout(() => finish(false), ms);
        waiting.add(onEnded);
      });
    },
  };
}

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
/// account's list again so the next look shows the machine's new stage. `stopped` resolves true
/// once the chat's turn has ended after a stop (false: it still runs, and nothing is paused).
export function cloudMachineRows(
  machine: CloudMachine | undefined,
  working: boolean,
  t: Translate,
  call: Call,
  after: (machine: CloudMachine) => void,
  stopped: () => Promise<boolean>,
): ChatMenuItem[] {
  if (!machine) return [];
  const run = (method: string) => () =>
    void (async () => {
      try {
        if (method === "cloudMachine.pause" && working) {
          await call("chat.cancel");
          // A paused machine would freeze a turn that has not stopped yet: no pause then.
          if (!(await stopped())) return;
        }
        await call(method, { id: machine.id });
      } catch {
        // The app refused (no gesture, the machine moved on): the list read shows its stage.
      } finally {
        after(machine);
      }
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
