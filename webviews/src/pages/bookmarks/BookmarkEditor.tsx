// The Add Bookmark, Add Folder, Edit and Rename dialog (the Swift BookmarkEditorSheet): Name, URL
// for a bookmark, and the folder it lives in. Return saves (one apply), Escape cancels; an invalid
// URL or a refusal is said under the fields and the dialog stays open.
import { useRef } from "react";
import { Dialog } from "../../ui/Dialog";
import { DialogButton } from "../../ui/DialogButton";
import { Select } from "../../ui/Select";
import type { Strings } from "../shared/i18n";
import { folderChoices, type RootTitles, type Tree } from "./model";
import type { BookmarksStore, OpenEditor } from "./store";

export function editorTitle(editor: OpenEditor, t: Strings["t"]): string {
  const mode = editor.mode;
  if (mode.kind === "addBookmark") return t("editor.addBookmark");
  if (mode.kind === "addFolder") return t("editor.addFolder");
  return t(editor.isFolder ? "editor.renameFolder" : "bubble.edit");
}

export function BookmarkEditor({
  store,
  editor,
  tree,
  titles,
  strings,
}: {
  store: BookmarksStore;
  editor: OpenEditor;
  tree: Tree;
  titles: RootTitles;
  strings: Strings;
}) {
  const { t } = strings;
  const name = useRef<HTMLInputElement | null>(null);
  const title = editorTitle(editor, t);
  // A folder cannot move into itself or under itself.
  const exclude = editor.mode.kind === "edit" && editor.isFolder ? editor.mode.id : undefined;
  const choices = folderChoices(tree, titles, exclude);
  const error = editor.error;
  return (
    <Dialog
      open
      label={title}
      className="bm-editor"
      initialFocus={name}
      onOpenChange={(open) => {
        if (!open) store.cancelEditor();
      }}
    >
      <form
        className="bm-editor-form"
        onSubmit={(event) => {
          event.preventDefault();
          void store.commitEditor();
        }}
      >
        <h2 className="bm-editor-title">{title}</h2>
        <label className="bm-editor-field">
          <span className="bm-editor-label">{t("field.name")}</span>
          <input
            ref={name}
            className="bm-editor-input"
            aria-label={t("field.name")}
            value={editor.title}
            onChange={(event) => store.setEditor({ title: event.target.value })}
          />
        </label>
        {editor.isFolder ? null : (
          <label className="bm-editor-field">
            <span className="bm-editor-label">{t("field.url")}</span>
            <input
              className="bm-editor-input"
              aria-label={t("field.url")}
              value={editor.url}
              spellCheck={false}
              autoCapitalize="off"
              autoCorrect="off"
              aria-invalid={error?.kind === "invalidURL" ? true : undefined}
              onChange={(event) => store.setEditor({ url: event.target.value })}
            />
          </label>
        )}
        <div className="bm-editor-field">
          <span className="bm-editor-label" id="bm-editor-folder">
            {t("field.folder")}
          </span>
          <Select
            className="bm-editor-select"
            label={t("field.folder")}
            labelledBy="bm-editor-folder"
            closeOnPick
            value={editor.folder}
            options={choices.map((choice) => ({
              value: choice.id,
              label: (
                <span className="bm-choice" style={{ paddingInlineStart: choice.depth * 14 }}>
                  {choice.title}
                </span>
              ),
            }))}
            onChange={(folder) => store.setEditor({ folder })}
          />
        </div>
        {/* One line is always reserved, so a refusal never moves the buttons. */}
        <p className="bm-editor-error" role={error ? "alert" : undefined}>
          {error?.kind === "invalidURL" ? t("editor.invalidURL") : error?.kind === "refused" ? error.message : ""}
        </p>
        <footer className="bm-editor-actions">
          <DialogButton dialogKey="escape" type="button" className="bm-button" onClick={() => store.cancelEditor()}>
            {t("editor.cancel")}
          </DialogButton>
          <DialogButton dialogKey="return" type="submit" className="bm-button is-primary">
            {t("editor.save")}
          </DialogButton>
        </footer>
      </form>
    </Dialog>
  );
}
