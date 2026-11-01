// The chat's project: the one folder Session Info's Environment lists. Leo, 2026-10-27, on a chat
// whose list showed its harness scratchpad and a worktree its commands had cd'd into: "why are these
// files being shown to me in the first place". So the list holds what acpmux knows, never a guess:
// the folder the chat runs in, at its linked worktree's top when acpmux reports one, named by its
// GitHub repository when the App read one, else by the folder. Folders the chat's tool calls touched
// are not listed: which of them is a project the snapshot cannot say.
//
// Never a temporary or internal folder, the chat's own included: the system's temp folders (a
// harness's scratchpad under /private/tmp), macOS's per-user folders under /private/var, cmux's
// agent-home, the home folder or `/`. A hidden or Spotlight-hidden (`.noindex`) folder (~/.claude,
// a lane's scratch) is internal too, unless acpmux reports it in git: a worktree under
// ~/.cmux/worktrees or <repo>/.claude/worktrees is the project the chat works on.
import type { AcpmuxSnapshot } from "../model";
import { isAgentHome, projectLabel } from "../sessionList";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

const TEMPORARY = /^\/(?:tmp|var\/tmp|var\/folders|private\/tmp|private\/var)(?:\/|$)/;
const HOME_OR_ROOT = /^\/(?:(?:Users|home)(?:\/[^/]+)?)?$/;

const trim = (path: string) => (path.length > 1 ? path.replace(/\/+$/, "") : path);

/// Whether `path` is never a project: a temporary or system folder, agent-home, the home folder or
/// `/`, or (unless `inGit`) a hidden or `.noindex` folder.
export function internalFolder(path: string, inGit = false): boolean {
  const clean = trim(path);
  if (!clean.startsWith("/") || TEMPORARY.test(clean) || HOME_OR_ROOT.test(clean) || isAgentHome(clean)) return true;
  return !inGit && clean.split("/").some((segment) => segment.startsWith(".") || segment.endsWith(".noindex"));
}

/// The chat's project: its folder (`path`, which only the row's tooltip shows), its name, and
/// whether it is a linked worktree.
export type ChatProject = { path: string; name: string; worktree: boolean };

/// The project of the chat `summary` describes, or none when it runs in an internal folder.
/// `repository`: the folder's GitHub `owner/name`, which names it.
export function chatProject(summary: Summary | undefined, repository?: string): ChatProject | undefined {
  const cwd = summary?.cwd ? trim(summary.cwd) : undefined;
  const top = summary?.worktree ? trim(summary.worktree) : undefined;
  // The worktree's top when the chat's folder is in it; else the folder itself.
  const worktree = top && cwd && (cwd === top || cwd.startsWith(`${top}/`)) ? top : undefined;
  const path = worktree ?? cwd;
  if (!path) return undefined;
  const inGit = Boolean(summary?.branch || worktree || repository);
  if (internalFolder(path, inGit) || (cwd !== undefined && internalFolder(cwd, inGit))) return undefined;
  const name = repository?.split("/").pop() || projectLabel(path);
  return { path, name, worktree: worktree !== undefined };
}
