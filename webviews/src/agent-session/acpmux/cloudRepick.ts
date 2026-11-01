/// Another machine picked for a Cloud chat whose first send has not run (it failed, say "Claude is not
/// signed in here"): the app moves the chat to that machine and sends its first prompt again there
/// (`cloud.repickChat`, CmuxNextApp CloudStartChat+Repick), rather than the pick starting a new empty
/// chat through the machine the chat is on. Leo, 2026-10-31: he "picked zesty-indigo-lemur in the
/// machine picker, but the chat stayed on sr2-tunnel-probe (the location menu's top row and the tab
/// title still show sr2-tunnel-probe) and failed again".
import type { Environment } from "./environments";
import type { CloudMachine } from "./cloudMachines";

/// The picked machine as the app finds it: an account Cloud machine's id (a row acpmux does not list),
/// else the name acpmux lists it under.
export type RepickMachine = { machine: string } | { name: string };

/// The machine a pick of row `id` moves the chat to, when it is a Cloud machine other than the one the
/// chat is on (`current`); undefined for any other pick (this Mac, an SSH machine, an action row).
export function repickMachine(
  rows: readonly (Pick<Environment, "id" | "label" | "kind"> & { cloudMachine?: CloudMachine })[],
  id: string,
  current: string | undefined,
): RepickMachine | undefined {
  if (id === current) return undefined;
  const row = rows.find((environment) => environment.id === id);
  if (!row || row.kind !== "cloud") return undefined;
  return row.cloudMachine ? { machine: row.cloudMachine.id } : { name: row.label || row.id };
}

/// Asks the app to move the chat; true when it took the pick (moved, or ran the move and said why it
/// failed in its toast, `cloud_start_failed`), false for any refusal before it ran (not a chat a Cloud
/// start opened, no such machine, no gesture, an older app): the pick then does what it did before.
export async function repickCloudChat(
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  machine: RepickMachine,
): Promise<boolean> {
  try {
    await call("cloud.repickChat", machine);
    return true;
  } catch (error) {
    const code = (error as { code?: unknown } | null | undefined)?.code;
    return code === "cloud_start_failed";
  }
}
