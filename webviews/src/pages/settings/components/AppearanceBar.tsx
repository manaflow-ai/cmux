// Settings > Appearance's floating Undo, Redo and Reset (Leo, 10-19): pinned to the bottom right of
// the content while Appearance shows, so a wrong pick is always one click from undone. Reset is a
// menu: Restore How It Was (when Appearance first showed in this visit) or Reset to Defaults, each
// confirmed inline and itself undoable.
import { useEffect, useState, useSyncExternalStore } from "react";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { Tooltip } from "../../../ui/Tooltip";
import { useSettingsState, useStore } from "../context";
import { Icon } from "../icons";
import { t } from "../strings";

type Pending = "opened" | "defaults";

export function AppearanceBar() {
  const store = useStore();
  const state = useSettingsState();
  const history = store.appearance;
  useSyncExternalStore(
    (listener) => history.subscribe(listener),
    () => history.version,
  );
  const [pending, setPending] = useState<Pending | null>(null);
  const [busy, setBusy] = useState(false);
  // The opened-with snapshot: the first time Appearance shows with the owner's values.
  useEffect(() => {
    if (state.readable) store.noteAppearanceOpened();
  }, [store, state.readable]);
  const live = state.connected && state.readable && !busy;
  // A step whose targets another writer changed since is not offered (#29881).
  const undo = store.appearanceUndoStep();
  const redo = store.appearanceRedoStep();
  const undoLabel = undo ? t("settingsPage.history.undoNamed", undo.label) : t("settingsPage.history.undo");
  const redoLabel = redo ? t("settingsPage.history.redoNamed", redo.label) : t("settingsPage.history.redo");
  const canRestore = store.appearanceChangedSinceOpened();
  const canReset = store.appearanceCustomized();
  const run = async (work: () => Promise<unknown>) => {
    setBusy(true);
    try {
      await work();
    } finally {
      setBusy(false);
    }
  };
  return (
    <div
      className="appearance-bar"
      // ui-allow: names the floating Undo, Redo and Reset row for VoiceOver; each control is its own Tab stop.
      role="toolbar"
      aria-label={t("settingsPage.history.toolbar")}
      data-appearance-bar=""
    >
      {pending ? (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- an inline confirm in the bar's row; a fieldset would bring its own box
        <span className="appearance-bar-confirm" role="group">
          <span className="appearance-bar-question">
            {pending === "opened"
              ? t("settingsPage.history.confirmRestore")
              : t("settingsPage.history.confirmDefaults")}
          </span>
          <button
            type="button"
            className="button"
            data-confirm=""
            disabled={!live}
            onClick={() =>
              void run(async () => {
                setPending(null);
                await (pending === "opened" ? store.restoreAppearanceOpened() : store.resetAppearanceToDefaults());
              })
            }
          >
            {pending === "opened" ? t("settingsPage.history.restore") : t("settingsPage.history.reset")}
          </button>
          <button type="button" className="button" data-cancel="" onClick={() => setPending(null)}>
            {t("settingsPage.history.cancel")}
          </button>
        </span>
      ) : (
        <>
          <Tooltip /* tooltip-allow: names the step Undo takes back */ label={undoLabel} side="top">
            <button
              type="button"
              className="icon-button appearance-bar-button"
              data-undo=""
              aria-label={undoLabel}
              disabled={!live || !undo}
              onClick={() => void run(() => store.undoAppearance())}
            >
              <Icon name="undo" />
            </button>
          </Tooltip>
          <Tooltip /* tooltip-allow: names the step Redo puts back */ label={redoLabel} side="top">
            <button
              type="button"
              className="icon-button appearance-bar-button"
              data-redo=""
              aria-label={redoLabel}
              disabled={!live || !redo}
              onClick={() => void run(() => store.redoAppearance())}
            >
              <Icon name="redo" />
            </button>
          </Tooltip>
          <Menu>
            <MenuButton
              className="button appearance-bar-reset"
              label={t("settingsPage.history.resetMenu")}
              data-menu="appearance-reset"
              disabled={!live || (!canRestore && !canReset)}
              aria-haspopup="menu"
            >
              <Icon name="reset" />
              <span>{t("settingsPage.history.reset")}</span>
            </MenuButton>
            <MenuPopup side="top" align="end">
              <MenuItem disabled={!canRestore} onSelect={() => setPending("opened")}>
                {t("settingsPage.history.restoreOpenedItem")}
              </MenuItem>
              <MenuItem disabled={!canReset} onSelect={() => setPending("defaults")}>
                {t("settingsPage.history.resetDefaultsItem")}
              </MenuItem>
            </MenuPopup>
          </Menu>
        </>
      )}
    </div>
  );
}
