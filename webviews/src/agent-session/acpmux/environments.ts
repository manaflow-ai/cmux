/// Where a chat runs, as the environment picker (EnvironmentPicker.tsx) lists it: this computer, an
/// SSH machine (an `ssh://` acpmux peer) or a Cloud machine (any other peer, or a Cloud chat's host).
/// The machines are the composer's computers (ComposerContext availableComputers): acpmux's peers
/// and the hosts its chats ran on. Nothing here keeps a list of its own.
export type EnvironmentKind = "local" | "ssh" | "cloud";
export type Environment = { id: string; label: string; kind: EnvironmentKind };

const SECTION_ORDER: readonly EnvironmentKind[] = ["local", "ssh", "cloud"];

/// Each peer's transport from `_acpmux/status`: `ssh` for an `ssh://` peer, `cloud` for a
/// `ws://`/`wss://` one (cmux Cloud and other daemons the user connected by URL). In the app the
/// relay keeps only `name` and `transport` (the URL's scheme; AcpmuxPaneMethods.replyShapes), so
/// `transport` comes first; the raw `url` is read only when the page talks to acpmux directly.
export function peerKindsFromStatus(status: unknown): Record<string, "ssh" | "cloud"> {
  const peers = (status as { peers?: unknown } | undefined)?.peers;
  if (!Array.isArray(peers)) return {};
  const kinds: Record<string, "ssh" | "cloud"> = {};
  for (const peer of peers) {
    const name = (peer as { name?: unknown } | null)?.name;
    if (typeof name !== "string" || !name) continue;
    const { transport, url } = peer as { transport?: unknown; url?: unknown };
    const ssh =
      typeof transport === "string" ? transport === "ssh" : typeof url === "string" && url.startsWith("ssh://");
    kinds[name] = ssh ? "ssh" : "cloud";
  }
  return kinds;
}

/// The environments in the order the picker lists them and ⌥⌘1–9 number them: Local, then SSH,
/// then Cloud, each in the order given.
export function orderEnvironments(environments: readonly Environment[]): Environment[] {
  return SECTION_ORDER.flatMap((kind) => environments.filter((environment) => environment.kind === kind));
}

/// The environment ⌥⌘`digit` picks, if any. The digit counts the full list, never a filtered one,
/// so a shortcut names the same machine whatever the search field holds.
export function environmentForDigit(environments: readonly Environment[], digit: number): Environment | undefined {
  if (!Number.isInteger(digit) || digit < 1 || digit > 9) return undefined;
  return orderEnvironments(environments)[digit - 1];
}

/// The digit of an ⌥⌘1–9 key event, from its physical key (Option changes `key` on a Mac).
export function environmentDigit(
  event: Pick<KeyboardEvent, "altKey" | "metaKey" | "ctrlKey" | "shiftKey" | "code">,
): number | undefined {
  if (!event.altKey || !event.metaKey || event.ctrlKey || event.shiftKey) return undefined;
  const match = /^Digit([1-9])$/.exec(event.code);
  return match ? Number(match[1]) : undefined;
}

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// A saved environment as the page edits it (New Tab page, preview): a name for where a chat
/// starts. This computer or an SSH machine (an acpmux peer), a folder on it and, on this computer,
/// a new git worktree of that folder for each chat. The host keeps them (`environment.list`,
/// `environment.save`, `environment.remove`; AgentPaneEnvironmentRequest.swift); the page never
/// stores them itself. No id before its first save.
export type SavedEnvironmentDraft = {
  id?: string;
  name: string;
  kind: "local" | "ssh";
  /// Kind `ssh`: the peer's name.
  host?: string;
  folder?: string;
  /// Kind `local` with a folder: each chat starts in a new worktree of it.
  worktree?: boolean;
};

/// A saved environment: the host assigned its id and time.
export type SavedEnvironment = SavedEnvironmentDraft & { id: string; updatedAt: number };

export type SavedEnvironmentHost = {
  list(): Promise<SavedEnvironment[]>;
  save(environment: SavedEnvironmentDraft): Promise<SavedEnvironment>;
  remove(id: string): Promise<void>;
};

/// The host's caps (AgentPaneEnvironment.swift).
export const SAVED_ENVIRONMENT_NAME_LIMIT = 80;

/// The host's environment methods over the page's native call.
export function savedEnvironmentHost(callNative: Native): SavedEnvironmentHost {
  return {
    list: () =>
      callNative("environment.list", {}).then((reply) =>
        ((reply as { environments?: unknown[] } | undefined)?.environments ?? []).filter(isSavedEnvironment),
      ),
    save: (environment) =>
      callNative("environment.save", { environment }).then((reply) => {
        const saved = (reply as { environment?: unknown } | undefined)?.environment;
        if (!isSavedEnvironment(saved)) throw new Error("environment.save");
        return saved;
      }),
    remove: (id) => callNative("environment.remove", { id }).then(() => undefined),
  };
}

function isSavedEnvironment(value: unknown): value is SavedEnvironment {
  const environment = value as Partial<SavedEnvironment> | null;
  return (
    typeof environment?.id === "string" &&
    typeof environment.name === "string" &&
    (environment.kind === "local" || environment.kind === "ssh") &&
    typeof environment.updatedAt === "number"
  );
}

/// What the host gets for a draft: the name trimmed, a blank folder dropped, and only the fields
/// the kind uses (an SSH machine's host; a worktree only of a folder on this computer).
export function savedEnvironmentToSave(draft: SavedEnvironmentDraft): SavedEnvironmentDraft {
  const folder = draft.folder?.trim();
  return {
    ...(draft.id ? { id: draft.id } : {}),
    name: draft.name.trim(),
    kind: draft.kind,
    ...(draft.kind === "ssh" && draft.host ? { host: draft.host } : {}),
    ...(folder ? { folder } : {}),
    ...(draft.kind === "local" && folder && draft.worktree ? { worktree: true } : {}),
  };
}

/// Whether a draft can be saved as it is: a name within the cap, an SSH machine for an SSH one,
/// and a folder the host takes (absolute, or from the home folder).
export function savedEnvironmentReady(draft: SavedEnvironmentDraft): boolean {
  const saved = savedEnvironmentToSave(draft);
  if (!saved.name || saved.name.length > SAVED_ENVIRONMENT_NAME_LIMIT) return false;
  if (saved.kind === "ssh" && !saved.host) return false;
  return saved.folder === undefined || /^(\/|~$|~\/)/.test(saved.folder);
}

/// The list after a save: the saved one first (the host sorts by `updatedAt`), replacing itself.
export function withSavedEnvironment(list: readonly SavedEnvironment[], saved: SavedEnvironment): SavedEnvironment[] {
  return [saved, ...list.filter((environment) => environment.id !== saved.id)];
}
