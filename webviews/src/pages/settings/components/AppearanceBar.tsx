// Settings > Appearance's floating Presets, Undo, Redo and Reset (Leo, 10-19 and 10-20): pinned to the
// bottom right of the content while Appearance shows, so a whole look is one click and a wrong pick
// is always one click from undone. Presets set the window's Opacity and Material and every surface's
// opacity at once (appearancePresets.ts), as one undoable step. Reset is a
// menu: Restore How It Was (when Appearance first showed in this visit), Reset to Defaults, or Reset
// <card> for one card of the page (Leo, 11-19: "make sure you can recover and stuff. for all
// customizations"), leaving the others as they are; each runs on the pick and is itself one Undo
// step, so none asks first. Cmd-Z and Shift-Cmd-Z run Undo and Redo while no text field has focus.
import { Button } from "../../../ui/Button";
import { useEffect, useEffectEvent, useMemo, useState, useSyncExternalStore } from "react";
import { isTypingTarget } from "../../../ui/focusRoute";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator } from "../../../ui/Menu";
import { Tooltip } from "../../../ui/Tooltip";
import { activePreset, APPEARANCE_PRESETS } from "../appearancePresets";
import { appearanceAreas } from "../appearanceUndo";
import { useSettingsState, useStore } from "../context";
import { Icon } from "../icons";
import { t, text } from "../strings";

/** Cmd-Z (undo) or Shift-Cmd-Z (redo), else null. */
function undoChord(event: KeyboardEvent): "undo" | "redo" | null {
  if (!event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return null;
  if (event.key.toLowerCase() !== "z") return null;
  return event.shiftKey ? "redo" : "undo";
}

export function AppearanceBar({ section }: { section: string }) {
  const store = useStore();
  const state = useSettingsState();
  const history = store.appearance;
  useSyncExternalStore(
    (listener) => history.subscribe(listener),
    () => history.version,
  );
  const [busy, setBusy] = useState(false);
  // The opened-with snapshot: the first time Appearance shows with the owner's values.
  useEffect(() => {
    if (state.readable) store.noteAppearanceOpened();
  }, [store, state.readable]);
  const live = state.connected && state.readable && !busy;
  const areas = useMemo(() => appearanceAreas(section), [section]);
  const undo = history.nextUndo;
  const redo = history.nextRedo;
  const undoLabel = undo ? t("settingsPage.history.undoNamed", undo.label) : t("settingsPage.history.undo");
  const redoLabel = redo ? t("settingsPage.history.redoNamed", redo.label) : t("settingsPage.history.redo");
  const canRestore = store.appearanceChangedSinceOpened();
  const canReset = store.appearanceCustomized();
  const preset = activePreset(state);
  const canResetArea = areas.map((area) => store.appearanceAreaCustomized(area));
  const run = async (work: () => Promise<unknown>) => {
    setBusy(true);
    try {
      await work();
    } finally {
      setBusy(false);
    }
  };
  // The page's own Cmd-Z: a text field keeps its own undo; a step running finishes first.
  const onKeyDown = useEffectEvent((event: KeyboardEvent) => {
    const chord = undoChord(event);
    if (!chord || event.defaultPrevented) return;
    if (isTypingTarget(event.target as Element | null)) return;
    event.preventDefault();
    if (!live) return;
    void run(() => (chord === "undo" ? store.undoAppearance() : store.redoAppearance()));
  });
  useEffect(() => {
    const listener = (event: KeyboardEvent) => onKeyDown(event);
    document.addEventListener("keydown", listener);
    return () => document.removeEventListener("keydown", listener);
  }, []);
  return (
    <div
      className="appearance-bar"
      // ui-allow: names the floating Undo, Redo and Reset row for VoiceOver; each control is its own Tab stop.
      role="toolbar"
      aria-label={t("settingsPage.history.toolbar")}
      data-appearance-bar=""
    >
      <Menu>
        <MenuButton
          className="button"
          label={t("settingsPage.presets.menu")}
          data-menu="appearance-presets"
          disabled={!live}
          aria-haspopup="menu"
        >
          <span>{t("settingsPage.presets.title")}</span>
        </MenuButton>
        <MenuPopup side="top" align="end">
          <MenuRadioGroup
            value={preset ?? ""}
            onValueChange={(id) => {
              const picked = APPEARANCE_PRESETS.find((item) => item.id === id);
              if (picked) void run(() => store.applyAppearancePreset(picked));
            }}
          >
            {APPEARANCE_PRESETS.map((item) => (
              <MenuRadioItem key={item.id} value={item.id} closeOnClick>
                {t(item.nameKey)}
              </MenuRadioItem>
            ))}
          </MenuRadioGroup>
        </MenuPopup>
      </Menu>
      <Tooltip /* tooltip-allow: names the step Undo takes back */ label={undoLabel} side="top">
        <Button
          type="button"
          variant="ghost"
          icon
          className="icon-button appearance-bar-button"
          data-undo=""
          aria-label={undoLabel}
          disabled={!live || !undo}
          onClick={() => void run(() => store.undoAppearance())}
        >
          <Icon name="undo" />
        </Button>
      </Tooltip>
      <Tooltip /* tooltip-allow: names the step Redo puts back */ label={redoLabel} side="top">
        <Button
          type="button"
          variant="ghost"
          icon
          className="icon-button appearance-bar-button"
          data-redo=""
          aria-label={redoLabel}
          disabled={!live || !redo}
          onClick={() => void run(() => store.redoAppearance())}
        >
          <Icon name="redo" />
        </Button>
      </Tooltip>
      <Menu>
        <MenuButton
          className="button appearance-bar-reset"
          label={t("settingsPage.history.resetMenu")}
          data-menu="appearance-reset"
          disabled={!live || (!canRestore && !canReset && !canResetArea.includes(true))}
          aria-haspopup="menu"
        >
          <Icon name="reset" />
          <span>{t("settingsPage.history.reset")}</span>
        </MenuButton>
        <MenuPopup side="top" align="end">
          <MenuItem disabled={!canRestore} onSelect={() => void run(() => store.restoreAppearanceOpened())}>
            {t("settingsPage.history.restoreOpenedItem")}
          </MenuItem>
          <MenuItem disabled={!canReset} onSelect={() => void run(() => store.resetAppearanceToDefaults())}>
            {t("settingsPage.history.resetDefaultsItem")}
          </MenuItem>
          {areas.length > 0 && <MenuSeparator />}
          {areas.map((area, index) => (
            <MenuItem
              key={area.key}
              disabled={!canResetArea[index]}
              onSelect={() => void run(() => store.resetAppearanceArea(area))}
            >
              {t("settingsPage.history.resetArea", text(area.title))}
            </MenuItem>
          ))}
        </MenuPopup>
      </Menu>
    </div>
  );
}
