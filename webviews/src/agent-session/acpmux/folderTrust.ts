// Folder trust, owned by acpmux: `acp.trust.get {cwd}` reads whether the user trusts a folder,
// and `acp.trust.set {cwd, level}` records it in each agent's own store (Codex's
// config.toml `projects.<path>.trust_level`, Claude Code's `~/.claude.json`
// `projects.<path>.hasTrustDialogAccepted`), so either agent sees the decision.

export type TrustLevel = "trusted" | "untrusted" | "unknown";
export type FolderTrust = { cwd: string; level: TrustLevel };

export type TrustSource = {
  get(cwd: string): Promise<unknown>;
  set(cwd: string, level: Exclude<TrustLevel, "unknown">): Promise<unknown>;
};

const LEVELS: readonly TrustLevel[] = ["trusted", "untrusted", "unknown"];

/// A reply in the shape above, or undefined for anything else.
export function readTrust(value: unknown): FolderTrust | undefined {
  const reply = value as Partial<FolderTrust> | null;
  if (!reply || typeof reply.cwd !== "string" || !LEVELS.includes(reply.level as TrustLevel)) return undefined;
  return { cwd: reply.cwd, level: reply.level as TrustLevel };
}

/// Whether to ask before the first prompt in `cwd`: only when the folder reads "unknown". A
/// folder already decided, or a host that can't say (no reply, a failed read), never blocks a send.
export async function needsTrust(source: TrustSource, cwd: string | undefined): Promise<boolean> {
  if (!cwd) return false;
  try {
    return readTrust(await source.get(cwd))?.level === "unknown";
  } catch {
    return false;
  }
}
