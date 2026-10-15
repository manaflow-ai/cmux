// Saved environments (cx-ncc.104, Labs `savedEnvironments`): a named set of folders, a machine and
// settings that a New Tab chat starts with. The host keeps them (`environment.list/save/remove`,
// New Tab page only); the page never stores them itself. The shape is the page/host contract's.

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

export type EnvironmentKind = "local" | "ssh" | "cloud";
export type EnvironmentFolder = { path: string; branch?: string; worktree?: boolean };
export type EnvironmentVariable = { key: string; value: string };
export type CloudNetwork = "none" | "limited" | "full";
export type EnvironmentCloud = { network: CloudNetwork; domains: string[]; setup?: string };

/// An environment as the page edits it: no id before its first save.
export type EnvironmentDraft = {
  id?: string;
  name: string;
  kind: EnvironmentKind;
  host?: string;
  folders: EnvironmentFolder[];
  env: EnvironmentVariable[];
  cloud?: EnvironmentCloud;
};

/// A saved environment: the host assigned its id and time.
export type Environment = EnvironmentDraft & { id: string; updatedAt: number };

export type EnvironmentHost = {
  list(): Promise<Environment[]>;
  save(environment: EnvironmentDraft): Promise<Environment>;
  remove(id: string): Promise<void>;
};

export const ENVIRONMENT_LIMITS = { name: 80, folders: 16, env: 32, key: 128, value: 4096 } as const;
export const ENVIRONMENT_KINDS: readonly EnvironmentKind[] = ["local", "ssh", "cloud"];
const ENV_KEY = /^[A-Za-z_][A-Za-z0-9_]*$/;

/// The host's environment methods over the page's native call.
export function environmentHost(callNative: Native): EnvironmentHost {
  return {
    list: () =>
      callNative("environment.list", {}).then((reply) =>
        ((reply as { environments?: Environment[] } | undefined)?.environments ?? []).filter(isEnvironment),
      ),
    save: (environment) =>
      callNative("environment.save", { environment }).then((reply) => {
        const saved = (reply as { environment?: Environment } | undefined)?.environment;
        if (!saved || !isEnvironment(saved)) throw new Error("environment.save");
        return saved;
      }),
    remove: (id) => callNative("environment.remove", { id }).then(() => undefined),
  };
}

function isEnvironment(value: unknown): value is Environment {
  const environment = value as Partial<Environment> | null;
  return (
    typeof environment?.id === "string" &&
    typeof environment.name === "string" &&
    ENVIRONMENT_KINDS.includes(environment.kind as EnvironmentKind) &&
    Array.isArray(environment.folders)
  );
}

export function emptyDraft(kind: EnvironmentKind = "local"): EnvironmentDraft {
  return { name: "", kind, folders: [], env: [] };
}

/// Whether a variable's name is one the host takes (a shell identifier).
export function validVariableKey(key: string): boolean {
  return ENV_KEY.test(key) && key.length <= ENVIRONMENT_LIMITS.key;
}

/// What the host gets for a draft: the name trimmed, blank variable rows dropped, and only the
/// fields the kind uses (an SSH host, a Cloud machine's network).
export function draftToSave(draft: EnvironmentDraft): EnvironmentDraft {
  const name = draft.name.trim();
  const env = draft.env
    .map((variable) => ({ key: variable.key.trim(), value: variable.value }))
    .filter((variable) => variable.key || variable.value);
  const saved: EnvironmentDraft = { ...(draft.id ? { id: draft.id } : {}), name, kind: draft.kind, folders: [], env };
  if (draft.kind === "cloud") {
    const cloud = draft.cloud ?? { network: "limited", domains: [] };
    const setup = cloud.setup?.trim();
    saved.cloud = {
      network: cloud.network,
      domains: cloud.network === "limited" ? cloud.domains.map((domain) => domain.trim()).filter(Boolean) : [],
      ...(setup ? { setup } : {}),
    };
    return saved;
  }
  if (draft.kind === "ssh" && draft.host) saved.host = draft.host;
  saved.folders = draft.folders.map((folder) => ({
    path: folder.path,
    ...(folder.branch ? { branch: folder.branch } : {}),
    // A worktree is made on this Mac (`git.worktree.create`): an SSH machine's folder has none.
    ...(folder.worktree && draft.kind === "local" ? { worktree: true } : {}),
  }));
  return saved;
}

/// Whether a draft can be saved as it is: a name, an SSH machine, names the host takes, and
/// within the host's caps.
export function draftReady(draft: EnvironmentDraft): boolean {
  const saved = draftToSave(draft);
  if (!saved.name || saved.name.length > ENVIRONMENT_LIMITS.name) return false;
  if (saved.kind === "ssh" && !saved.host) return false;
  if (saved.folders.length > ENVIRONMENT_LIMITS.folders || saved.env.length > ENVIRONMENT_LIMITS.env) return false;
  return saved.env.every(
    (variable) => validVariableKey(variable.key) && variable.value.length <= ENVIRONMENT_LIMITS.value,
  );
}

/// The list after a save: the saved one first (the host sorts by `updatedAt`), replacing itself.
export function withSaved(list: readonly Environment[], saved: Environment): Environment[] {
  return [saved, ...list.filter((environment) => environment.id !== saved.id)];
}

/// The folder a chat with the environment starts in: its first folder.
export function environmentFolder(environment: EnvironmentDraft): string | undefined {
  return environment.kind === "cloud" ? undefined : environment.folders[0]?.path;
}
