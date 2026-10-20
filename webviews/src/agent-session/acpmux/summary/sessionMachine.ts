import type { AcpmuxSnapshot } from "../model";

export type MachineSummary = Pick<NonNullable<AcpmuxSnapshot["summary"]>, "hostKind" | "host" | "peer">;

/// The session's machine, shared by Thread details and the Environment rail.
export function sessionMachine(summary: MachineSummary | undefined, machineName: string | undefined, thisMac: string) {
  const remote = summary?.peer || (summary?.hostKind === "cloud" ? summary.host : undefined);
  return remote
    ? { icon: summary?.hostKind === "cloud" ? "cloud" : "machine.remote", name: summary?.host ?? remote }
    : {
        icon: "machine.local",
        name: machineName || (summary?.hostKind === "local" && summary.host ? summary.host : thisMac),
      };
}
