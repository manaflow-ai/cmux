// One theme choice of the Theme section: a button with the theme's swatch and name, and a popover
// to search every bundled theme. The row the arrow keys highlight previews at once in the section's
// hero and live in the app (onPreview) until the popover closes. A row the pointer only passes over
// does not: the preview follows the pointer once it rests on a row for DWELL_MS, so sweeping down
// the list no longer flashes every theme across the whole app (the "loud" hover, Lawrence
// 2026-10-18) or reloads every terminal's config per row. A right-click pins a row's preview so it
// stays while the pointer moves on. Return or a click picks; Escape reverts. Every theme choice on
// the page uses it: the terminal theme, the app theme, their light and dark sides, and a theme row
// in search results (ThemeRowEditor). The button has one width, so a long name ellipsizes instead of
// moving the row's controls.
import { useEffect, useRef, useState } from "react";
import { Combobox } from "../../../ui/Combobox";
import { Popover } from "../../../ui/Popover";
import { ThemeBall } from "../../../ui/ThemeBall";
import type { GhosttyTheme } from "../../../theme/ghosttyTheme";
import { Icon } from "../icons";
import { t } from "../strings";
import { CONFIG_ROW as CONFIG, pickerRows } from "../themePickerModel";
/** How long the pointer rests on a row before that row previews. */
export const DWELL_MS = 450;

export function ThemePicker({
  value,
  names,
  colors,
  labelId,
  disabled,
  configLabel,
  configColors,
  onPick,
  onPreview,
  custom = () => false,
  nullChoice = true,
}: {
  /** The picked theme name; null shows `configLabel` (the Ghostty config, or Match Terminal Theme). */
  value: string | null;
  names: readonly string[];
  colors: ReadonlyMap<string, GhosttyTheme> | null;
  labelId: string;
  disabled: boolean;
  configLabel: string;
  /** The colors the null choice shows (the Ghostty config's, or the terminal theme), for its chip. */
  configColors: GhosttyTheme | undefined;
  /** Writes the choice; the live preview ends once the returned promise settles. */
  onPick(name: string | null): void | Promise<unknown>;
  /** The highlighted row while the list is open; null when it closes or nothing is highlighted. */
  onPreview(name: string | null, owner?: object): void;
  /** Whether a theme has the user's color edits (appearance.themeEdits): it reads "<name> (custom)". */
  custom?(name: string): boolean;
  /** Whether the list offers the null choice (`configLabel`); the button still shows it for a null value. */
  nullChoice?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [anchor, setAnchor] = useState<HTMLButtonElement | null>(null);
  // The right-clicked theme: previewed whenever no row is highlighted.
  const [pinned, setPinned] = useState<string | null>(null);
  // A live preview is showing in the app; it must end even if the picker goes away while open.
  const showing = useRef<string | null>(null);
  const owner = useRef<object | null>(null);
  // The pending pointer-rest preview; any other preview, a pick or a close cancels it.
  const dwell = useRef<ReturnType<typeof setTimeout> | null>(null);
  const cancelDwell = () => {
    if (dwell.current !== null) clearTimeout(dwell.current);
    dwell.current = null;
  };
  const preview = (name: string | null) => {
    cancelDwell();
    // The same theme again is no new preview: no bridge round trip, no hero re-render.
    if (name === showing.current) return;
    // No preview left to show: end the one in effect under its own owner.
    if (name === null) return end();
    showing.current = name;
    owner.current = {};
    onPreview(name, owner.current);
  };
  // A save that settles late passes the owner it started under: a newer preview (and the pointer's
  // pending dwell in a reopened list) belongs to someone else and is left alone.
  const end = (expectedOwner?: object) => {
    if (expectedOwner !== undefined && owner.current !== expectedOwner) return;
    if (expectedOwner === undefined) cancelDwell();
    if (showing.current !== null) {
      const currentOwner = owner.current;
      showing.current = null;
      owner.current = null;
      onPreview(null, currentOwner ?? undefined);
    }
  };
  const endOnUnmount = useRef(() => {});
  endOnUnmount.current = () => end();
  useEffect(() => () => endOnUnmount.current(), []);
  const highlight = (name: string | undefined, by: "keyboard" | "pointer" | "none") => {
    const target = name && name !== CONFIG ? name : pinned;
    if (by === "keyboard") return preview(target);
    // The pointer passing over, or the list re-highlighting its first row while typing: wait for a rest.
    cancelDwell();
    if (target === showing.current) return;
    dwell.current = setTimeout(() => preview(target), DWELL_MS);
  };
  const label = (name: string) => (custom(name) ? t("settingsPage.theme.custom", name) : name);
  const shown = pickerRows({ names, query, nullChoice });
  const dismiss = () => {
    setOpen(false);
    setQuery("");
    setPinned(null);
  };
  const close = () => {
    cancelDwell();
    dismiss();
    end();
  };
  // Disabled while open (the key became managed, the host disconnected) closes it too.
  useEffect(() => {
    if (disabled && open) close();
  });
  // Write first, then end the preview: the app goes from the preview to the same saved theme,
  // never back to the old one in between.
  const pick = (name: string) => {
    cancelDwell();
    dismiss();
    const chosen = name === CONFIG ? null : names.includes(name) ? name : undefined;
    if (chosen === undefined) return end();
    const pickOwner = owner.current;
    void Promise.resolve(onPick(chosen)).finally(() => {
      if (pickOwner) end(pickOwner);
    });
  };
  return (
    <>
      <button
        ref={setAnchor}
        type="button"
        className="button theme-button"
        data-theme-picker=""
        aria-labelledby={labelId}
        aria-haspopup="dialog"
        aria-expanded={open}
        disabled={disabled}
        onClick={() => setOpen(!open)}
      >
        <ThemeBall name={value ?? undefined} colors={value ? colors?.get(value) : configColors} />
        <span className="theme-button-name">{value ? label(value) : configLabel}</span>
        <Icon name="chevron" />
      </button>
      <Popover
        open={open && !disabled}
        onOpenChange={(next) => (next ? setOpen(true) : close())}
        anchor={anchor}
        label={t("settingsWindow.themeSearch")}
        className="theme-popover"
      >
        <Combobox
          inline
          suggestions={shown}
          onQuery={setQuery}
          onSubmit={pick}
          onCancel={close}
          onHighlight={highlight}
          label={t("settingsWindow.themeSearch")}
          placeholder={t("settingsWindow.themeSearch")}
          inputClassName="field theme-search"
          listClassName="theme-list"
          itemClassName="theme-option"
          renderItem={(name) =>
            name === CONFIG ? (
              <span className="theme-option-row">
                <ThemeBall colors={configColors} />
                <span className="theme-option-name">{configLabel}</span>
                {value === null && <Icon name="check" className="theme-option-check" />}
              </span>
            ) : (
              <span
                className="theme-option-row"
                data-theme-option={name}
                data-previewing={name === pinned ? "" : undefined}
                onContextMenu={(event) => {
                  event.preventDefault();
                  setPinned(name);
                  preview(name);
                }}
              >
                <ThemeBall name={name} colors={colors?.get(name)} />
                <span className="theme-option-name">{label(name)}</span>
                {name === value && <Icon name="check" className="theme-option-check" />}
              </span>
            )
          }
        />
        {shown.length === 0 && <output className="theme-empty empty block">{t("settingsPage.theme.noMatch")}</output>}
        <div className="theme-count">{t("settingsPage.theme.count", names.length)}</div>
      </Popover>
    </>
  );
}
