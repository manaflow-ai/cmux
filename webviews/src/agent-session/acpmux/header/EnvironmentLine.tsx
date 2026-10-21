// The chat header's Environment line (Leo, 2026-10-20): where a started chat runs, machine · folder ·
// branch, so it shows without opening the Inspector. Only a new chat's composer names its folder and
// machine (the location strip goes with the first send), so this is the one place a running chat
// says so up front. It reads what the Inspector's Environment reads (inspector/EnvironmentSection.tsx
// `machineOf`), so the two never disagree, and clicking it opens the Inspector there.
//
// A header with its own row has it in the status slot, which it never sizes: a long name ends in an
// ellipsis and the tools stay put. A header in the pane's tab row (`compact`) leads the tools with
// it instead, its width capped, as the connection warning does there. A connection problem's label
// takes its place in either (ChatHeaderStatus.tsx).
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxSnapshot } from "../model";
import { machineOf } from "../inspector/EnvironmentSection";
import { projectLabel } from "../sessionList";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

export function EnvironmentLine({
  summary,
  machineName,
  peerKinds,
  compact,
  onOpen,
}: {
  summary?: Summary;
  /// This Mac's name from the handshake, for a local chat.
  machineName?: string;
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>;
  /// The tab-row header's version: it leads the tools with a capped width.
  compact?: boolean;
  /// Opens the Inspector at Environment; without it the line only says where the chat runs.
  onOpen?: () => void;
}) {
  const t = useT();
  const machine = machineOf(summary, machineName, peerKinds);
  const cwd = summary?.cwd;
  // The root folder has no name of its own: it reads "/".
  const trimmed = cwd ? cwd.replace(/\/+$/, "") || "/" : undefined;
  const folder = trimmed === "/" ? "/" : trimmed && projectLabel(trimmed);
  // A local chat in a worktree has the header's worktree pill (WorktreePill.tsx), which names the
  // branch already; the line leaves it out rather than say it twice.
  const pill = machine.kind === "local" && Boolean(summary?.worktree);
  const branch = pill ? undefined : summary?.branch;
  // Nothing to say before the session reports where it runs.
  if (!cwd && !summary?.branch) return null;
  const parts = [machine.name, folder, branch].filter((part): part is string => Boolean(part));
  const className = compact ? "acpmux-env-line acpmux-env-line--compact" : "acpmux-env-line";
  const content = (
    <>
      <Icon name={machine.icon} size={12} />
      {machine.name && <span className="acpmux-env-line__machine">{machine.name}</span>}
      {folder && (
        <>
          {machine.name && (
            <span className="acpmux-env-line__dot" aria-hidden="true">
              ·
            </span>
          )}
          <span className="acpmux-env-line__folder">{folder}</span>
        </>
      )}
      {branch && (
        <>
          <Icon name="git.branch" size={12} />
          <span className="acpmux-env-line__branch">{branch}</span>
        </>
      )}
    </>
  );
  const label = `${t("rail.environment")}: ${parts.join(" · ")}`;
  return onOpen ? (
    <button
      type="button"
      className={className}
      data-machine={machine.kind}
      aria-label={label}
      // tooltip-allow: the line cuts its names with an ellipsis; the tooltip is the folder's full path
      title={cwd}
      onClick={onOpen}
    >
      {content}
    </button>
  ) : (
    <div
      className={className}
      data-machine={machine.kind}
      role="note"
      aria-label={label}
      // tooltip-allow: the line cuts its names with an ellipsis; the tooltip is the folder's full path
      title={cwd}
    >
      {content}
    </div>
  );
}
