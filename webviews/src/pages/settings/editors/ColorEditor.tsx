import { useState } from "react";
import { useStore } from "../context";
import { t, text } from "../strings";
import { isHexColor } from "../validate";
import type { EditorProps } from "./types";

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
  const commit = (input: string) => {
    setDraft(null);
    if (input.trim() === "" || normalized(input) === stored) return setInvalid(false);
    if (!isHexColor(input.trim())) return setInvalid(true);
    setInvalid(false);
    void store.set(row.key, normalized(input));
  };
  const wellRef = (well: HTMLInputElement | null) => {
    if (!well) return;
    const onChange = () => {
      store.previewEnd(row.key);
      commit(well.value + alpha);
    };
    well.addEventListener("change", onChange);
    return () => well.removeEventListener("change", onChange);
  };
  return (
    <span className="color-editor">
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
        placeholder={text(row.default_label)}
        disabled={disabled}
        aria-labelledby={labelId}
        aria-invalid={invalid}
        onChange={(event) => setDraft(event.currentTarget.value)}
        onBlur={(event) => commit(event.currentTarget.value)}
        onKeyDown={(event) => {
          if (event.key === "Enter") commit(event.currentTarget.value);
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
