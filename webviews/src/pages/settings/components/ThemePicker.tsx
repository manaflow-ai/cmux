// One theme choice of the Theme section: a button with the theme's swatch and name, and a popover
// to search every bundled theme. The highlighted row previews in the section's hero (onPreview)
// and live in the app (cmux.settings.preview) until the popover closes; Return or a click picks.
import { useState } from "react";
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
  onPick(name: string | null): void;
  /** The highlighted row while the list is open; null when it closes or nothing is highlighted. */
  onPreview(name: string | null): void;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [anchor, setAnchor] = useState<HTMLButtonElement | null>(null);
  const typed = query.trim().toLowerCase();
  const shown = [CONFIG, ...names.filter((name) => name.toLowerCase().includes(typed))].filter(
    (name) => name !== CONFIG || typed === "",
  );
  const close = () => {
    setOpen(false);
    setQuery("");
    onPreview(null);
  };
  const pick = (name: string) => {
    close();
    if (name === CONFIG) onPick(null);
    else if (names.includes(name)) onPick(name);
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
        <span className="theme-button-name">{value ?? configLabel}</span>
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
          onHighlight={(name) => onPreview(name && name !== CONFIG ? name : null)}
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
              <span className="theme-option-row" data-theme-option={name}>
                <ThemeBall name={name} colors={colors?.get(name)} />
                <span className="theme-option-name">{name}</span>
                {name === value && <Icon name="check" className="theme-option-check" />}
              </span>
            )
          }
        />
        <div className="theme-count">{t("settingsPage.theme.count", names.length)}</div>
      </Popover>
    </>
  );
}
