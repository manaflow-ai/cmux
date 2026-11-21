// Every page but the appearance ones: a floating Undo, Redo and Reset at the bottom right of the
// content, as Appearance's (AppearanceBar), so any card is one click from its defaults and the reset
// one click from undone. Leo, 11-19: "make sure you can recover and stuff. for all customizations".
// Reset is a menu of Reset <card> for each card of the page (cardReset.ts), dimmed for a card with
// nothing set; each runs on the pick and is one Undo step, so none asks first. Cmd-Z and Shift-Cmd-Z
// run Undo and Redo while no text field has focus (a field keeps its own undo).
import { Button } from "../../../ui/Button";
import { useEffect, useEffectEvent, useMemo, useState, useSyncExternalStore } from "react";
import { isTypingTarget } from "../../../ui/focusRoute";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { Tooltip } from "../../../ui/Tooltip";
import { cardResetLabel, resetCards } from "../cardReset";
import { useSettingsState, useStore } from "../context";
import { Icon } from "../icons";
import { t } from "../strings";

/** Cmd-Z (undo) or Shift-Cmd-Z (redo), else null. */
function undoChord(event: KeyboardEvent): "undo" | "redo" | null {
  if (!event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return null;
  if (event.key.toLowerCase() !== "z") return null;
  return event.shiftKey ? "redo" : "undo";
}

export function CardResetBar({ section }: { section: string }) {
  const store = useStore();
  const state = useSettingsState();
  const history = store.cardHistory;
  useSyncExternalStore(
    (listener) => history.subscribe(listener),
    () => history.version,
  );
  const [busy, setBusy] = useState(false);
  const cards = useMemo(() => resetCards(section), [section]);
  const live = state.connected && state.readable && !busy;
  const undo = history.nextUndo;
  const redo = history.nextRedo;
  const undoLabel = undo ? t("settingsPage.history.undoNamed", undo.label) : t("settingsPage.history.undo");
  const redoLabel = redo ? t("settingsPage.history.redoNamed", redo.label) : t("settingsPage.history.redo");
  const canReset = cards.map((card) => store.cardCustomized(card));
  const run = async (work: () => Promise<unknown>) => {
    setBusy(true);
    try {
      await work();
    } finally {
      setBusy(false);
    }
  };
  const onKeyDown = useEffectEvent((event: KeyboardEvent) => {
    const chord = undoChord(event);
    if (!chord || event.defaultPrevented) return;
    if (isTypingTarget(event.target as Element | null)) return;
    // With no step to take, the chord is left to the app.
    if (!(chord === "undo" ? history.canUndo : history.canRedo)) return;
    event.preventDefault();
    if (!live) return;
    void run(() => (chord === "undo" ? store.undoCardReset() : store.redoCardReset()));
  });
  useEffect(() => {
    const listener = (event: KeyboardEvent) => onKeyDown(event);
    document.addEventListener("keydown", listener);
    return () => document.removeEventListener("keydown", listener);
  }, []);
  if (cards.length === 0) return null;
  return (
    <div
      // The appearance bar's look and place: one floating bar, whichever page shows it.
      className="appearance-bar"
      // ui-allow: names the floating Undo, Redo and Reset row for VoiceOver; each control is its own Tab stop.
      role="toolbar"
      aria-label={t("settingsPage.cardReset.toolbar")}
      data-card-reset-bar=""
    >
      <Tooltip /* tooltip-allow: names the step Undo takes back */ label={undoLabel} side="top">
        <Button
          type="button"
          variant="ghost"
          icon
          className="icon-button appearance-bar-button"
          data-undo=""
          aria-label={undoLabel}
          disabled={!live || !undo}
          onClick={() => void run(() => store.undoCardReset())}
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
          onClick={() => void run(() => store.redoCardReset())}
        >
          <Icon name="redo" />
        </Button>
      </Tooltip>
      <Menu>
        <MenuButton
          className="button appearance-bar-reset"
          label={t("settingsPage.cardReset.menu")}
          data-menu="card-reset"
          disabled={!live || !canReset.includes(true)}
          aria-haspopup="menu"
        >
          <Icon name="reset" />
          <span>{t("settingsPage.history.reset")}</span>
        </MenuButton>
        <MenuPopup side="top" align="end">
          {cards.map((card, index) => (
            <MenuItem
              key={card.key}
              data-value={card.key}
              disabled={!canReset[index]}
              onSelect={() => void run(() => store.resetCard(card))}
            >
              {cardResetLabel(card)}
            </MenuItem>
          ))}
        </MenuPopup>
      </Menu>
    </div>
  );
}
