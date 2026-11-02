// Session Info's Environment, drawn by the App (EnvironmentSection.tsx): where the chat runs,
// its project, repository, branch, Remote Control, and active access grants.
// It heads the panel bare: rows only, always open.
import type { Translate } from "../../i18n";
import type { AcpmuxSnapshot } from "../../model";
import { homePath } from "../../sessionList";
import { chatProject } from "../chatFolders";
import { machineHue } from "../../machineColor";
import { machineOf, type ProjectRowLook } from "../EnvironmentSection";
import type { AttachedCloudRepo, PendingCloudRepo } from "../CloudRepositoryPicker";
import type { NativeInfoRect } from "./model";
import type { NativeInfoActions, NativeInfoRow, NativeInfoSection } from "./model";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

const MACHINE_SYMBOLS = {
  local: "desktopcomputer",
  ssh: "server.rack",
  cloud: "cloud",
} as const;

export type EnvironmentInput = {
  summary?: Summary;
  machineName?: string;
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>;
  /// The chat folder's GitHub repository, `owner/name`.
  repository?: string;
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  grants?: readonly { id: string; label: string; onRemove: () => void }[];
  cloudRepositoryAvailable?: boolean;
  attachedCloudRepos?: readonly AttachedCloudRepo[];
  pendingCloudRepos?: readonly PendingCloudRepo[];
  onOpenCloudEnvironment?: () => void;
  onAddCloudRepository?: (rect?: NativeInfoRect) => void;
  onOpenFolder?: (path: string) => void;
  projectLook?: ProjectRowLook;
  /// Opens the repository's and the branch's GitHub links (the web rows' `href`).
  onOpenUrl?: (url: string) => void;
};

export function environmentSection(
  input: EnvironmentInput,
  actions: NativeInfoActions,
  t: Translate,
): NativeInfoSection | undefined {
  const { summary, repository, remoteControl, onOpenFolder, onOpenUrl, projectLook = "name", grants = [] } = input;
  const machine = machineOf(summary, input.machineName, input.peerKinds);
  const branch = summary?.branch;
  const project = chatProject(summary, repository);
  const repositoryUrl = repository ? `https://github.com/${repository}` : undefined;
  const branchUrl =
    repositoryUrl && branch
      ? `${repositoryUrl}/tree/${branch.split("/").map(encodeURIComponent).join("/")}`
      : undefined;
  const rows: NativeInfoRow[] = [];
  rows.push({
    id: "machine",
    symbol: MACHINE_SYMBOLS[machine.kind],
    title: machine.name ?? "—",
    trailing: t(
      machine.kind === "local" ? "composer.envLocal" : machine.kind === "ssh" ? "composer.envSSH" : "composer.cloud",
    ),
    ...(machine.kind !== "local" && machine.name ? { symbolColor: machineHue(machine.name) } : {}),
  });
  const cloudSession = machine.kind === "cloud" && summary?.sessionId;
  if (cloudSession && input.cloudRepositoryAvailable) {
    rows.push({
      id: "cloud-default",
      symbol: "cloud",
      title: t("cloudRepository.default"),
      ...(input.onOpenCloudEnvironment
        ? {
            action: actions.add("environment.cloudSettings", input.onOpenCloudEnvironment),
          }
        : {}),
    });
    if (input.onAddCloudRepository) {
      rows.push({
        id: "cloud-add-repository",
        symbol: "folder.badge.plus",
        title: t("cloudRepository.add"),
        action: actions.add("environment.cloudAddRepository", input.onAddCloudRepository),
      });
    }
    for (const repo of input.attachedCloudRepos ?? []) {
      if (repo.repo === repository) continue;
      rows.push({
        id: `cloud-repository:${repo.repo}`,
        symbol: "chevron.left.forwardslash.chevron.right",
        title: repo.repo,
        detail: repo.folder,
      });
    }
    for (const repo of input.pendingCloudRepos ?? []) {
      rows.push({
        id: `cloud-pending:${repo.repo}`,
        symbol: "arrow.triangle.branch",
        title: repo.repo,
        trailing: repo.phase ?? repo.state ?? t("cloudRepository.pending"),
        tone: "waiting",
        ...(repo.progress?.total_objects
          ? {
              subtitle: `${repo.progress.objects ?? 0}/${repo.progress.total_objects}`,
            }
          : {}),
      });
    }
  }
  if (project) {
    const parent = homePath(project.path.slice(0, project.path.lastIndexOf("/")) || "/");
    const detail =
      projectLook === "parent" && parent ? parent : projectLook === "branch" && branch ? branch : undefined;
    rows.push({
      id: "project",
      symbol: project.worktree ? "rectangle.stack" : "folder",
      title: project.name,
      ...(detail ? { detail } : {}),
      help: project.path,
      ...(onOpenFolder
        ? {
            action: actions.add("environment.openFolder", () => onOpenFolder(project.path)),
          }
        : {}),
    });
  }
  if (repository)
    rows.push({
      id: "repository",
      symbol: "chevron.left.forwardslash.chevron.right",
      title: repository,
      ...(onOpenUrl && repositoryUrl
        ? {
            action: actions.add("environment.openRepository", () => onOpenUrl(repositoryUrl)),
          }
        : {}),
    });
  if (branch && !(projectLook === "branch" && project))
    rows.push({
      id: "branch",
      symbol: "arrow.triangle.branch",
      title: branch,
      ...(onOpenUrl && branchUrl
        ? {
            action: actions.add("environment.openBranch", () => onOpenUrl(branchUrl)),
          }
        : {}),
    });
  if (remoteControl) {
    const label = t("sessionInfo.environment.remoteControl");
    // The web's switch: a checkbox button that flips it.
    const toggle = actions.add("environment.remoteControl", () => remoteControl.set(!remoteControl.on));
    rows.push({
      id: "remoteControl",
      symbol: "cursorarrow.click",
      title: label,
      tone: remoteControl.on ? "accent" : undefined,
      action: toggle,
      toggle: remoteControl.on,
    });
  }
  for (const grant of grants) {
    const revoke = actions.add(`environment.revoke:${grant.id}`, grant.onRemove);
    rows.push({
      id: `grant:${grant.id}`,
      symbol: "lock",
      title: grant.label,
      buttons: [{ label: t("permission.revoke"), action: revoke }],
    });
  }
  return {
    id: "environment",
    group: "about",
    title: t("rail.environment"),
    bare: true,
    open: true,
    foldable: false,
    reorderable: true,
    rows,
  };
}
