/**
 * The chat's name in the header: plain text, as Claude Code and ChatGPT desktop draw it. It is not
 * a dropdown and draws no pill (Leo, 2026-11-01: "still background on the top right ... why is
 * there a dropdown of this"); the chat's actions are in the header's ⋮ menu. A double-click renames,
 * as ⌘R does. The Codex app look (look/README.md) names the chat's project after it in gray, as the
 * Codex app's title bar does ("Document shot-scraper CLI usage  shot-scraper").
 */
export function ThreadTitle({
  title,
  project,
  onRename,
}: {
  title: string;
  project?: string | undefined;
  onRename?: () => void;
}) {
  return (
    <span className="acpmux-thread-title" title={title} onDoubleClick={onRename}>
      {title}
      {project && <span className="acpmux-thread-title-project">{project}</span>}
    </span>
  );
}

/// The last path component of a folder, the name the Codex app shows for a project.
export function projectName(cwd: string | undefined): string | undefined {
  const name = cwd?.replace(/\/+$/, "").split("/").pop();
  return name || undefined;
}
