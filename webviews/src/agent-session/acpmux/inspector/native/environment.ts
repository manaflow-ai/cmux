// Session Info's Environment, drawn by the App (EnvironmentSection.tsx): the machine (with Save),
// the chat's project, its GitHub repository, its branch, and Remote Control when the App offers it.
// It heads the panel bare: rows only, always open.
import type { Translate } from "../../i18n";
import type { AcpmuxSnapshot } from "../../model";
import { homePath } from "../../sessionList";
import { chatProject } from "../chatFolders";
import { machineOf, type ProjectRowLook } from "../EnvironmentSection";
import type { NativeInfoActions, NativeInfoRow, NativeInfoSection } from "./model";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

const MACHINE_SYMBOLS = { local: "desktopcomputer", ssh: "server.rack", cloud: "cloud" } as const;

export type EnvironmentInput = {
  summary?: Summary;
  machineName?: string;
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>;
  /// The chat folder's GitHub repository, `owner/name`.
  repository?: string;
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  onSave?: () => Promise<unknown> | void;
  onOpenFolder?: (path: string) => void;
  projectLook?: ProjectRowLook;
  /// Save already kept this environment (EnvironmentSection's own `saved`, held by the caller).
  saved?: boolean;
  /// Save finished: the caller marks it `saved`.
  onSaved?: () => void;
  /// Opens the repository's and the branch's GitHub links (the web rows' `href`).
  onOpenUrl?: (url: string) => void;
};

export function environmentSection(
  input: EnvironmentInput,
  actions: NativeInfoActions,
  t: Translate,
): NativeInfoSection | undefined {
  const { summary, repository, remoteControl, onSave, onOpenFolder, onOpenUrl, projectLook = "name" } = input;
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
    ...(onSave && project
      ? {
          buttons: [
            {
              label: t(input.saved ? "artifact.saved" : "chatInspector.environment.save"),
              disabled: input.saved === true,
              action: actions.add("environment.save", () =>
                Promise.resolve(onSave()).then(
                  () => input.onSaved?.(),
                  () => undefined,
                ),
              ),
            },
          ],
        }
      : {}),
  });
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
      ...(onOpenFolder ? { action: actions.add("environment.openFolder", () => onOpenFolder(project.path)) } : {}),
    });
  }
  if (repository)
    rows.push({
      id: "repository",
      symbol: "chevron.left.forwardslash.chevron.right",
      title: repository,
      ...(onOpenUrl && repositoryUrl
        ? { action: actions.add("environment.openRepository", () => onOpenUrl(repositoryUrl)) }
        : {}),
    });
  if (branch && !(projectLook === "branch" && project))
    rows.push({
      id: "branch",
      symbol: "arrow.triangle.branch",
      title: branch,
      ...(onOpenUrl && branchUrl ? { action: actions.add("environment.openBranch", () => onOpenUrl(branchUrl)) } : {}),
    });
  if (remoteControl) {
    const label = t("chatInspector.environment.remoteControl");
    // The web's switch: a checkbox button that flips it.
    const toggle = actions.add("environment.remoteControl", () => remoteControl.set(!remoteControl.on));
    rows.push({
      id: "remoteControl",
      symbol: "iphone",
      title: label,
      tone: remoteControl.on ? "accent" : undefined,
      action: toggle,
      buttons: [{ label, symbol: remoteControl.on ? "checkmark.square.fill" : "square", action: toggle }],
    });
  }
  return {
    id: "environment",
    group: "about",
    title: t("rail.environment"),
    bare: true,
    open: true,
    foldable: false,
    rows,
  };
}
