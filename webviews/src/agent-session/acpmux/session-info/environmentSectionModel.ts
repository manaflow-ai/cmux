import { type StringKey } from "../i18n";
import type { SavedEnvironmentDraft } from "../environments";
import type { AcpmuxSnapshot } from "../model";
import { chatMachine, type ChatPlace } from "../chatMachine";
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

/// What Save keeps of the chat's environment (environments.ts, the New Tab page's saved
/// environments): this Mac or the SSH machine, and the chat's folder, named after its project. Only
/// a chat in a project has one: a chat in a temporary or internal folder (chatFolders.ts) saves
/// nothing useful, and a Cloud machine's chat has none (a saved environment is this Mac or an SSH
/// machine).
export function environmentToSave(
  summary: Summary | undefined,
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>,
  repository?: string,
  place?: ChatPlace,
): SavedEnvironmentDraft | undefined {
  const machine = chatMachine(summary, undefined, peerKinds, place);
  const project = chatProject(summary, repository);
  const folder = summary?.cwd;
  if (!summary || !folder || !project || machine.kind === "cloud") return undefined;
  // An SSH machine is saved by its peer name; a chat reached over a remote route has none to save.
  if (machine.kind === "ssh")
    return summary.peer ? { name: project.name, kind: "ssh", host: summary.peer, folder } : undefined;
  return { name: project.name, kind: "local", folder };
}
