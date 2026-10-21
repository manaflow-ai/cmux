// The Inspector's Environment (Claude Code desktop's): where a running chat runs, the one place
// that says so. The machine by its own name and kind (this Mac, an SSH machine, a Cloud machine),
// never "This computer"; the working folder, whose full path a hover shows; the GitHub repository;
// the branch and the worktree. Then Remote Control and Save, when the App offers them. Everything
// here is already in the snapshot when the chat shows, so nothing fills in late and moves the rows.
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { AcpmuxSnapshot } from "../model";
import { homePath, projectLabel } from "../sessionList";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

const ROW_ICON = rowIconSize(12);

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

export function EnvironmentSection({
  summary,
  machineName,
  peerKinds,
  repository,
  remoteControl,
  onSave,
}: {
  summary?: Summary;
  machineName?: string;
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>;
  /// The chat folder's GitHub repository, `owner/name`.
  repository?: string;
  /// Remote Control's state and switch, when the App offers it for this chat.
  remoteControl?: { on: boolean; set: (on: boolean) => void };
  /// Saves this machine, folder and branch as a reusable environment, when the App offers it.
  onSave?: () => void;
}) {
  const t = useT();
  const machine = machineOf(summary, machineName, peerKinds);
  const cwd = summary?.cwd;
  const worktree = summary?.worktree && summary.worktree !== cwd ? summary.worktree : undefined;
  const folderRow = (path: string, icon: string) => {
    const { name, parent } = splitFolder(path);
    return (
      <li
        className="acpmux-chat-inspector-row"
        // tooltip-allow: the row shows the folder's name; its full path appears nowhere else.
        title={path}
      >
        <Icon name={icon} size={ROW_ICON} row />
        <span className="acpmux-chat-inspector-row__name">{name}</span>
        {parent && <span className="acpmux-chat-inspector-row__detail">{parent}</span>}
      </li>
    );
  };
  return (
    <ul className="acpmux-chat-inspector-list" data-section="environment">
      <li className="acpmux-chat-inspector-row" data-machine={machine.kind}>
        <Icon name={machine.icon} size={ROW_ICON} row />
        <span className="acpmux-chat-inspector-row__name">{machine.name ?? "—"}</span>
        {onSave && (
          <button type="button" className="acpmux-chat-inspector-link acpmux-chat-inspector-row__end" onClick={onSave}>
            {t("chatInspector.environment.save")}
          </button>
        )}
      </li>
      {cwd && folderRow(cwd, cwd === summary?.worktree ? "git.worktree" : "folder")}
      {repository && (
        <li className="acpmux-chat-inspector-row">
          <Icon name="brand.github" size={ROW_ICON} row />
          <a
            className="acpmux-chat-inspector-row__name acpmux-chat-inspector-row__link"
            href={`https://github.com/${repository}`}
          >
            {repository}
          </a>
        </li>
      )}
      {summary?.branch && (
        <li className="acpmux-chat-inspector-row">
          <Icon name="git.branch" size={ROW_ICON} row />
          <span className="acpmux-chat-inspector-row__name">{summary.branch}</span>
        </li>
      )}
      {worktree && folderRow(worktree, "git.worktree")}
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
