// Session Info's Environment (Claude Code desktop's): where a running chat runs, the one place
// that says so. The machine by its own name, with its kind in words at the row's end (Local, SSH or
// Cloud), never "This computer", with Save; then the chat's project (chatFolders.ts), named by its
// repository, whose full path only a hover shows; the GitHub repository; the branch. Then Remote
// Control, when the App offers it. A chat in a temporary or internal folder (a harness's scratchpad)
// has no project row and no Save: only its machine. Every row does something: the project opens in
// the Files tree beside the chat, the repository and the branch are links to GitHub, which the pane
// opens in the browser as it opens a reply's link.
import { useRef, useState, type ReactNode } from "react";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { machineColor } from "../machineColor";
import type { SavedEnvironmentDraft } from "../environments";
import type { AcpmuxSnapshot } from "../model";
import { homePath } from "../sessionList";
import { chatProject } from "./chatFolders";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

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

/// Where the session runs, as the composer's computer chip names it (ComposerContext computerId):
/// a peer or a Cloud host is another machine, else it is this Mac by its name. With no name known
/// (an older App), the row says nothing rather than a generic "This computer".
export function machineOf(
  summary: Summary | undefined,
  machineName: string | undefined,
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>,
): { icon: string; name?: string; kind: "local" | "ssh" | "cloud" } {
  const peer = summary?.peer;
  if (summary?.hostKind === "cloud" || (peer && peerKinds?.[peer] === "cloud"))
    return { icon: "cloud", name: summary?.host || peer, kind: "cloud" };
  if (peer) return { icon: "machine.remote", name: summary?.host || peer, kind: "ssh" };
  return { icon: "machine.mac", name: machineName || summary?.host || undefined, kind: "local" };
}

/// What Save keeps of the chat's environment (environments.ts, the New Tab page's saved
/// environments): this Mac or the SSH machine, and the chat's folder, named after its project. Only
/// a chat in a project has one: a chat in a temporary or internal folder (chatFolders.ts) saves
/// nothing useful, and a Cloud machine's chat has none (a saved environment is this Mac or an SSH
/// machine).
export function environmentToSave(
  summary: Summary | undefined,
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>,
  repository?: string,
): SavedEnvironmentDraft | undefined {
  const machine = machineOf(summary, undefined, peerKinds);
  const project = chatProject(summary, repository);
  const folder = summary?.cwd;
  if (!summary || !folder || !project || machine.kind === "cloud") return undefined;
  if (machine.kind === "ssh") return { name: project.name, kind: "ssh", host: summary.peer, folder };
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
        <a className="acpmux-session-info-row acpmux-session-info-row--button" href={href}>
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
  repository,
  remoteControl,
  onSave,
  onOpenFolder,
  projectLook = "name",
  remoteControlIcon = REMOTE_CONTROL_ICON,
}: {
  summary?: Summary;
  machineName?: string;
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>;
  /// The chat folder's GitHub repository, `owner/name`.
  repository?: string;
  /// Remote Control's state and switch, when the App offers it for this chat.
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  /// Saves this machine and folder as a reusable environment, when the App offers it.
  onSave?: () => Promise<unknown> | void;
  /// Opens a folder in the Files tree beside the chat (a chat on this Mac).
  onOpenFolder?: (path: string) => void;
  projectLook?: ProjectRowLook;
  remoteControlIcon?: string;
}) {
  const t = useT();
  const [saved, setSaved] = useState(false);
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState(false);
  const pending = useRef(false);
  const machine = machineOf(summary, machineName, peerKinds);
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
      {failed && (
        <li className="acpmux-session-info-note" role="alert">
          {t("environment.saveFailed", { reason: t("error.requestFailed") })}
        </li>
      )}
      {project && (
        <Row
          icon={project.worktree ? "git.worktree" : "folder"}
          title={project.path}
          onClick={onOpenFolder && (() => onOpenFolder(project.path))}
        >
          <span className="acpmux-session-info-row__name">{project.name}</span>
          {projectLook === "parent" && parent && <span className="acpmux-session-info-row__detail">{parent}</span>}
          {projectLook === "branch" && branch && (
            <span className="acpmux-session-info-row__detail acpmux-session-info-row__end">{branch}</span>
          )}
        </Row>
      )}
      {repository && (
        <Row icon="brand.github" href={repositoryUrl}>
          <span className="acpmux-session-info-row__name">{repository}</span>
        </Row>
      )}
      {branch && !(projectLook === "branch" && project) && (
        <Row icon="git.branch" href={branchUrl}>
          <span className="acpmux-session-info-row__name">{branch}</span>
        </Row>
      )}
      {remoteControl && (
        <li className="acpmux-session-info-row">
          <Icon name={remoteControlIcon} size={ROW_ICON} row fit />
          <label className="acpmux-session-info-switch" title={t("sessionInfo.environment.remoteControl.help")}>
            <span className="acpmux-session-info-row__name">{t("sessionInfo.environment.remoteControl")}</span>
            <input
              type="checkbox"
              className="acpmux-session-info-switch__input"
              aria-label={t("sessionInfo.environment.remoteControl")}
              checked={remoteControl.on}
              onChange={(event) => remoteControl.set(event.currentTarget.checked)}
            />
          </label>
        </li>
      )}
    </ul>
  );
}
