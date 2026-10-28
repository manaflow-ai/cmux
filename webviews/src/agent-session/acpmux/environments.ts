/// Where a chat runs, as the environment picker (EnvironmentPicker.tsx) lists it: this computer, an
/// SSH machine (an `ssh://` acpmux peer) or a Cloud machine (any other peer, or a Cloud chat's host).
/// The machines are the composer's computers (ComposerContext availableComputers): acpmux's peers
/// and the hosts its chats ran on. Nothing here keeps a list of its own.
export type EnvironmentKind = "local" | "ssh" | "cloud";
/// `connected`: what acpmux last said of an SSH or Cloud machine it lists; absent when it said nothing.
/// `state`: its link state as acpmux says it (`connecting`, `connected`, `degraded`, `reconnecting`,
/// `offline`; acpmux peer_link.rs `PeerState`), absent from an older daemon or relay.
export type Environment = { id: string; label: string; kind: EnvironmentKind; connected?: boolean; state?: string };

/// The location row's connect choices and the app action each runs (the agent pane allows exactly
/// these; AgentPaneModel.connectActions): SSH… connects a machine, New Cloud Machine creates one on
/// the plan's default size, and Open Cloud… opens the Cloud page, whose storefront lists
/// the plan's sizes (the pane knows no plan), Connect Phone… opens the Mobile Pairing page (cmux
/// on iPhone reaches this Mac), and Add Machine… opens the Add Device card: a computer on the
/// tailnet or in ~/.ssh/config (the app installs its agent daemon and keeps it current), or a new
/// Cloud VM. A started chat's picker offers its one move instead: Move to Cloud on this Mac, Bring
/// Back Local on a Cloud machine (the tab menu's same actions).
export const CONNECT_ACTIONS = {
  ssh: "remote.connect",
  cloud: "newCloudMachine",
  cloudPage: "palette.openCloudPane",
  addMachine: "device.add",
  move: "cloudMove",
  bringBack: "cloudBringBack",
  phone: "palette.mobileConnect",
} as const;
export type ConnectKind = keyof typeof CONNECT_ACTIONS;
/// A started chat's move: to a Cloud machine, or back to this Mac.
export type OffloadKind = Extract<ConnectKind, "move" | "bringBack">;

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

/// Each peer's `connected` flag from `_acpmux/status` (the relay keeps it only as a JSON boolean;
/// AcpmuxPaneMethods.replyShapes). A peer with no flag, or one that is not a boolean, is left out.
export function peerConnectedFromStatus(status: unknown): Record<string, boolean> {
  const peers = (status as { peers?: unknown } | undefined)?.peers;
  if (!Array.isArray(peers)) return {};
  const connected: Record<string, boolean> = {};
  for (const peer of peers) {
    const { name, connected: flag } = (peer ?? {}) as { name?: unknown; connected?: unknown };
    if (typeof name === "string" && name && typeof flag === "boolean") connected[name] = flag;
  }
  return connected;
}

/// Each peer's link state from `_acpmux/status` (the relay keeps it as a string;
/// AcpmuxPaneMethods.replyShapes). A peer with no state, or one that is not a string, is left out.
export function peerStatesFromStatus(status: unknown): Record<string, string> {
  const peers = (status as { peers?: unknown } | undefined)?.peers;
  if (!Array.isArray(peers)) return {};
  const states: Record<string, string> = {};
  for (const peer of peers) {
    const { name, state } = (peer ?? {}) as { name?: unknown; state?: unknown };
    if (typeof name === "string" && name && typeof state === "string" && state) states[name] = state;
  }
  return states;
}

/// Whether a chat can start on the machine now: this Mac always; a peer once acpmux says its link
/// is `connected` (a `degraded` link has not finished its handshake), or, from a daemon that says no
/// state, while it is not marked disconnected. A Cloud chat's host acpmux does not list counts.
export function environmentReady(environment: Environment): boolean {
  if (environment.kind === "local") return true;
  if (environment.state !== undefined) return environment.state === "connected";
  return environment.connected !== false;
}

/// The picker's sections: this Mac; the person's own machines; Cloud machines and VM pools. acpmux
/// keeps no label for a peer, so a pool is read from its names: a `wss://`/`ws://` peer (cmux Cloud)
/// or a Cloud chat's host, and every SSH peer whose name is a shared stem and a number
/// (`gcp-codex-lane-1`, `gcp-codex-lane-2`, `gcp-codex-lane-3`), at least three of them. Any other
/// SSH peer is the person's own (`big-red`, `cmux16`, and a pair such as `build-mini-1`/`-2`).
export type EnvironmentSection = "local" | "mine" | "fleet";
const SECTION_ORDER: readonly EnvironmentSection[] = ["local", "mine", "fleet"];
const POOL_NAME = /^(.*\D)[-_.]?\d+$/;
const POOL_MIN = 3;

export function environmentSections(environments: readonly Environment[]): Map<string, EnvironmentSection> {
  const stems = new Map<string, number>();
  const stemOf = (environment: Environment) =>
    environment.kind === "ssh" ? POOL_NAME.exec(environment.label)?.[1]?.replace(/[-_.]$/, "") : undefined;
  for (const environment of environments) {
    const stem = stemOf(environment);
    if (stem) stems.set(stem, (stems.get(stem) ?? 0) + 1);
  }
  return new Map(
    environments.map((environment) => {
      if (environment.kind === "local") return [environment.id, "local"];
      if (environment.kind === "cloud") return [environment.id, "fleet"];
      const stem = stemOf(environment);
      return [environment.id, stem && (stems.get(stem) ?? 0) >= POOL_MIN ? "fleet" : "mine"];
    }),
  );
}

const byName = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

/// The environments in the order the picker lists them: This Mac, then the person's machines, then
/// Cloud and VMs; in each, the machines a chat can start on first, then the ones still connecting or
/// down, each part by name with its numbers in order (`lane-2` before `lane-10`).
export function orderEnvironments<T extends Environment>(environments: readonly T[]): T[] {
  const sections = environmentSections(environments);
  return SECTION_ORDER.flatMap((section) => {
    const listed = environments
      .filter((environment) => sections.get(environment.id) === section)
      .sort((a, b) => byName.compare(a.label, b.label));
    return [...listed.filter(environmentReady), ...listed.filter((environment) => !environmentReady(environment))];
  });
}

/// The machines ⌥⌘1–9 number, in order: the listed ones a chat can start on.
export function numberedEnvironments(environments: readonly Environment[]): Environment[] {
  return orderEnvironments(environments).filter(environmentReady).slice(0, 9);
}

/// The environment ⌥⌘`digit` picks, if any. The digit counts the full list, never a filtered one,
/// so a shortcut names the same machine whatever the search field holds.
export function environmentForDigit(environments: readonly Environment[], digit: number): Environment | undefined {
  if (!Number.isInteger(digit) || digit < 1 || digit > 9) return undefined;
  return numberedEnvironments(environments)[digit - 1];
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

type Host = { peer?: string | undefined; host?: string | undefined; hostKind?: string | undefined };

/// The machines besides this one, in order: acpmux's peers, then the hosts its chats ran on (a
/// chat's peer, else a Cloud chat's host), then `extra`, each once, never this one (`local`). A peer's transport names its
/// kind (`peerKinds`): an `ssh://` peer is SSH, any other, or a Cloud chat's host acpmux no longer
/// lists, is Cloud. A peer carries what acpmux last said of its connection (`peerConnected`) and
/// its link state (`peerStates`); a Cloud chat's host carries neither. A chat's peer acpmux no
/// longer lists (removed, or a daemon that has not said yet) is not connected: listed, no pick. The composer's computers and the New Tab machines widget both
/// list these.
export function knownMachines(
  peers: readonly string[],
  chats: readonly Host[],
  peerKinds: Record<string, "ssh" | "cloud">,
  extra: readonly Host[] = [],
  peerConnected: Record<string, boolean> = {},
  peerStates: Record<string, string> = {},
): Environment[] {
  const machines: Environment[] = [];
  const seen = new Set<string>();
  const listedPeers = new Set(peers);
  const add = (id: string, label: string, cloudHost: boolean) => {
    if (id === "local" || seen.has(id)) return;
    seen.add(id);
    const listed = cloudHost || listedPeers.has(id);
    const connected = cloudHost ? undefined : listed ? peerConnected[id] : false;
    const state = cloudHost || !listed ? undefined : peerStates[id];
    machines.push({
      id,
      label,
      kind: !cloudHost && peerKinds[id] === "ssh" ? "ssh" : "cloud",
      ...(connected !== undefined ? { connected } : {}),
      ...(state !== undefined ? { state } : {}),
    });
  };
  for (const peer of peers) add(peer, peer, false);
  for (const chat of [...chats, ...extra]) {
    const peer = chat.peer ?? (chat.hostKind === "cloud" ? chat.host : undefined);
    if (peer) add(peer, chat.host ?? peer, !chat.peer);
  }
  return machines;
}
