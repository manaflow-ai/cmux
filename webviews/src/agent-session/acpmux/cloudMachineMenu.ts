// Pause and Resume for a chat's Cloud machine, in the chat menu (cmuxterm-hq#4755: "Pause/resume
// with acpmux and the GUI chat"). A chat on one of the account's Cloud machines (the chat's peer,
// matched by name as the app matches a peer to a Cloud machine) offers Pause Machine while the
// machine runs, and Resume Machine while it is paused. Pausing while the chat's turn runs stops
// the turn first and says so in the row ("Stop and Pause Machine"): a paused machine freezes the
// turn mid-call, and a stopped turn ends on the chat's hand-off as stopped (acpmux reports it,
// daemon/cloud_handoff.rs) instead of reading as running while the machine sleeps. A stop
// request returns before the turn stops, so the pause waits for the turn to end
// (`StopWaiter`, on the chat's own turn state, not the working indicator a forced stop clears)
// and is not sent if the turn still runs after STOP_WAIT_MS, or if the pane shows another chat.
//
// Delete Machine… sits after them while the machine runs or is paused (Leo, 2026-11-08: "how would
// I be able to shut it down?"): it asks the app (`cloudMachine.delete`), which shows Kill Machine's
// own confirmation and deletes it only on the person's answer. A paused machine's rows start with
// what pausing means: opening the chat resumes it, and, when the server says so (`evictAt`), the
// date it is deleted unless it resumes, drawn as a warning within its last EVICT_WARN_MS.
import type { ChatMenuItem } from "./header/chatHeaderToolsModel";
import type { CloudMachine } from "./cloudMachines";
import { currentLanguage, type Translate } from "./i18n";

type Call = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// A paused machine's delete date within this long (7 days, in ms) is drawn as a warning.
export const EVICT_WARN_MS = 7 * 24 * 60 * 60 * 1000;

/// How long Stop and Pause waits for the chat's turn to end before it gives up on the pause.
export const STOP_WAIT_MS = 10_000;

/// Resolves waits for the chat's turn to end. The pane calls `changed` when its chat's state
/// changes; each wait also ends after its own timeout, so none outlives STOP_WAIT_MS.
export type StopWaiter = {
  /// The chat's state changed: each wait whose turn no longer runs resolves true.
  changed(): void;
  /// True once the turn ends (at once when `working()` is false), false after `ms`.
  wait(working: () => boolean, ms?: number): Promise<boolean>;
};

export function createStopWaiter(): StopWaiter {
  const waiting = new Set<() => void>();
  return {
    changed() {
      // A Set may lose its current entry while it is iterated (each wait removes itself).
      for (const check of waiting) check();
    },
    wait(working, ms = STOP_WAIT_MS) {
      if (!working()) return Promise.resolve(true);
      return new Promise((resolve) => {
        const finish = (stopped: boolean) => {
          clearTimeout(timer);
          waiting.delete(check);
          resolve(stopped);
        };
        const check = () => {
          if (!working()) finish(true);
        };
        const timer = setTimeout(() => finish(false), ms);
        waiting.add(check);
      });
    },
  };
}

/// The account's machine the chat runs on: a Cloud chat whose peer is one of the account's
/// machines by name (any case). Two machines of that name (names are not unique) give none:
/// a pause or resume must never land on the other one.
export function chatCloudMachine(
  summary: { peer?: unknown; host?: unknown; hostKind?: unknown } | undefined,
  machines: readonly CloudMachine[],
): CloudMachine | undefined {
  if (summary?.hostKind !== "cloud") return undefined;
  const names = new Set(
    [summary.peer, summary.host]
      .filter((name): name is string => typeof name === "string" && name !== "")
      .map((name) => name.toLowerCase()),
  );
  // Both the peer's and the host's name: exactly one of the account's machines, or none.
  const named = new Map(
    machines.filter((machine) => names.has(machine.name.toLowerCase())).map((machine) => [machine.id, machine]),
  );
  return named.size === 1 ? [...named.values()][0] : undefined;
}

/// The menu rows for the chat's machine: Pause while it runs (stopping a running turn first),
/// Resume while it is paused (after what pausing means, `pausedInfoRows`), Delete Machine… in
/// both, none while it starts, fails or is not one of the account's.
/// Each row's pick is the person's click (the app runs it only on a gesture); `after` reads the
/// account's list again so the next look shows the machine's new stage. `live` is the chat the
/// pane shows now and whether its turn runs, read at the pick (not when the menu was drawn);
/// `stopped(session)` resolves true once that chat's turn has ended after a stop (false: it still
/// runs, and nothing is paused).
export function cloudMachineRows(
  machine: CloudMachine | undefined,
  working: boolean,
  t: Translate,
  call: Call,
  after: (machine: CloudMachine) => void,
  live: () => { session: string | undefined; running: boolean },
  stopped: (session: string | undefined) => Promise<boolean>,
  /// The chat the menu was drawn for: a Pause picked once the pane shows another does nothing.
  drawnFor?: string,
  /// The time the paused rows count the delete date from (tests pass their own).
  now: number = Date.now(),
  /// Whether the pane still shows the chat the menu was drawn for: a row picked from a menu kept
  /// open across a chat switch runs nothing, so Delete never lands on another chat's machine.
  current: () => boolean = () => true,
): ChatMenuItem[] {
  if (!machine) return [];
  const run = (method: string) => () =>
    void (async () => {
      if (!current()) return;
      const { session, running } = live();
      try {
        if (method === "cloudMachine.pause" && (session === undefined || session !== drawnFor)) return;
        if (method === "cloudMachine.pause" && running) {
          await call("chat.cancel");
          // A paused machine would freeze a turn that has not stopped yet: no pause then.
          if (!(await stopped(session))) return;
        }
        // The pane moved to another chat meanwhile (this pick was for the one it left), or a
        // turn started again in it: no pause freezes it.
        // A Resume freezes nothing, and a paused machine's chat may show no live session.
        const before = live();
        if (method === "cloudMachine.pause" && (session === undefined || before.session !== session || before.running))
          return;
        // A stop awaited above may outlast a chat switch: check the chat again before the call.
        if (!current()) return;
        await call(method, { id: machine.id });
      } catch {
        // The app refused (no gesture, the machine moved on): the list read shows its stage.
      } finally {
        after(machine);
      }
    })();
  // The app asks before it deletes (Kill Machine's sheet); the row's ellipsis says so.
  const remove: ChatMenuItem = {
    key: "deleteMachine",
    label: t("chatMenu.deleteMachine"),
    icon: "action.delete",
    destructive: true,
    onSelect: run("cloudMachine.delete"),
  };
  if (machine.stage === "ready") {
    return [
      {
        key: "pauseMachine",
        label: t(working ? "chatMenu.stopAndPauseMachine" : "chatMenu.pauseMachine"),
        icon: "action.pause",
        onSelect: run("cloudMachine.pause"),
      },
      remove,
    ];
  }
  if (machine.stage === "paused") {
    return [
      ...pausedInfoRows(machine, t, now),
      {
        key: "resumeMachine",
        label: t("chatMenu.resumeMachine"),
        icon: "action.resume",
        onSelect: run("cloudMachine.resume"),
      },
      remove,
    ];
  }
  return [];
}

/// What a paused machine's pause means, as rows no click runs: opening the chat resumes it, and the
/// date the server deletes it unless it resumes (when the record carries `evictAt`), a warning
/// within EVICT_WARN_MS of it.
export function pausedInfoRows(machine: CloudMachine, t: Translate, now: number = Date.now()): ChatMenuItem[] {
  const rows: ChatMenuItem[] = [
    { key: "machinePaused", label: t("chatMenu.machinePausedInfo"), icon: "agent.paused", disabled: true },
  ];
  if (machine.evictAt !== undefined) {
    const language = currentLanguage() || globalThis.navigator?.language || "en";
    const date = new Intl.DateTimeFormat(language, { dateStyle: "medium" }).format(new Date(machine.evictAt));
    const soon = machine.evictAt - now <= EVICT_WARN_MS;
    rows.push({
      key: "machineEvicts",
      label: t("chatMenu.machineDeletedOn", { date }),
      icon: soon ? "status.warning" : "time.waiting",
      disabled: true,
      ...(soon ? { destructive: true } : {}),
    });
  }
  return rows;
}
