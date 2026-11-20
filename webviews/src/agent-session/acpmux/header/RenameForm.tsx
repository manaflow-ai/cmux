// Rename as an inline popover form (experiments.elevationLadder): a double-click on the chat's name, or
// the ⋮ menu's Rename, opens a small form under the name instead of the App's prompt. A title, one line
// of what the name is for, and a labelled field holding the name, selected. Return saves, Escape or a
// press outside cancels; an empty or unchanged name saves nothing. The popover points at the name with
// its notch (ui/NotchOutline.tsx). The popup mounts on each opening, so the field starts from the name
// it has then.
import { useEffect, useRef, useState, type FormEvent } from "react";
import { elevationLadderOn, useElevationLadder } from "../../../ui/elevationLadder";
import { Input } from "../../../ui/Input";
import { Popover } from "../../../ui/Popover";
import { ThreadTitle } from "./ThreadTitle";
import { useT } from "../i18n";
import "./renameForm.css";

export interface RenameFormProps {
  open: boolean;
  /** The chat's name in the header; the form opens under it. */
  anchor: Element | null;
  /** The name now, prefilled and selected. */
  title: string;
  onCommit(name: string): void;
  onCancel(): void;
}

export function RenameForm({ open, anchor, title, onCommit, onCancel }: RenameFormProps) {
  const t = useT();
  const field = useRef<HTMLInputElement>(null);
  const submit = (event: FormEvent) => {
    event.preventDefault();
    const next = field.current?.value.trim() ?? "";
    if (next && next !== title) onCommit(next);
    else onCancel();
  };
  return (
    <Popover
      open={open}
      onOpenChange={(next) => {
        if (!next) onCancel();
      }}
      anchor={anchor}
      label={t("renameForm.title")}
      className="acpmux-rename-form"
      initialFocus={field}
      notch
    >
      <form onSubmit={submit}>
        <div className="acpmux-rename-form__title">{t("renameForm.title")}</div>
        <p className="acpmux-rename-form__description">{t("renameForm.description")}</p>
        <label className="acpmux-rename-form__row">
          <span className="acpmux-rename-form__label">{t("renameForm.name")}</span>
          <Input
            ref={field}
            className="acpmux-rename-form__field"
            defaultValue={title}
            // All of it selected, so typing replaces it.
            onFocus={(event) => event.currentTarget.select()}
            spellCheck={false}
            autoComplete="off"
          />
        </label>
      </form>
    </Popover>
  );
}

/** The ⋮ menu's Rename asks the header's title to open its form (`requestInlineRename`). */
const INLINE_RENAME_EVENT = "cmux-inline-rename";

/**
 * Opens the inline rename form of the chat's title in this page: true when the elevation ladder is
 * on and a title is there to take it, false when the caller should run the App's own Rename.
 */
export function requestInlineRename(): boolean {
  if (!elevationLadderOn() || !document.querySelector(".acpmux-thread-title")) return false;
  window.dispatchEvent(new Event(INLINE_RENAME_EVENT));
  return true;
}

/**
 * The chat's title (ThreadTitle) with its rename: with the elevation ladder on, a double-click, or
 * the ⋮ menu's Rename, opens the inline form under it; off, a double-click runs `onRename`, the App's
 * prompt, as before. `onRename` undefined (Quick Chat) renames nothing either way.
 */
export function RenamableTitle({
  title,
  onRename,
  onCommit,
}: {
  title: string;
  onRename?: () => void;
  onCommit(name: string): void;
}) {
  const ladder = useElevationLadder();
  const [anchor, setAnchor] = useState<Element | null>(null);
  const titleRef = useRef<HTMLSpanElement>(null);
  const inline = ladder && onRename !== undefined;
  useEffect(() => {
    if (!inline) return;
    const open = () => setAnchor(titleRef.current);
    window.addEventListener(INLINE_RENAME_EVENT, open);
    return () => window.removeEventListener(INLINE_RENAME_EVENT, open);
  }, [inline]);
  return (
    <>
      <ThreadTitle ref={titleRef} title={title} onRename={inline ? () => setAnchor(titleRef.current) : onRename} />
      {inline && (
        <RenameForm
          open={anchor !== null}
          anchor={anchor}
          title={title}
          onCommit={(name) => {
            setAnchor(null);
            onCommit(name);
          }}
          onCancel={() => setAnchor(null)}
        />
      )}
    </>
  );
}
