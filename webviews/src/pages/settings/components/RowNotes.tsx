import { Button } from "../../../ui/Button";
import { useSettingsSelector, useStore } from "../context";
import { Icon } from "../icons";
import type { RowNoteData } from "../ops";
import { t } from "../strings";

/** The Plain Backgrounds row its note turns off. */
const PLAIN_BACKGROUNDS_KEY = "ui.reducedBackgrounds";

/**
 * A row's notes (#44894): not problems, so no warning color. Where the value comes from (the
 * active theme file sets it, or the person's value applies over the file's) and why it does not draw
 * (Plain Backgrounds is on), each with the one way to change that.
 */
export function RowNotes({ notes, disabled }: { notes: RowNoteData[]; disabled: boolean }) {
  return (
    <>
      {notes.map((note) => (
        <RowNote key={`${note.kind}:${note.path}`} note={note} disabled={disabled} />
      ))}
    </>
  );
}

function RowNote({ note, disabled }: { note: RowNoteData; disabled: boolean }) {
  const store = useStore();
  // Turn Off writes Plain Backgrounds itself: it is off-limits when that key is managed.
  const plainManaged = useSettingsSelector((state) => state.managed.has(PLAIN_BACKGROUNDS_KEY));
  const file = note.file ?? "";
  switch (note.kind) {
    case "setByThemeFile":
    case "overThemeFile":
      return (
        <output className="notice row-note" data-row-note={note.kind}>
          <Icon name="layers" />
          <span className="notice-text">
            {t(
              note.kind === "setByThemeFile" ? "settingsPage.note.setByThemeFile" : "settingsPage.note.overThemeFile",
              file,
            )}
          </span>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            className="link-button"
            onClick={() => void store.openThemeFile()}
          >
            {t("settingsPage.theme.file.open")}
          </Button>
        </output>
      );
    case "plainBackgrounds":
      return (
        <output className="notice row-note" data-row-note={note.kind}>
          <Icon name="paintbrush" />
          <span className="notice-text">{t("settingsPage.note.plainBackgrounds")}</span>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            className="link-button"
            disabled={disabled || plainManaged}
            data-row-note-action="plain-backgrounds-off"
            onClick={() => void store.set(PLAIN_BACKGROUNDS_KEY, false)}
          >
            {t("settingsPage.note.plainBackgroundsOff")}
          </Button>
        </output>
      );
    default:
      return null;
  }
}
