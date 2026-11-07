// Session Info's Environment (Claude Code desktop's): where a running chat runs, the one place
// that says so. The machine by its own name, with its kind in words at the row's end (Local, SSH or
// Cloud), never "This computer", with Save; then the chat's project (chatFolders.ts), named by its
// repository, whose full path only a hover shows, under a folder icon whether or not it is a
// repository (the repository is the folder, so it has no row of its own); the branch; the chat's
// changes, which open the folder's diff beside the chat. Then Remote Control, when the App offers it.
// No grant rows: the chat menu's Revoke Granted Access (header/grantsMenu.ts) lists what the chat was
// granted (Lucas, 2026-11-05: ChatGPT's panel has none). A chat in a temporary or internal folder (a
// harness's scratchpad) has no project row and no Save: only its machine. Every row does something:
// the project opens in the Files tree beside the chat, the branch is a link to GitHub when the folder's
// repository is there, which the pane opens in the browser as it opens a reply's link, and Changes
// opens the diff.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { machineColor } from "../machineColor";
import type { SavedEnvironmentDraft } from "../environments";
import type { AcpmuxSnapshot } from "../model";
import { chatMachine, type ChatPlace } from "../chatMachine";
import { homePath } from "../sessionList";
import { chatProject } from "./chatFolders";
import { Counts } from "../changes/Counts";
import { openCloudEnvironment } from "../cloudEnvironment";
import { Switch } from "../../../ui/Switch";
import "../../../ui/controls.css";
import {
  CloudRepositoryPicker,
  loadAttachedCloudRepos,
  type AttachedCloudRepo,
  type PendingCloudRepo,
} from "./CloudRepositoryPicker";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

/// Something the chat was granted (App.tsx `accessGrants`): its label, and how Revoke takes it back.
export type AccessGrant = {
  id: string;
  label: string;
  onRemove(): void;
};

const ROW_ICON = rowIconSize(12);

/// How the project row reads. `name` (shipped): the repository's name alone, the branch its own row.
/// Gallery alternatives: `branch`, the branch as a chip in the project's row, with no branch row;
/// `parent`, the name with its parent folder after it (the path text Leo asked not to see).
export type ProjectRowLook = "name" | "branch" | "parent";

/// Remote Control's row icon. Shipped: `computeruse.click`, a pointer, as Claude Code desktop marks its
/// Remote Control row; Leo, 2026-11-01: "i think we should rethink what symbol we have for remote
/// control at least" (it was `device.phone`, a bare phone outline). The gallery shows the others.
export const REMOTE_CONTROL_ICON = "computeruse.click";

/// Where the chat runs, in words beside the machine's name: Local, SSH or Cloud, the words the
/// environment picker gives each kind (EnvironmentPicker.tsx KIND_LABELS). A name alone never said
/// whether the chat was on this Mac (Leo, 2026-10-31: "WHY IS THERE NOTHING THAT
/// TELLS ME IF IT'S LOCAL OR IF").
export const MACHINE_KIND_LABELS: Readonly<Record<"local" | "ssh" | "cloud", StringKey>> = {
  local: "composer.envLocal",
  ssh: "composer.envSSH",
  cloud: "composer.cloud",
};

/// What Save keeps of the chat's environment (environments.ts, the New Tab page's saved
/// environments): this Mac or the SSH machine, and the chat's folder, named after its project. Only
/// a chat in a project has one: a chat in a temporary or internal folder (chatFolders.ts) saves
/// nothing useful, and a Cloud machine's chat has none (a saved environment is this Mac or an SSH
/// machine).
export function environmentToSave(
  summary: Summary | undefined,
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>,
  repository?: string,
  place?: ChatPlace,
): SavedEnvironmentDraft | undefined {
  const machine = chatMachine(summary, undefined, peerKinds, place);
  const project = chatProject(summary, repository);
  const folder = summary?.cwd;
  if (!summary || !folder || !project || machine.kind === "cloud") return undefined;
  // An SSH machine is saved by its peer name; a chat reached over a remote route has none to save.
  if (machine.kind === "ssh")
    return summary.peer ? { name: project.name, kind: "ssh", host: summary.peer, folder } : undefined;
  return { name: project.name, kind: "local", folder };
}

/// A row that does something when it is clicked (`onClick`, or `href`: a web address the pane opens
/// in the browser as it opens a reply's link), else plain text.
function Row({
  icon,
  title,
  onClick,
  href,
  children,
}: {
  icon: string;
  title?: string;
  onClick?: () => void;
  href?: string;
  children: ReactNode;
}) {
  const content = (
    <>
      <Icon name={icon} size={ROW_ICON} row fit />
      {children}
    </>
  );
  if (href)
    return (
      <li>
        {/* tooltip-allow: a long branch name ends in an ellipsis; the whole name appears nowhere else. */}
        <a className="acpmux-session-info-row acpmux-session-info-row--button" href={href} title={title}>
          {content}
        </a>
      </li>
    );
  if (!onClick)
    return (
      // tooltip-allow: a folder row shows the folder's name; its full path appears nowhere else.
      <li className="acpmux-session-info-row" title={title}>
        {content}
      </li>
    );
  return (
    <li>
      <button
        type="button"
        className="acpmux-session-info-row acpmux-session-info-row--button"
        // tooltip-allow: a folder row shows the folder's name; its full path appears nowhere else.
        title={title}
        onClick={onClick}
      >
        {content}
      </button>
    </li>
  );
}

export function EnvironmentSection({
  summary,
  machineName,
  peerKinds,
  place,
  repository,
  cloudRepositoryAvailable = false,
  remoteControl,
  onSave,
  onOpenFolder,
  edits,
  onOpenChanges,
  projectLook = "name",
  remoteControlIcon = REMOTE_CONTROL_ICON,
}: {
  summary?: Summary;
  machineName?: string;
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>;
  /// The page's route to the chat (chatMachine.ts `chatPlace`).
  place?: ChatPlace;
  /// The chat folder's GitHub repository, `owner/name`.
  repository?: string;
  /// Native says whether this pane has an authenticated Cloud repository route.
  cloudRepositoryAvailable?: boolean;
  /// Remote Control's state and switch, when the App offers it for this chat.
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  /// Saves this machine and folder as a reusable environment, when the App offers it.
  onSave?: () => Promise<unknown> | void;
  /// Opens a folder in the Files tree beside the chat (a chat on this Mac).
  onOpenFolder?: (path: string) => void;
  /// The chat's last edits (SessionInfo `edits`): a Changes row under the branch, which opens the
  /// chat folder's diff beside the chat (`onOpenChanges`, the header's Changes). Never a fold.
  edits?: { additions: number; deletions: number };
  onOpenChanges?: () => void;
  projectLook?: ProjectRowLook;
  remoteControlIcon?: string;
}) {
  const t = useT();
  const [saved, setSaved] = useState(false);
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState(false);
  const [repositoryPickerOpen, setRepositoryPickerOpen] = useState(false);
  const [attachedRepos, setAttachedRepos] = useState<AttachedCloudRepo[]>([]);
  const [pendingRepos, setPendingRepos] = useState<PendingCloudRepo[]>([]);
  const addRepositoryButton = useRef<HTMLButtonElement>(null);
  const pending = useRef(false);
  const machine = chatMachine(summary, machineName, peerKinds, place);
  const cloudSession = machine.kind === "cloud" ? summary?.sessionId : undefined;
  const canUseCloudRepositories = Boolean(cloudSession && cloudRepositoryAvailable);
  const branch = summary?.branch;
  const project = chatProject(summary, repository);
  const repositoryUrl = repository ? `https://github.com/${repository}` : undefined;
  const branchUrl =
    repositoryUrl && branch
      ? `${repositoryUrl}/tree/${branch.split("/").map(encodeURIComponent).join("/")}`
      : undefined;
  // Save keeps a project: a chat in a scratch folder has nothing worth keeping.
  const save =
    onSave && project
      ? async () => {
          if (pending.current || saved) return;
          pending.current = true;
          setSaving(true);
          setFailed(false);
          try {
            await onSave();
            setSaved(true);
          } catch {
            // The host can return internal transport details; keep the visible failure display-safe.
            setFailed(true);
          } finally {
            pending.current = false;
            setSaving(false);
          }
        }
      : undefined;
  const parent = project && homePath(project.path.slice(0, project.path.lastIndexOf("/")) || "/");
  useEffect(() => {
    if (!cloudSession || !canUseCloudRepositories) {
      setAttachedRepos([]);
      setPendingRepos([]);
      return;
    }
    let live = true;
    void loadAttachedCloudRepos(cloudSession)
      .then(({ repos, pending }) => {
        if (live) {
          setAttachedRepos(repos);
          setPendingRepos(pending);
        }
      })
      .catch(() => {
        if (live) setAttachedRepos([]);
        if (live) setPendingRepos([]);
      });
    return () => {
      live = false;
    };
  }, [canUseCloudRepositories, cloudSession]);
  return (
    <ul className="acpmux-session-info-list" data-section="environment">
      <li className="acpmux-session-info-row" data-machine={machine.kind}>
        <Icon
          name={machine.icon}
          size={ROW_ICON}
          row
          fit
          color={machine.kind !== "local" && machine.name ? machineColor(machine.name) : undefined}
        />
        <span className="acpmux-session-info-row__name">{machine.name ?? "—"}</span>
        <span className="acpmux-session-info-row__end" data-machine-kind={machine.kind}>
          {t(MACHINE_KIND_LABELS[machine.kind])}
        </span>
        {save && (
          <button
            type="button"
            className="acpmux-session-info-link acpmux-session-info-row__end"
            disabled={saved || saving}
            aria-busy={saving}
            onClick={save}
          >
            {t(saved ? "artifact.saved" : "sessionInfo.environment.save")}
          </button>
        )}
      </li>
      {canUseCloudRepositories && cloudSession && (
        <>
          <li className="acpmux-session-info-row acpmux-cloud-environment-row">
            <Icon name="cloud" size={ROW_ICON} row />
            <span className="acpmux-session-info-row__name">{t("cloudRepository.default")}</span>
            <button
              type="button"
              className="acpmux-session-info-icon-button acpmux-session-info-row__end"
              aria-label={t("cloudRepository.editEnvironment")}
              title={t("cloudRepository.editEnvironment")}
              onClick={() => openCloudEnvironment({ section: "overview" })}
            >
              <Icon name="settings" size={ROW_ICON} />
            </button>
          </li>
          <li>
            <button
              ref={addRepositoryButton}
              type="button"
              className="acpmux-session-info-row acpmux-session-info-row--button"
              data-action="add-repository"
              aria-haspopup="dialog"
              aria-expanded={repositoryPickerOpen}
              data-open={repositoryPickerOpen ? "" : undefined}
              onClick={() => setRepositoryPickerOpen((open) => !open)}
            >
              <Icon name="folder.add" size={ROW_ICON} row />
              <span className="acpmux-session-info-row__name">{t("cloudRepository.add")}</span>
            </button>
            <CloudRepositoryPicker
              session={cloudSession}
              anchor={addRepositoryButton}
              open={repositoryPickerOpen}
              onOpenChange={setRepositoryPickerOpen}
              onAttached={(repo) => setAttachedRepos((current) => [...current, repo])}
            />
          </li>
          {attachedRepos
            .filter((attached) => attached.repo !== repository)
            .map((attached) => (
              <Row key={`${attached.repo}:${attached.folder ?? ""}`} icon="brand.github">
                <span className="acpmux-session-info-row__name">{attached.repo}</span>
              </Row>
            ))}
          {pendingRepos.map((pending) => (
            <li key={`pending:${pending.repo}`} className="acpmux-session-info-row acpmux-cloud-repository-pending">
              <Icon name="git.branch" size={ROW_ICON} row />
              <span className="acpmux-session-info-row__name">{pending.repo}</span>
              <span className="acpmux-session-info-row__detail acpmux-session-info-row__end">
                {pending.phase ?? t("cloudRepository.pending")}
                {pending.progress?.total_objects
                  ? ` · ${pending.progress.objects ?? 0}/${pending.progress.total_objects}`
                  : ""}
              </span>
            </li>
          ))}
        </>
      )}
      {failed && (
        <li className="acpmux-session-info-note" role="alert">
          {t("environment.saveFailed", { reason: t("error.requestFailed") })}
        </li>
      )}
      {project && (
        <Row icon="folder" title={project.path} onClick={onOpenFolder && (() => onOpenFolder(project.path))}>
          <span className="acpmux-session-info-row__name">{project.name}</span>
          {projectLook === "parent" && parent && <span className="acpmux-session-info-row__detail">{parent}</span>}
          {projectLook === "branch" && branch && (
            <span className="acpmux-session-info-row__detail acpmux-session-info-row__end">{branch}</span>
          )}
        </Row>
      )}
      {branch && !(projectLook === "branch" && project) && (
        <Row icon="git.branch" href={branchUrl} title={branch}>
          <span className="acpmux-session-info-row__name">{branch}</span>
        </Row>
      )}
      {branch && edits && edits.additions + edits.deletions > 0 && (
        <Row icon="diff.file" onClick={onOpenChanges} title={t("header.changes")}>
          <span className="acpmux-session-info-row__name">{t("header.changes")}</span>
          <span className="acpmux-session-info-row__end">
            <Counts additions={edits.additions} deletions={edits.deletions} />
          </span>
        </Row>
      )}
      {remoteControl && (
        <li className="acpmux-session-info-row">
          <Icon name={remoteControlIcon} size={ROW_ICON} row fit />
          <label className="acpmux-session-info-switch" title={t("sessionInfo.environment.remoteControl.help")}>
            <span className="acpmux-session-info-row__name">{t("sessionInfo.environment.remoteControl")}</span>
            <Switch
              className="acpmux-session-info-switch__input"
              size="md"
              aria-label={t("sessionInfo.environment.remoteControl")}
              checked={remoteControl.on}
              onCheckedChange={remoteControl.set}
            />
          </label>
        </li>
      )}
    </ul>
  );
}
