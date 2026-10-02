// Folder trust, owned by acpmux. `acp.trust.get {cwd}` is a read-only projection: the level
// in Claude Code's `~/.claude.json` and Codex's `~/.codex/config.toml` for the folder, per
// harness, and the stricter of the two (or "unknown"). Those files each keep their one
// writer: `acp.trust.set {cwd, level}` records the decision in acpmux's own per-folder
// record, which acpmux applies as launch overrides for the sessions it starts there; level
// "unknown" clears that record, so each agent's own default applies again (Undo).

export type TrustLevel = "trusted" | "untrusted" | "unknown";
export type HarnessTrust = { claude?: TrustLevel; codex?: TrustLevel };
export type FolderTrust = { cwd: string; level: TrustLevel; harnesses?: HarnessTrust };

export type TrustSource = {
  get(cwd: string): Promise<unknown>;
  set(cwd: string, level: TrustLevel): Promise<unknown>;
};

const LEVELS: readonly TrustLevel[] = ["trusted", "untrusted", "unknown"];

/// A reply in the shape above, or undefined for anything else.
export function readTrust(value: unknown): FolderTrust | undefined {
  const reply = value as Partial<FolderTrust> | null;
  if (!reply || typeof reply.cwd !== "string" || !LEVELS.includes(reply.level as TrustLevel)) return undefined;
  const harnesses: HarnessTrust = {};
  for (const harness of ["claude", "codex"] as const) {
    const level = (reply.harnesses as Record<string, unknown> | undefined)?.[harness];
    if (LEVELS.includes(level as TrustLevel)) harnesses[harness] = level as TrustLevel;
  }
  return {
    cwd: reply.cwd,
    level: reply.level as TrustLevel,
    ...(Object.keys(harnesses).length > 0 ? { harnesses } : {}),
  };
}

/// The stricter of two levels: untrusted over unknown over trusted.
export function stricterTrust(left: TrustLevel, right: TrustLevel): TrustLevel {
  const rank: Record<TrustLevel, number> = { untrusted: 0, unknown: 1, trusted: 2 };
  return rank[left] <= rank[right] ? left : right;
}

/// How long the pane waits on a folder's trust before leaving it unasked.
export const TRUST_READ_TIMEOUT_MS = 1500;

/// The folder's trust, or undefined when the host can't say (no reply in time, a failed read):
/// a folder the pane can't read is never asked about.
export async function readFolderTrust(
  source: TrustSource,
  cwd: string,
  timeoutMs = TRUST_READ_TIMEOUT_MS,
): Promise<FolderTrust | undefined> {
  let timer: number | undefined;
  const late = new Promise<undefined>((resolve) => {
    timer = window.setTimeout(resolve, timeoutMs);
  });
  try {
    return readTrust(await Promise.race([source.get(cwd), late]));
  } catch {
    return undefined;
  } finally {
    clearTimeout(timer);
  }
}
