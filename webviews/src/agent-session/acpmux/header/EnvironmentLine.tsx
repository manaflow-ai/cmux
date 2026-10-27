// The chat header's Environment line (Leo, 2026-10-20): where a started chat runs, machine · folder ·
// branch, so it shows without opening the Inspector. Only a new chat's composer names its folder and
// machine (the location strip goes with the first send), so this is the one place a running chat
// says so up front. It reads what the Inspector's Environment reads (inspector/EnvironmentSection.tsx
// `machineOf`), so the two never disagree. A click opens the Inspector at Environment and lights that
// section (so a click with it already in view still answers); with the Inspector off (Debug Settings
// `agent.inspector`) it opens the chat folder's Files tree instead (`environmentOpener`).
//
// The App keeps Left in a small row below the tab row; Right preserves the original header slot and
// compact tab-row lead. A connection problem's label takes the header's status slot instead.
import { memo } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxSnapshot } from "../model";
import { machineOf } from "../inspector/EnvironmentSection";
import { projectLabel } from "../sessionList";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

export type EnvironmentLineProps = {
  summary?: Summary;
  /// This Mac's name from the handshake, for a local chat.
  machineName?: string;
  peerKinds?: Readonly<Record<string, "ssh" | "cloud">>;
  /// The tab-row header's version: it leads the tools with a capped width.
  compact?: boolean;
  /// Opens where the chat runs (`environmentOpener`); without it the line only says so.
  onOpen?: () => void;
};

/// What a click on the line opens (Leo 2026-10-21: no dead clicks in the header): the Inspector at
/// Environment while the Inspector is on, else the chat folder's Files tree when the folder is on this
/// Mac. With neither the line is a note, not a button.
export function environmentOpener(
  reveal: ((section: "environment") => void) | undefined,
  openFiles: (() => void) | undefined,
): (() => void) | undefined {
  if (reveal) return () => reveal("environment");
  return openFiles;
}

export const EnvironmentLine = memo(function EnvironmentLine({
  summary,
  machineName,
  peerKinds,
  compact,
  onOpen,
}: EnvironmentLineProps) {
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
}, sameEnvironmentLine);

function sameEnvironmentLine(previous: EnvironmentLineProps, next: EnvironmentLineProps): boolean {
  const previousSummary = previous.summary;
  const nextSummary = next.summary;
  const previousPeer = previousSummary?.peer;
  const nextPeer = nextSummary?.peer;
  return (
    previous.compact === next.compact &&
    previous.machineName === next.machineName &&
    previous.onOpen === next.onOpen &&
    previousSummary?.cwd === nextSummary?.cwd &&
    previousSummary?.branch === nextSummary?.branch &&
    previousSummary?.worktree === nextSummary?.worktree &&
    previousSummary?.host === nextSummary?.host &&
    previousSummary?.hostKind === nextSummary?.hostKind &&
    previousPeer === nextPeer &&
    previous.peerKinds?.[previousPeer ?? ""] === next.peerKinds?.[nextPeer ?? ""]
  );
}
