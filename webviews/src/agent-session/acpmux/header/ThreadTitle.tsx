// The thread's place at the header's start (Lucas 2026-10-17, layout.json `threadTitle`): its
// project, as a label, then its title, which renames the chat in place (`pane.rename`): Return or
// leaving the field keeps the name, Escape puts the old one back.
import { useRef, useState } from "react";
import { useT } from "../i18n";
import { useNt } from "../newtab/strings";
import { folderName } from "../summary/ThreadDetails";
import { Icon } from "../icons/Icon";
import { isAgentHome } from "../sessionList";

export function ThreadTitle({
  folder,
  title,
  onRename,
}: {
  folder?: string;
  title: string;
  onRename?: (name: string) => Promise<unknown>;
}) {
  const t = useT();
  const nt = useNt();
  const [editing, setEditing] = useState(false);
  // Set once Return or Escape settled the field, so the blur its removal may send does nothing.
  const settled = useRef(false);
  const home = isAgentHome(folder);
  // The name this page gave the chat, shown until its title catches up.
  const [renamed, setRenamed] = useState<{ from: string; to: string }>();
  const shown = renamed && renamed.from === title ? renamed.to : title || t("header.agentChat");
  const commit = (value: string) => {
    if (settled.current) return;
    settled.current = true;
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
          {/* A chat with no project runs in its private agent-home folder: No project, nothing to open. */}
          <span className="acpmux-thread-title__project" title={home ? undefined : folder}>
            <Icon name={home ? "placeholder" : "folder"} size={13} />
            <span className="acpmux-thread-title__label">{home ? nt("noProject") : folderName(folder)}</span>
          </span>
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
          // As wide as the name (and a little room to type), so the project beside it never moves.
          size={Math.max(8, Math.min(48, shown.length + 2))}
          // oxlint-disable-next-line jsx-a11y/no-autofocus
          autoFocus
          onFocus={(event) => event.currentTarget.select()}
          onBlur={(event) => commit(event.currentTarget.value)}
          onKeyDown={(event) => {
            // Return or Escape inside an input method's composition belongs to the composition.
            if (event.nativeEvent.isComposing) return;
            if (event.key === "Enter") commit(event.currentTarget.value);
            if (event.key === "Escape") {
              settled.current = true;
              setEditing(false);
            }
          }}
        />
      ) : (
        <button
          type="button"
          className="acpmux-thread-title__name"
          title={onRename ? t("chatMenu.rename") : undefined}
          disabled={!onRename}
          onClick={() => {
            settled.current = false;
            setEditing(true);
          }}
        >
          {shown}
        </button>
      )}
    </nav>
  );
}
