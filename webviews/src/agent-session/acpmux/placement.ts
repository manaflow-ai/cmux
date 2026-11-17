// Where a new chat should go, as acpmux's placement engine says it (`_acpmux/place`, acpmux
// placement.rs; design/remote-spin-up.md 2.3): the Where menu's Auto row, Remote's remembered
// machine and the "This Mac is busy" chip read it. The host relay cuts the reply to these fields
// (AcpmuxPaneMethods+ReplyShapes.swift): never another machine's numbers.
import { type Environment, environmentReady } from "./environments";
import { activityTime, type AcpmuxSessionEntry } from "./sessionList";

/// `pick`: the machine placement chose (acpmux's own name for this one when `local`). `room`: how
/// many more chats it has room for, when its reading says. `overloaded`: no machine had room and the
/// pick takes it anyway. `localOver`: why this machine is over its budget ("over its budget (load1
/// 29.8 >= 15)"), absent while it is not.
export type Placement = {
  pick?: string;
  local: boolean;
  overloaded: boolean;
  room?: number;
  localOver?: string;
};

/// The relay's filtered `_acpmux/place` reply as a Placement; nothing for a reply that is not one
/// (an older daemon or host refusing the method answers with an error instead, read as none).
export function placementFromReply(reply: unknown): Placement | undefined {
  if (!reply || typeof reply !== "object" || Array.isArray(reply)) return undefined;
  const value = reply as Record<string, unknown>;
  const pick = typeof value.pick === "string" && value.pick ? value.pick : undefined;
  const room =
    typeof value.room === "number" && Number.isFinite(value.room) && value.room >= 0
      ? Math.floor(value.room)
      : undefined;
  const localOver = typeof value.localOver === "string" && value.localOver ? value.localOver : undefined;
  return {
    ...(pick ? { pick } : {}),
    local: value.local === true,
    overloaded: value.overloaded === true,
    ...(room !== undefined ? { room } : {}),
    ...(localOver ? { localOver } : {}),
  };
}

/// The machine a placement names, as a row of the composer's machines: `local` for this one, else
/// the listed machine of that name a chat can start on now. None when the pick is no such machine.
function pickedEnvironment(placement: Placement, environments: readonly Environment[]): Environment | undefined {
  if (placement.local) return environments.find((environment) => environment.kind === "local");
  if (!placement.pick) return undefined;
  const machine = environments.find((environment) => environment.id === placement.pick);
  return machine && machine.kind !== "local" && environmentReady(machine) ? machine : undefined;
}

/// The Where menu's Auto row: the machine it starts the chat on and how much room it has. None
/// without a placement answer or with no machine placement can use; never a pick of a machine
/// already full (every host over its budget: Auto has nothing better than This Mac to offer).
export function autoChoice(
  placement: Placement | undefined,
  environments: readonly Environment[],
): { id: string; label: string; local: boolean; room?: number } | undefined {
  if (!placement || placement.overloaded) return undefined;
  const machine = pickedEnvironment(placement, environments);
  if (!machine) return undefined;
  return {
    id: machine.id,
    label: machine.label,
    local: machine.kind === "local",
    ...(placement.room !== undefined ? { room: placement.room } : {}),
  };
}

/// The "This Mac is busy · Run on NAME" chip: while this Mac is the new chat's pick and placement
/// says it is over its budget, the machine placement chose instead. Never while no other machine
/// has room (the pick is this Mac, or every host was full).
export function busyChoice(
  placement: Placement | undefined,
  environments: readonly Environment[],
  selected: string,
): { id: string; label: string; why: string } | undefined {
  if (!placement?.localOver || placement.local || placement.overloaded) return undefined;
  // A pick with no reading (room unknown) is no machine known to have room.
  if (placement.room === undefined || placement.room < 1) return undefined;
  if (environments.find((environment) => environment.id === selected)?.kind !== "local") return undefined;
  const machine = pickedEnvironment(placement, environments);
  if (!machine) return undefined;
  return { id: machine.id, label: machine.label, why: placement.localOver };
}

type PlacedSession = Pick<AcpmuxSessionEntry, "cwd" | "peer" | "activityAt" | "updatedAt">;

/// The folder's last part, the project's name on whichever machine has it (a project's path differs
/// between machines: `/Users/leo/fun/cmux` here, `/home/leo/fun/cmux` there).
function projectName(cwd: string | undefined): string | undefined {
  const name = cwd?.replace(/\/+$/, "").split("/").pop();
  return name || undefined;
}

/// Remote's remembered machine: of the person's own machines (SSH, never Cloud, which is its own
/// pick) a chat can start on now, the one this project's newest chat ran on. `project` is the new
/// chat's folder; none without one, or when no chat of the project ran on such a machine. Read as
/// Remote is picked, so it costs nothing while the composer sits.
export function lastRemoteMachine(
  sessions: readonly PlacedSession[],
  project: string | undefined,
  environments: readonly Environment[],
): string | undefined {
  const name = projectName(project);
  if (!name) return undefined;
  const own = new Set(
    environments
      .filter((environment) => environment.kind === "ssh" && environmentReady(environment))
      .map((environment) => environment.id),
  );
  let best: { peer: string; at: number } | undefined;
  for (const session of sessions) {
    if (!session.peer || !own.has(session.peer) || projectName(session.cwd) !== name) continue;
    const at = activityTime(session) ?? 0;
    if (!best || at > best.at) best = { peer: session.peer, at };
  }
  return best?.peer;
}
