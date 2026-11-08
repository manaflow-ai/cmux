// The omnibar star's "Bookmark Added" / "Edit Bookmark" bubble. The native host is
// CmuxNextBookmarks BookmarkEditBubble, which floats this page in a glass popup under the star and
// saves what it shows when it closes. The fields are the Bookmarks page's editor's (Name, Folder;
// pages/bookmarks/BookmarkEditor.tsx), without URL: the star bookmarks the page shown. The Folder
// menu shows past the card's edge through the app's popup host, so the card never grows for it.
import { useLayoutEffect, useMemo, useRef, useState } from "react";
import { Button } from "../../ui/Button";
import { DialogButton } from "../../ui/DialogButton";
import { Input } from "../../ui/Input";
import { Select } from "../../ui/Select";
import { selectDescription } from "../../ui/popupDescriptors";
import "../../ui/popupSurface.css";
import type { Strings } from "../../pages/shared/i18n";
import {
  adoptTitle,
  folderOptions,
  type BookmarkEditCommand,
  type BookmarkEditLook,
  type BookmarkEditState,
} from "./model";
import "./bookmarkEdit.css";

export type BookmarkEditBubbleProps = {
  state: BookmarkEditState;
  onCommand: (command: BookmarkEditCommand) => void;
  strings: Strings;
  look?: BookmarkEditLook;
  /** Draws its own glass card. Off in the app, where the native popup is the glass. */
  glass?: boolean;
};

export function BookmarkEditBubble({
  state,
  onCommand,
  strings,
  look = "parity",
  glass = true,
}: BookmarkEditBubbleProps) {
  const { t } = strings;
  const [title, setTitle] = useState(state.title);
  const [folder, setFolder] = useState(state.folder);
  // The push the draft last followed: a later push (a page title that arrived) replaces the name
  // only while the person has not edited it.
  const [pushed, setPushed] = useState({ revision: state.revision, title: state.title });
  if (pushed.revision !== state.revision) {
    setPushed({ revision: state.revision, title: state.title });
    setTitle((draft) => adoptTitle(draft, pushed.title, state.title));
  }
  const options = useMemo(() => folderOptions(state, folder), [state, folder]);
  const native = useMemo(
    () => ({
      model: selectDescription({
        options,
        value: folder,
        label: t("field.folder"),
        width: Math.round(state.width * 0.6),
      }),
    }),
    [options, folder, state.width, t],
  );
  // The name has the keys and its text selected when the bubble opens, so typing renames it.
  const name = useRef<HTMLInputElement | null>(null);
  useLayoutEffect(() => {
    name.current?.focus();
    name.current?.select();
  }, []);
  const send = (type: BookmarkEditCommand["type"], next = { title, folder }) => onCommand({ type, ...next });
  return (
    <form
      className={glass ? "be-card ui-popup ui-glass" : "be-card"}
      data-look={look}
      style={{ width: state.width }}
      onSubmit={(event) => {
        event.preventDefault();
        send("done");
      }}
    >
      <h2 className="be-title">{t(state.isNew ? "bubble.added" : "bubble.edit")}</h2>
      <div className="be-fields">
        <label className="be-label" htmlFor="be-name">
          {t("field.name")}
        </label>
        <Input
          id="be-name"
          ref={name}
          className="be-name"
          variant="outline"
          size="sm"
          value={title}
          spellCheck={false}
          onChange={(event) => {
            const next = event.target.value;
            setTitle(next);
            send("edit", { title: next, folder });
          }}
        />
        <span className="be-label" id="be-folder">
          {t("field.folder")}
        </span>
        <Select
          className="be-folder"
          label={t("field.folder")}
          labelledBy="be-folder"
          closeOnPick
          value={folder}
          options={options}
          native={native}
          onChange={(next) => {
            setFolder(next);
            send("edit", { title, folder: next });
          }}
        />
      </div>
      <footer className="be-actions">
        <Button variant="ghost" size="sm" className="be-more" onClick={() => send("more")}>
          {t("bubble.more")}
        </Button>
        <span className="be-spacer" />
        <Button variant="subtle" size="sm" className="be-remove" onClick={() => send("remove")}>
          {t("bubble.remove")}
        </Button>
        <DialogButton dialogKey="return" type="submit" className="ui-btn be-done" data-variant="solid" data-size="sm">
          {t("bubble.done")}
        </DialogButton>
      </footer>
    </form>
  );
}
