// One theme choice of the Theme section: a button with the theme's swatch and name, and a popover
// to search every bundled theme. The row the arrow keys highlight previews at once in the section's
// hero and live in the app (onPreview) until the popover closes. A row the pointer only passes over
// does not: the preview follows the pointer once it rests on a row for DWELL_MS, so sweeping down
// the list no longer flashes every theme across the whole app (the "loud" hover, Lawrence
// 2026-10-18) or reloads every terminal's config per row. A right-click pins a row's preview so it
// stays while the pointer moves on. Return or a click picks; Escape reverts. Every theme choice on
// the page uses it: the terminal theme, the app theme, their light and dark sides, and a theme row
// in search results (ThemeRowEditor). The button has one width, so a long name ellipsizes instead of
// moving the row's controls. Each row has a star (appearance.favoriteThemes, Leo 2026-10-20: "you
// should also be able to star themes and pick from them"): the starred themes list first, under
// their own heading. The star, or Cmd-S on the highlighted row, toggles it without picking the row.
import { useEffect, useMemo, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { Combobox } from "../../../ui/Combobox";
import { Popover } from "../../../ui/Popover";
import { ThemeBall } from "../../../ui/ThemeBall";
import type { GhosttyTheme } from "../../../theme/ghosttyTheme";
import { useSettingsSelector, useStore } from "../context";
import { Icon } from "../icons";
import { managedOf, valueOf } from "../store";
import { t } from "../strings";
import { CONFIG_ROW as CONFIG, pickerRows, rowGroupStart, rowTheme, toggledFavorites } from "../themePickerModel";
/** How long the pointer rests on a row before that row previews. */
export const DWELL_MS = 450;
/** appearance.favoriteThemes: the starred themes, shared by every theme picker on the page. */
export const FAVORITE_THEMES_KEY = "appearance.favoriteThemes";

/** The starred themes and the toggle every ThemePicker caller passes it; no toggle (no stars) while
 * the key is managed or the owner is away. An empty list resets the key. */
export function useThemeFavorites(): { favorites: readonly string[]; toggle?(name: string): void } {
  const store = useStore();
  const value = useSettingsSelector((state) => valueOf(state, FAVORITE_THEMES_KEY));
  const editable = useSettingsSelector(
    (state) => state.connected && state.readable && managedOf(state, FAVORITE_THEMES_KEY) === null,
  );
  const favorites = useMemo(
    () => (Array.isArray(value) ? value.filter((name): name is string => typeof name === "string") : []),
    [value],
  );
  if (!editable) return { favorites };
  const toggle = (name: string) => {
    const next = toggledFavorites(favorites, name);
    void (next.length > 0 ? store.set(FAVORITE_THEMES_KEY, next) : store.reset(FAVORITE_THEMES_KEY));
  };
  return { favorites, toggle };
}

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
  favorites = [],
  onToggleFavorite,
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
  /** The starred themes (appearance.favoriteThemes), listed first. */
  favorites?: readonly string[];
  /** Stars or unstars a theme; without it the rows have no star. */
  onToggleFavorite?(name: string): void;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [anchor, setAnchor] = useState<HTMLElement | null>(null);
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
  // The highlighted row, for Cmd-S.
  const highlighted = useRef<string | null>(null);
  const highlight = (row: string | undefined, by: "keyboard" | "pointer" | "none") => {
    const name = row && row !== CONFIG ? rowTheme(row) : undefined;
    highlighted.current = name ?? null;
    const target = name ?? pinned;
    if (by === "keyboard") return preview(target);
    // The pointer passing over, or the list re-highlighting its first row while typing: wait for a rest.
    cancelDwell();
    if (target === showing.current) return;
    dwell.current = setTimeout(() => preview(target), DWELL_MS);
  };
  const label = (name: string) => (custom(name) ? t("settingsPage.theme.custom", name) : name);
  const shown = pickerRows({ names, query, nullChoice, favorites });
  // The heading each group's first row carries (Starred, then All Themes).
  const headings = new Map<string, "starred" | "all">();
  shown.forEach((row, index) => {
    const start = rowGroupStart(shown, index);
    if (start) headings.set(row, start);
  });
  const starred = new Set(favorites);
  const star = (name: string) =>
    onToggleFavorite && (
      <button
        type="button"
        className="theme-option-star"
        data-theme-star={name}
        data-starred={starred.has(name) ? "" : undefined}
        aria-pressed={starred.has(name)}
        aria-label={t("settingsPage.theme.star", name)}
        aria-keyshortcuts="Meta+S"
        // The row's input keeps the focus and the row is not picked: the press stops here.
        tabIndex={-1}
        onMouseDown={(event) => {
          event.preventDefault();
          event.stopPropagation();
        }}
        onClick={(event) => {
          event.stopPropagation();
          onToggleFavorite(name);
        }}
      >
        <Icon name="star" />
      </button>
    );
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
  const pick = (row: string) => {
    const name = row === CONFIG ? row : rowTheme(row);
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
      <Button
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
      </Button>
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
          onCommand={(event) => {
            const name = highlighted.current;
            if (!onToggleFavorite || !name || !event.metaKey || event.key.toLowerCase() !== "s") return;
            event.preventDefault();
            event.preventBaseUIHandler?.();
            onToggleFavorite(name);
          }}
          itemLabel={(row) => (row === CONFIG ? configLabel : label(rowTheme(row)))}
          label={t("settingsWindow.themeSearch")}
          placeholder={t("settingsWindow.themeSearch")}
          inputClassName="field theme-search"
          listClassName="theme-list"
          itemClassName="theme-option"
          renderItem={(row) => {
            const name = rowTheme(row);
            const heading = headings.get(row);
            return name === CONFIG ? (
              <span className="theme-option-row">
                <ThemeBall colors={configColors} />
                <span className="theme-option-name">{configLabel}</span>
                {value === null && <Icon name="check" className="theme-option-check" />}
              </span>
            ) : (
              <span
                className="theme-option-row"
                data-theme-option={name}
                data-starred-row={row !== name ? "" : undefined}
                data-group-start={heading}
                data-previewing={name === pinned ? "" : undefined}
                onContextMenu={(event) => {
                  event.preventDefault();
                  setPinned(name);
                  preview(name);
                }}
              >
                {heading && (
                  <span className="theme-group-heading" aria-hidden="true">
                    {heading === "starred" ? t("settingsPage.theme.starred") : t("settingsPage.theme.allThemes")}
                  </span>
                )}
                <ThemeBall name={name} colors={colors?.get(name)} />
                <span className="theme-option-name">{label(name)}</span>
                {name === value && <Icon name="check" className="theme-option-check" />}
                {star(name)}
              </span>
            );
          }}
        />
        {shown.length === 0 && <output className="theme-empty empty block">{t("settingsPage.theme.noMatch")}</output>}
        <div className="theme-count">{t("settingsPage.theme.count", names.length)}</div>
      </Popover>
    </>
  );
}
