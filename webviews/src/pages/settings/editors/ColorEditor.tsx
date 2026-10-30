import { useState } from "react";
import { useStore } from "../context";
import { inheritsWindowColor } from "../inheritance";
import { t, text } from "../strings";
import { isHexColor } from "../validate";
import type { EditorProps } from "./types";

/** The window's own color, which an unset surface color shows in its swatch. */
const WINDOW_COLOR = "var(--cmux-window-background, var(--cmux-surface-background, Canvas))";

function normalized(input: string): string {
  const trimmed = input.trim();
  return trimmed.startsWith("#") ? trimmed.toUpperCase() : `#${trimmed.toUpperCase()}`;
}

/**
 * Swatch (the native color well) + hex field + "Use Theme Color", which resets the key.
 * The well previews while its panel moves and commits on the native `change` event.
 */
export function ColorEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const [draft, setDraft] = useState<string | null>(null);
  const [invalid, setInvalid] = useState(false);
  const stored = typeof value === "string" ? normalized(value) : "";
  const alpha = stored.length === 9 ? stored.slice(7) : "";
  /** Writes `input`; resolves once the write settles (at once when there is nothing to write). */
  const commit = async (input: string) => {
    setDraft(null);
    if (input.trim() === "" || normalized(input) === stored) return setInvalid(false);
    if (!isHexColor(input.trim())) return setInvalid(true);
    setInvalid(false);
    await store.set(row.key, normalized(input));
  };
  const wellRef = (well: HTMLInputElement | null) => {
    if (!well) return;
    // Write first, then end the preview, so the app never flashes the old color (as NumberEditor).
    const onChange = () => void commit(well.value + alpha).finally(() => store.previewEnd(row.key));
    well.addEventListener("change", onChange);
    return () => well.removeEventListener("change", onChange);
  };
  // A surface color while unset shows the window's color, dimmed, with a badge (never the
  // default label squeezed into the hex field).
  const inherited = stored === "" && draft === null && inheritsWindowColor(row.key);
  return (
    <span className="color-editor" data-inherited={inherited ? "" : undefined}>
      {inherited && <span className="inherit-badge">{t("settingsPage.inheritsWindow")}</span>}
      {inherited && (
        <svg className="swatch-inherited" aria-hidden="true" viewBox="0 0 26 22">
          <rect width="26" height="22" rx="5" fill={WINDOW_COLOR} />
        </svg>
      )}
      <input
        ref={wellRef}
        type="color"
        className="swatch"
        data-swatch=""
        value={stored ? stored.slice(0, 7).toLowerCase() : "#808080"}
        disabled={disabled}
        aria-labelledby={labelId}
        onChange={(event) => store.preview(row.key, normalized(event.currentTarget.value) + alpha)}
      />
      <input
        className="field hex"
        type="text"
        spellCheck={false}
        value={draft ?? stored}
        placeholder={inherited ? "" : text(row.default_label)}
        disabled={disabled}
        aria-labelledby={labelId}
        aria-invalid={invalid}
        onChange={(event) => setDraft(event.currentTarget.value)}
        onBlur={(event) => void commit(event.currentTarget.value)}
        onKeyDown={(event) => {
          if (event.key === "Enter") void commit(event.currentTarget.value);
        }}
      />
      {invalid && (
        <span className="field-error" role="alert">
          {t("settingsPage.invalidColor")}
        </span>
      )}
    </span>
  );
}
