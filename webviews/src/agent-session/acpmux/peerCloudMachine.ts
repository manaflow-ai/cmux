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

/// What the banner shows of the chat's machine.
export type PeerMachineState = "paused" | "starting" | undefined;

/// The machine named `peer` (any case: the app matches a peer to a Cloud machine by its title,
/// MachineRegistry machineName(peer:), as cloudMachines.ts does).
export function peerCloudMachine(machines: readonly CloudMachine[], peer: string | undefined): CloudMachine | undefined {
  if (!peer) return undefined;
  const name = peer.toLowerCase();
  return machines.find((machine) => machine.name.toLowerCase() === name);
}

/// What the banner says of `machine`: paused, starting (a Resume this page asked for counts), or
/// nothing it knows (offline as before).
export function peerMachineState(machine: CloudMachine | undefined, resuming: boolean): PeerMachineState {
  if (!machine) return undefined;
  if (resuming || STARTING.has(machine.stage)) return "starting";
  return machine.stage === "paused" ? "paused" : undefined;
}

/// The chat's Cloud machine while `peer` (the chat's machine) does not answer; `peer` undefined
/// once it does. The account's list is read when the machine goes down, and every
/// STARTING_READ_MS while it starts. The reads stop when the machine leaves the starting stages,
/// when the chat's machine answers again (`peer` undefined), or when the banner goes; nothing
/// outlives the banner.
export function usePeerCloudMachine(peer: string | undefined, call: Call = postNative) {
  const machine = peerCloudMachine(useCloudMachines(), peer);
  const [resuming, setResuming] = useState(false);
  const state = peerMachineState(machine, resuming);
  useEffect(() => {
    if (!peer) return;
    void refreshCloudMachines(call);
    if (state !== "starting") return;
    const timer = setInterval(() => void refreshCloudMachines(call), STARTING_READ_MS);
    return () => clearInterval(timer);
  }, [peer, state, call]);
  const resume = () => {
    if (!machine || state !== "paused") return;
    setResuming(true);
    // Resume consumes this click (the app checks the gesture and that the machine is paused),
    // then the list is read again: a refused Resume leaves it paused, with Resume back.
    void runCloudMachine(machine, call).finally(() => setResuming(false));
  };
  return { machine, state, resume };
}
