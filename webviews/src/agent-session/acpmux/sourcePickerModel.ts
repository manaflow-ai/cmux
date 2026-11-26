import { isCloudChatFolder } from "./folderlessCloud";
import { githubFolder, githubFolderRepo, type GitHubPickerState } from "./githubRepos";
import { githubRepository } from "./githubRepository";
import type { StringKey } from "./i18n";
import { isAgentHome, projectLabel } from "./sessionList";

type GitHubAction = "connect" | "refresh" | "retry";

export function githubSource(state: GitHubPickerState): {
  status: StringKey;
  action?: GitHubAction;
  message?: StringKey;
} {
  if (state.connecting || state.status?.connecting)
    return { status: "source.github.opening", message: "source.github.opening" };
  if (!state.status) return { status: "harnesses.checking", message: "harnesses.checking" };
  if (state.status.state === "unavailable") {
    switch (state.status.reason) {
      case "signed_out":
        return { status: "source.github.signIn", action: "connect", message: "source.github.signInDetail" };
      case "not_configured":
        return { status: "composer.githubConnect", action: "connect" };
      case "not_allowed":
        return { status: "source.github.offForTeam", message: "source.github.notAllowed" };
      default:
        return { status: "source.github.offline", action: "refresh", message: "source.github.offlineDetail" };
    }
  }
  if (state.status.state === "not_connected")
    return {
      status: state.status.pendingApproval ? "source.github.needsApproval" : "composer.githubConnect",
      action: "connect",
      // What happens next, not only what is missing: the repositories come here once an owner approves (Leo 2026-11-25).
      ...(state.status.pendingApproval ? { message: "source.github.approvalNext" as const } : {}),
    };
  if (state.error)
    return { status: state.rateLimited ? "source.github.busy" : "source.github.offline", action: "retry" };
  if (state.query === null && state.repos?.length === 0 && !state.loading)
    return { status: "source.github.noRepos", message: "composer.githubNoRepos" };
  if (state.loading || !state.repos) return { status: "harnesses.checking", message: "source.github.loading" };
  return { status: "composer.envConnected" };
}

export function matchesSourceQuery(text: string, query: string): boolean {
  const lower = text.toLowerCase();
  return query
    .toLowerCase()
    .split(/\s+/)
    .every((word) => lower.includes(word));
}

/// `disabled`: its machine cannot take a new chat now (offline, or already resuming) and has no action to start a
/// wait; a paused machine is not disabled, it resumes through its own action.
export type CloudFolder = {
  id: string;
  label: string;
  peer: string;
  machine: string;
  stage?: string;
  disabled?: boolean;
};

export function cloudSourceFolders(
  sessions: readonly { peer?: string; cwd?: string; host?: string }[],
  machines: readonly { id: string; label: string; kind: string; detail?: string; disabled?: boolean }[],
  peerKinds: Readonly<Record<string, string>>,
): CloudFolder[] {
  const byPeer = new Map(machines.map((machine) => [machine.id, machine]));
  const groups = new Map<string, Map<string, CloudFolder>>();
  for (const session of sessions) {
    const peer = session.peer;
    if (!peer || peerKinds[peer] !== "cloud") continue;
    const path = session.cwd?.replace(/\/+$/, "");
    if (!path?.startsWith("/") || isCloudChatFolder(path) || isAgentHome(path)) continue;
    const machine = byPeer.get(peer);
    const group = groups.get(peer) ?? new Map<string, CloudFolder>();
    if (!group.has(path))
      group.set(path, {
        id: path,
        label: projectLabel(path),
        peer,
        machine: machine?.label === peer ? (session.host ?? peer) : (machine?.label ?? session.host ?? peer),
        stage: machine?.detail,
        ...(machine?.disabled ? { disabled: true } : {}),
      });
    groups.set(peer, group);
  }
  return [...groups.values()].flatMap((group) => [...group.values()]);
}

/** The selected repository is portable across machines. A Mac path is not. */
export function cloudRepositoryPick(folder: string | undefined, remote?: string): string | undefined {
  const repo = githubFolderRepo(folder) ?? githubRepository(remote);
  return repo ? githubFolder(repo) : undefined;
}
