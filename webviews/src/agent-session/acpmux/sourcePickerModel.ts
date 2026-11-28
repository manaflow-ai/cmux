import { isCloudChatFolder } from "./folderlessCloud";
import { githubFolder, githubFolderRepo, githubFullName, type GitHubPickerState } from "./githubRepos";
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
  // The app's own GitHub panel is open, or the app is finishing what GitHub handed back: say so, no click needed.
  if (state.status?.progress === "on_github" && state.status.state !== "ready")
    return { status: "source.github.onGitHub", message: "source.github.onGitHubDetail" };
  if (state.status?.progress === "finishing" && state.status.state !== "ready")
    return { status: "source.github.finishing", message: "source.github.finishing" };
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

/// Why a typed Git URL names no repository to clone, or nothing when it is an https URL with an owner and a name.
export function gitURLValidation(url: string): StringKey | undefined {
  if (!/^https:\/\//i.test(url) || /\s/.test(url)) return "source.url.invalid";
  try {
    const parsed = new URL(url);
    if (parsed.username || parsed.password || parsed.search || parsed.hash) return "source.url.credentials";
    return parsed.pathname.split("/").filter(Boolean).length < 2 ? "source.url.invalid" : undefined;
  } catch {
    return "source.url.invalid";
  }
}

/// A Git URL typed into Add project with Cloud picked: nothing is cloned on this Mac. A GitHub repository (an https,
/// scp or ssh URL, or `owner/name`) becomes the chat's `github:owner/name` folder, which the Cloud machine clones
/// (AgentPaneCloudStart+Repository.swift). Another host's URL is refused in words: the machine's repo step clones
/// GitLab and other https hosts (cmux-cloud-start-core `machine_repo.rs`), but the app's Cloud start carries a
/// GitHub repository only (AgentPaneGitHubFolder), so a GitLab URL here would start a chat with no folder.
export function cloudGitURLFolder(url: string): { folder: string } | { error: StringKey } {
  const typed = url.trim();
  const name = githubFullName(typed);
  if (name && !/^https?:\/\/[^/]*@/i.test(typed)) return { folder: githubFolder(name) };
  const invalid = gitURLValidation(typed);
  if (invalid) return { error: invalid };
  return { error: "source.url.cloudGitHubOnly" };
}
