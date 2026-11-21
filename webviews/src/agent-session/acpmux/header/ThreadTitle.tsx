import { Fragment } from "react";

/**
 * The chat's name in the header: plain text, as Claude Code and ChatGPT desktop draw it. It is not
 * a dropdown and draws no pill (Leo, 2026-11-01: "still background on the top right ... why is
 * there a dropdown of this"); the chat's actions are in the header's ⋮ menu. A double-click renames,
 * as ⌘R does.
 *
 * With Header Path on (`agentPane.display.headerBreadcrumb`, off by default; Taste Board #20), `trail`
 * (headerState.ts `headerBreadcrumb`: repository, branch) leads the title as one monospace slash path,
 * `repo / branch / title`, its separators fainter. The title segment stays the rename target. With no
 * trail the title draws exactly as before.
 */
export function ThreadTitle({
  title,
  onRename,
  trail,
}: {
  title: string;
  onRename?: () => void;
  trail?: readonly string[];
}) {
  // With a trail the title segment carries no tooltip of its own: the path's full-path tooltip shows
  // over it too.
  const name = (tooltip: string | undefined) => (
    <span className="acpmux-thread-title" title={tooltip} onDoubleClick={onRename}>
      {title}
    </span>
  );
  if (!trail?.length) return name(title);
  return (
    <span className="acpmux-thread-crumbs" title={[...trail, title].join(" / ")}>
      {trail.map((part, index) => (
        <Fragment key={index}>
          <span className="acpmux-thread-crumb">{part}</span>
          <span className="acpmux-thread-crumb-sep" aria-hidden="true">
            {" / "}
          </span>
        </Fragment>
      ))}
      {name(undefined)}
    </span>
  );
}
