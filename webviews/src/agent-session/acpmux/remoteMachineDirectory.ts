import type { ProjectDirectory, ProjectDirectoryHost } from "./projectDirectory";

/// The folder chooser of a chat on another machine: one folder of that machine's own disk, listed by
/// its daemon (`machine.folder.list`, the host's `agent-session-list-dir`), never this Mac's open panel.
/// A listing, or `error` {code, message} the chooser shows beside Retry.
export type MachineListing = {
  path?: string;
  parent?: string | null;
  home?: string | null;
  work?: string | null;
  entries?: { name: string; path: string; kind: string; repo?: boolean }[];
  truncated?: boolean;
  error?: { code?: string; message?: string };
};

type Call = (method: string, params: Record<string, unknown>) => Promise<MachineListing | undefined>;

/// The page's directory shape from a daemon listing: folders only, in the daemon's order (repositories first).
export function machineDirectory(listing: MachineListing | undefined): ProjectDirectory {
  if (!listing) throw new Error("This machine did not answer");
  if (listing.error || !listing.path) throw new Error(listing.error?.message ?? "This machine did not answer");
  return {
    path: listing.path,
    parent: listing.parent ?? null,
    home: listing.home ?? listing.path,
    directories: (listing.entries ?? []).filter((entry) => entry.kind === "dir").map((entry) => entry.path),
  };
}

/// The chooser's directory host for one machine, `machine` named when it is not the chat's own (the host addresses that one). It starts where the machine says (its work folder, else its home);
/// a typed `~` or `~/x` is that machine's home, which the first listing names.
export function machineDirectoryHost(call: Call, machine?: string): ProjectDirectoryHost {
  let home: string | undefined;
  return {
    list: async (requested) => {
      const path = requested.trim();
      let asked: string | undefined = path === "" || (path === "~" && !home) ? undefined : path;
      if (home && (path === "~" || path.startsWith("~/"))) asked = home + path.slice(1);
      const directory = machineDirectory(
        await call("machine.folder.list", {
          ...(asked === undefined ? {} : { path: asked }),
          ...(machine ? { machine } : {}),
        }),
      );
      home = directory.home;
      return directory;
    },
  };
}
