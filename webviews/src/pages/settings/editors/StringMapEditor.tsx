import { useState } from "react";
import { useStore } from "../context";
import { Icon } from "../icons";
import { rowsByKey, type Choice } from "../schema";
import { t, text } from "../strings";
import { Select } from "./Select";
import type { EditorProps } from "./types";

/** The row whose choices a map's values take: `browser.siteEngines` maps a site to an engine. */
const VALUE_CHOICES: Readonly<Record<string, string>> = { "browser.siteEngines": "browser.defaultEngine" };

/** A map key such as `spotify.com` or `amazon.com/gp/video`: not empty, no spaces. */
function isMapKey(key: string): boolean {
  return key !== "" && !/\s/.test(key);
}

/**
 * A `string_map` row (browser.siteEngines): one line per key, in key order, with its value (a menu
 * when the values are fixed choices, else a text field) and Remove; the last line adds a key. Each
 * change writes the whole map, as cmux.json holds it.
 */
export function StringMapEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const map: Record<string, string> =
    typeof value === "object" && value !== null && !Array.isArray(value)
      ? Object.fromEntries(Object.entries(value).map(([key, item]) => [key, String(item)]))
      : {};
  const choices: Choice[] | undefined = rowsByKey.get(VALUE_CHOICES[row.key] ?? "")?.choices;
  const [draftKey, setDraftKey] = useState("");
  const [draftValue, setDraftValue] = useState(choices?.[0]?.value ?? "");
  const [invalid, setInvalid] = useState(false);
  const write = (next: Record<string, string>) => void store.set(row.key, next);
  const add = () => {
    const key = draftKey.trim();
    if (key === "") return;
    if (!isMapKey(key) || draftValue === "") return setInvalid(true);
    setInvalid(false);
    setDraftKey("");
    write({ ...map, [key]: draftValue });
  };
  const valueControl = (current: string, onChange: (next: string) => void) =>
    choices ? (
      <Select value={current} disabled={disabled} labelId={labelId} onChange={onChange}>
        {choices.map((choice) => (
          <option key={choice.value} value={choice.value}>
            {text(choice.title)}
          </option>
        ))}
      </Select>
    ) : (
      <input
        className="field text"
        type="text"
        spellCheck={false}
        value={current}
        disabled={disabled}
        aria-labelledby={labelId}
        onChange={(event) => onChange(event.currentTarget.value)}
      />
    );
  return (
    <span className="string-map" data-string-map="">
      {Object.keys(map)
        .sort()
        .map((key) => (
          <span key={key} className="string-map-item" data-map-key={key}>
            <span className="string-map-key selectable">{key}</span>
            {valueControl(map[key]!, (next) => write({ ...map, [key]: next }))}
            <button
              type="button"
              className="icon-button"
              aria-label={`${t("settingsPage.remove")} ${key}`}
              disabled={disabled}
              onClick={() => write(Object.fromEntries(Object.entries(map).filter(([item]) => item !== key)))}
            >
              <Icon name="xmark" />
            </button>
          </span>
        ))}
      {/* A form, so Return in the site field adds as the Add button does. */}
      <form
        className="string-map-item"
        onSubmit={(event) => {
          event.preventDefault();
          add();
        }}
      >
        <input
          className="field token-input"
          type="text"
          spellCheck={false}
          data-map-new-key=""
          value={draftKey}
          placeholder={t("settingsPage.hostPlaceholder")}
          disabled={disabled}
          aria-labelledby={labelId}
          aria-invalid={invalid}
          onChange={(event) => {
            setDraftKey(event.currentTarget.value);
            if (invalid) setInvalid(false);
          }}
        />
        <span data-map-new-value="">{valueControl(draftValue, setDraftValue)}</span>
        <button type="submit" className="button" data-map-add="" disabled={disabled}>
          {t("settingsPage.add")}
        </button>
      </form>
      {invalid && (
        <span className="field-error" role="alert">
          {t("settingsPage.invalidSite")}
        </span>
      )}
    </span>
  );
}
