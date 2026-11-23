import type { MachineListing } from "./remoteMachineDirectory";

/// The files view of a chat on another machine (Leo 2026-11-23, the feature map's "Own machines as good as
/// Cloud": "see a new dev server's port and open a file, with no terminal line"): one folder of that
/// machine, listed by its own daemon (`machine.folder.list` with files, the host's `agent-session-list-dir`).
/// The daemon decides the order (folders first, repositories first among them, then by name) and the
/// bound; this only reads its answer.
export type MachineFileEntry = { name: string; path: string; folder: boolean; repo: boolean };
export type MachineFolder = { path: string; parent: string | null; entries: MachineFileEntry[]; truncated: boolean };

/// Lists one folder of the chat's machine: undefined starts where the machine says (its work folder, else home).
export type MachineFilesList = (path: string | undefined) => Promise<MachineListing | undefined>;

/// The folder a daemon answer names, or an Error carrying the daemon's own sentence.
export function machineFolder(listing: MachineListing | undefined): MachineFolder {
  if (!listing) throw new Error("This machine did not answer");
  if (listing.error || !listing.path) throw new Error(listing.error?.message ?? "This machine did not answer");
  return {
    path: listing.path,
    parent: listing.parent ?? null,
    entries: (listing.entries ?? []).map((entry) => ({
      name: entry.name,
      path: entry.path,
      folder: entry.kind === "dir",
      repo: entry.repo === true,
    })),
    truncated: listing.truncated === true,
  };
}
