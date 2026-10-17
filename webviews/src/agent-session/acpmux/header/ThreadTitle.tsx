// The thread's place at the header's start (Lucas 2026-10-17, layout.json `threadTitle`): its
// project, then its title. The project opens a New Tab page in that folder beside the chat, with the
// project picked (`chat.newHere`); the title renames the chat in place (`pane.rename`): Return or
// leaving the field keeps the name, Escape puts the old one back.
import { useState } from "react";
import { useT } from "../i18n";
import { folderName } from "../summary/ThreadDetails";

export function ThreadTitle({
  folder,
  title,
  onProject,
  onRename,
}: {
  folder?: string;
  title: string;
  onProject?: (folder: string) => void;
  onRename?: (name: string) => Promise<unknown>;
}) {
  const t = useT();
  const [editing, setEditing] = useState(false);
  // The name this page gave the chat, shown until its title catches up.
  const [renamed, setRenamed] = useState<{ from: string; to: string }>();
  const shown = renamed && renamed.from === title ? renamed.to : title || t("header.agentChat");
  const commit = (value: string) => {
    setEditing(false);
    const name = value.trim();
    if (!name || name === shown || !onRename) return;
    setRenamed({ from: title, to: name });
    onRename(name).catch(() => setRenamed(undefined));
  };
  return (
    <nav className="acpmux-thread-title" aria-label={t("chatMenu.rename")}>
      {folder && (
        <>
          <button
            type="button"
            className="acpmux-thread-title__project"
            title={folder}
            disabled={!onProject}
            onClick={() => onProject?.(folder)}
          >
            {folderName(folder)}
          </button>
          <span className="acpmux-thread-title__slash" aria-hidden="true">
            /
          </span>
        </>
      )}
      {editing ? (
        <input
          className="acpmux-thread-title__field"
          aria-label={t("chatMenu.rename")}
          defaultValue={shown}
          // oxlint-disable-next-line jsx-a11y/no-autofocus
          autoFocus
          onFocus={(event) => event.currentTarget.select()}
          onBlur={(event) => commit(event.currentTarget.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") commit(event.currentTarget.value);
            if (event.key === "Escape") setEditing(false);
          }}
        />
      ) : (
        <button
          type="button"
          className="acpmux-thread-title__name"
          title={onRename ? t("chatMenu.rename") : undefined}
          disabled={!onRename}
          onClick={() => setEditing(true)}
        >
          {shown}
        </button>
      )}
    </nav>
  );
}
