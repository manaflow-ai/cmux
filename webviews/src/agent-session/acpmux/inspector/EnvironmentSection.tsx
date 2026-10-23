// The Inspector's Environment (Claude Code desktop's): where a running chat runs, the one place
// that says so. The machine by its own name and kind (this Mac, an SSH machine, a Cloud machine),
// never "This computer", with Save; then every folder the chat worked in (chatFolders.ts): its own
// folder with its parent, then each project its tool calls touched, whose full path a hover shows;
// the GitHub repository; the branch and the worktree. Then Remote Control, when the App offers it.
// Every row does something: a folder opens in the Files tree beside the chat, the repository and
// the branch are links to GitHub, which the pane opens in the browser as it opens a reply's link.
import { useMemo, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { machineColor } from "../machineColor";
import type { SavedEnvironmentDraft } from "../environments";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { homePath, projectLabel } from "../sessionList";
import { chatFolders } from "./chatFolders";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

const ROW_ICON = rowIconSize(12);
const NO_ROWS: readonly AcpmuxRow[] = [];

/// The folder's name, then its parent folder, home-abbreviated: `atlas-web` · `~/src`.
function splitFolder(path: string): { name: string; parent?: string } {
  const trimmed = path.replace(/\/+$/, "");
  const cut = trimmed.lastIndexOf("/");
  const parent = cut > 0 ? homePath(trimmed.slice(0, cut)) : undefined;
  return { name: projectLabel(trimmed), parent: parent && parent !== trimmed ? parent : undefined };
}

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
/// environments): this Mac or the SSH machine, and the chat's folder, named after the folder. A
/// Cloud machine's chat has none: a saved environment is this Mac or an SSH machine.
export function environmentToSave(
  summary: Summary | undefined,
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>,
): SavedEnvironmentDraft | undefined {
  const machine = machineOf(summary, undefined, peerKinds);
  if (!summary || machine.kind === "cloud") return undefined;
  const folder = summary.cwd;
  const name = folder ? projectLabel(folder) : machine.name;
  if (!name) return undefined;
  if (machine.kind === "ssh") return { name, kind: "ssh", host: summary.peer, ...(folder ? { folder } : {}) };
  return { name, kind: "local", ...(folder ? { folder } : {}) };
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
      <Icon name={icon} size={ROW_ICON} row />
      {children}
    </>
  );
  if (href)
    return (
      <li>
        <a className="acpmux-chat-inspector-row acpmux-chat-inspector-row--button" href={href}>
          {content}
        </a>
      </li>
    );
  if (!onClick)
    return (
      // tooltip-allow: a folder row shows the folder's name; its full path appears nowhere else.
      <li className="acpmux-chat-inspector-row" title={title}>
        {content}
      </li>
    );
  return (
    <li>
      <button
        type="button"
        className="acpmux-chat-inspector-row acpmux-chat-inspector-row--button"
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
  showMachineAndFolder = false,
  rows = NO_ROWS,
  remoteControl,
  onSave,
  onOpenFolder,
}: {
  summary?: Summary;
  machineName?: string;
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>;
  /// The chat folder's GitHub repository, `owner/name`.
  repository?: string;
  /// Session Info keeps the machine and folder rows out of the way unless enabled in Settings.
  showMachineAndFolder?: boolean;
  /// The chat's rows, whose tool calls name the other folders it worked in.
  rows?: readonly AcpmuxRow[];
  /// Remote Control's state and switch, when the App offers it for this chat.
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  /// Saves this machine and folder as a reusable environment, when the App offers it.
  onSave?: () => Promise<unknown> | void;
  /// Opens a folder in the Files tree beside the chat (a chat on this Mac).
  onOpenFolder?: (path: string) => void;
}) {
  const t = useT();
  const [saved, setSaved] = useState(false);
  const machine = machineOf(summary, machineName, peerKinds);
  const cwd = summary?.cwd;
  const branch = summary?.branch;
  const worktree = summary?.worktree && summary.worktree !== cwd ? summary.worktree : undefined;
  const folders = useMemo(() => chatFolders(rows, cwd, Boolean(branch)), [rows, cwd, branch]);
  const repositoryUrl = repository ? `https://github.com/${repository}` : undefined;
  const branchUrl =
    repositoryUrl && branch
      ? `${repositoryUrl}/tree/${branch.split("/").map(encodeURIComponent).join("/")}`
      : undefined;
  const save = onSave
    ? () => {
        void Promise.resolve(onSave()).then(
          () => setSaved(true),
          () => undefined,
        );
      }
    : undefined;
  const folderRow = (path: string, icon: string, withParent: boolean) => {
    const { name, parent } = splitFolder(path);
    return (
      <Row key={path} icon={icon} title={path} onClick={onOpenFolder && (() => onOpenFolder(path))}>
        <span className="acpmux-chat-inspector-row__name">{name}</span>
        {withParent && parent && <span className="acpmux-chat-inspector-row__detail">{parent}</span>}
      </Row>
    );
  };
  return (
    <ul className="acpmux-chat-inspector-list" data-section="environment">
      {showMachineAndFolder && (
        <>
          <li className="acpmux-chat-inspector-row" data-machine={machine.kind}>
            <Icon
              name={machine.icon}
              size={ROW_ICON}
              row
              color={machine.kind !== "local" && machine.name ? machineColor(machine.name) : undefined}
            />
            <span className="acpmux-chat-inspector-row__name">{machine.name ?? "—"}</span>
            {save && (
              <button
                type="button"
                className="acpmux-chat-inspector-link acpmux-chat-inspector-row__end"
                disabled={saved}
                onClick={save}
              >
                {t(saved ? "artifact.saved" : "chatInspector.environment.save")}
              </button>
            )}
          </li>
          {folders.map((path, index) =>
            folderRow(path, index === 0 && path === summary?.worktree ? "git.worktree" : "folder", index === 0),
          )}
        </>
      )}
      {repository && (
        <Row icon="brand.github" href={repositoryUrl}>
          <span className="acpmux-chat-inspector-row__name">{repository}</span>
        </Row>
      )}
      {branch && (
        <Row icon="git.branch" href={branchUrl}>
          <span className="acpmux-chat-inspector-row__name">{branch}</span>
        </Row>
      )}
      {showMachineAndFolder && worktree && !folders.includes(worktree) && folderRow(worktree, "git.worktree", true)}
      {remoteControl && (
        <li className="acpmux-chat-inspector-row">
          <Icon name="device.phone" size={ROW_ICON} row />
          <label className="acpmux-chat-inspector-switch">
            <span className="acpmux-chat-inspector-row__name">{t("chatInspector.environment.remoteControl")}</span>
            <input
              type="checkbox"
              className="acpmux-chat-inspector-switch__input"
              aria-label={t("chatInspector.environment.remoteControl")}
              checked={remoteControl.on}
              onChange={(event) => remoteControl.set(event.currentTarget.checked)}
            />
          </label>
        </li>
      )}
    </ul>
  );
}
