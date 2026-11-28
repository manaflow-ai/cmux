// One theme choice of the Theme section: a button with the theme's swatch and name, and a popover
// to search every bundled theme. The highlighted row (the pointer or the arrow keys) previews in the
// section's hero and live in the app (onPreview) until the popover closes; a right-click pins a row's
// preview so it stays while the pointer moves on. Return or a click picks; Escape reverts.
import { useEffect, useRef, useState } from "react";
import { Combobox } from "../../../ui/Combobox";
import { Popover } from "../../../ui/Popover";
import { ThemeBall } from "../../../ui/ThemeBall";
import type { GhosttyTheme } from "../../../theme/ghosttyTheme";
import { Icon } from "../icons";
import { t } from "../strings";

const CONFIG = "\u0000config";

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
  onPreview(name: string | null): void;
  /** Whether a theme has the user's color edits (appearance.themeEdits): it reads "<name> (custom)". */
  custom?(name: string): boolean;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [anchor, setAnchor] = useState<HTMLButtonElement | null>(null);
  // The right-clicked theme: previewed whenever no row is highlighted.
  const [pinned, setPinned] = useState<string | null>(null);
  // A live preview is showing in the app; it must end even if the picker goes away while open.
  const showing = useRef(false);
  const preview = (name: string | null) => {
    showing.current = name !== null;
    onPreview(name);
  };
  const end = useRef(() => {});
  end.current = () => {
    if (showing.current) preview(null);
  };
  useEffect(() => () => end.current(), []);
  const typed = query.trim().toLowerCase();
  const label = (name: string) => (custom(name) ? t("settingsPage.theme.custom", name) : name);
  const shown = [CONFIG, ...names.filter((name) => name.toLowerCase().includes(typed))].filter(
    (name) => name !== CONFIG || typed === "",
  );
  const dismiss = () => {
    setOpen(false);
    setQuery("");
    setPinned(null);
  };
  const close = () => {
    dismiss();
    preview(null);
  };
  // Disabled while open (the key became managed, the host disconnected) closes it too.
  useEffect(() => {
    if (disabled && open) close();
  });
  // Write first, then end the preview: the app goes from the preview to the same saved theme,
  // never back to the old one in between.
  const pick = (name: string) => {
    dismiss();
    const chosen = name === CONFIG ? null : names.includes(name) ? name : undefined;
    if (chosen === undefined) return preview(null);
    void Promise.resolve(onPick(chosen)).finally(() => preview(null));
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
          onHighlight={(name) => preview(name && name !== CONFIG ? name : pinned)}
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
