import type { AcpmuxSnapshot } from "./model";

/// The remote Cloud handshake identifies the machine even when its acpmux summary predates the
/// host-kind field. Keep the daemon's host/name fields intact and add only the missing kind so every
/// Session Info consumer treats the chat as Cloud.
export function withCloudMachineSummary(
  summary: AcpmuxSnapshot["summary"],
  cloudMachineID?: string,
): AcpmuxSnapshot["summary"] {
  if (!summary || !cloudMachineID || summary.hostKind === "cloud") return summary;
  return { ...summary, hostKind: "cloud" };
}
