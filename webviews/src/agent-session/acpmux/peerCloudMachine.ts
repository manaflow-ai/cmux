// The account's Cloud machine a peer chat runs on, for the banner over the chat while that machine
// does not answer (PeerCopyBanner.tsx): a paused machine says so and offers Resume, one starting
// says so with a spinner. cmuxterm-hq#4755: "a paused machine's chat reads 'offline'. There is no
// Resume in the pane".
import { useEffect, useState } from "react";
import { refreshCloudMachines, runCloudMachine, useCloudMachines, type CloudMachine } from "./cloudMachines";
import { postNative } from "./native";

type Call = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// `CloudMachineStage` names of a machine on its way up (Swift CloudMachineStage: a resume reads
/// `booting`, then `connecting`).
const STARTING = new Set(["requesting", "creating", "booting", "connecting"]);
/// How often the account's list is read again while the machine starts.
export const STARTING_READ_MS = 3_000;
/// Reads while it starts, at most (3 minutes): a machine stuck starting is read no more, and the
/// banner keeps saying it starts until the chat's machine answers or the banner goes.
export const STARTING_READS = 60;

/// What the banner shows of the chat's machine.
export type PeerMachineState = "paused" | "starting" | undefined;

/// The machine named `peer` (any case: the app matches a peer to a Cloud machine by its title,
/// MachineRegistry machineName(peer:), as cloudMachines.ts does). Two machines of that name
/// (names are not unique) give none: a Resume must never start the other one.
export function peerCloudMachine(
  machines: readonly CloudMachine[],
  peer: string | undefined,
): CloudMachine | undefined {
  if (!peer) return undefined;
  const name = peer.toLowerCase();
  const named = machines.filter((machine) => machine.name.toLowerCase() === name);
  return named.length === 1 ? named[0] : undefined;
}

/// What the banner says of `machine`: paused, starting (a Resume this page asked for counts), or
/// nothing it knows (offline as before).
export function peerMachineState(machine: CloudMachine | undefined, resuming: boolean): PeerMachineState {
  if (!machine) return undefined;
  if (resuming || STARTING.has(machine.stage)) return "starting";
  return machine.stage === "paused" ? "paused" : undefined;
}

/// The chat's Cloud machine while `peer` (the chat's machine) does not answer; `peer` undefined
/// once it does. The account's list is read once when the machine goes down, and every
/// STARTING_READ_MS while it starts, at most STARTING_READS times. The reads stop when the machine
/// leaves the starting stages, after the last one, when the chat's machine answers again (`peer`
/// undefined), or when the banner goes; nothing outlives the banner. A Resume belongs to the
/// machine it was asked for: another peer never reads as starting because of it.
export function usePeerCloudMachine(peer: string | undefined, call: Call = postNative) {
  const machine = peerCloudMachine(useCloudMachines(), peer);
  const [resumingId, setResumingId] = useState<string | undefined>(undefined);
  const state = peerMachineState(machine, machine !== undefined && resumingId === machine.id);
  useEffect(() => {
    if (peer) void refreshCloudMachines(call);
  }, [peer, call]);
  const starting = peer !== undefined && state === "starting";
  useEffect(() => {
    if (!starting) return;
    let reads = 0;
    const timer = setInterval(() => {
      reads += 1;
      if (reads >= STARTING_READS) clearInterval(timer);
      void refreshCloudMachines(call);
    }, STARTING_READ_MS);
    return () => clearInterval(timer);
  }, [starting, machine?.id, call]);
  const resume = () => {
    if (!machine || state !== "paused") return;
    const id = machine.id;
    setResumingId(id);
    // Resume consumes this click (the app checks the gesture and that the machine is paused),
    // then the list is read again: a refused Resume leaves it paused, with Resume back. Only
    // this Resume's own flag is cleared.
    void runCloudMachine(machine, call).finally(() => setResumingId((now) => (now === id ? undefined : now)));
  };
  return { machine, state, resume };
}
