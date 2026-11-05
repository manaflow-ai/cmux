import { type StringKey } from "../i18n";
import type { SavedEnvironmentDraft } from "../environments";
import type { AcpmuxSnapshot } from "../model";
import { chatProject } from "./chatFolders";

export type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

/// Remote Control's row icon. Shipped: `computeruse.click`, a pointer, as Claude Code desktop marks its
/// Remote Control row; Leo, 2026-11-01: "i think we should rethink what symbol we have for remote
/// control at least" (it was `device.phone`, a bare phone outline). The gallery shows the others.
export const REMOTE_CONTROL_ICON = "computeruse.click";

/// Where the chat runs, in words beside the machine's name: Local, SSH or Cloud, the words the
/// environment picker gives each kind (EnvironmentPicker.tsx KIND_LABELS). A name alone never said
/// whether the chat was on this Mac (Leo, 2026-10-31: "WHY IS THERE NOTHING THAT
/// TELLS ME IF IT'S LOCAL OR IF").
export const MACHINE_KIND_LABELS: Readonly<Record<"local" | "ssh" | "cloud", StringKey>> = {
  local: "composer.envLocal",
  ssh: "composer.envSSH",
  cloud: "composer.cloud",
};

/// Where the session runs, as the composer's computer chip names it (ComposerContext computerId):
/// a peer or a Cloud host is another machine, else it is this Mac by its name. With no name known
/// (an older App), the row says nothing rather than a generic "This computer".
export function machineOf(
  summary: Summary | undefined,
  machineName: string | undefined,
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>,
): { icon: string; name?: string; kind: "local" | "ssh" | "cloud" } {
  const peer = summary?.peer;
  if (summary?.hostKind === "cloud" || (peer && peerKinds?.[peer] === "cloud"))
    return { icon: "cloud", name: summary?.host || peer || machineName, kind: "cloud" };
  if (peer) return { icon: "machine.remote", name: summary?.host || peer, kind: "ssh" };
  return { icon: "machine.mac", name: machineName || summary?.host || undefined, kind: "local" };
}

/// What Save keeps of the chat's environment (environments.ts, the New Tab page's saved
/// environments): this Mac or the SSH machine, and the chat's folder, named after its project. Only
/// a chat in a project has one: a chat in a temporary or internal folder (chatFolders.ts) saves
/// nothing useful, and a Cloud machine's chat has none (a saved environment is this Mac or an SSH
/// machine).
export function environmentToSave(
  summary: Summary | undefined,
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>,
  repository?: string,
): SavedEnvironmentDraft | undefined {
  const machine = machineOf(summary, undefined, peerKinds);
  const project = chatProject(summary, repository);
  const folder = summary?.cwd;
  if (!summary || !folder || !project || machine.kind === "cloud") return undefined;
  if (machine.kind === "ssh") return { name: project.name, kind: "ssh", host: summary.peer, folder };
  return { name: project.name, kind: "local", folder };
}
