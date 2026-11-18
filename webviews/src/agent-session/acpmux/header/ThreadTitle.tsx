import { STUDIO } from "../../../look/studio";

/**
 * The chat's name in the header: plain text, as Claude Code and ChatGPT desktop draw it. It is not
 * a dropdown and draws no pill (Leo, 2026-11-01: "still background on the top right ... why is
 * there a dropdown of this"); the chat's actions are in the header's ⋮ menu. A double-click renames,
 * as ⌘R does.
 *
 * The studio look puts the chat's project before it as a breadcrumb, "project / chat title", as
 * the reference app does (look/studio.ts).
 */
export function ThreadTitle({ title, project, onRename }: { title: string; project?: string; onRename?: () => void }) {
  const name = (
    <span className="acpmux-thread-title" title={title} onDoubleClick={onRename}>
      {title}
    </span>
  );
  if (!project) return name;
  return (
    <span className="studio-crumb">
      <span className="studio-crumb__project">{project}</span>
      <span className="studio-crumb__slash" aria-hidden="true">
        {STUDIO.crumbSlash}
      </span>
      {name}
    </span>
  );
}
