import { useState } from "react";
import { useStore } from "../context";
import { t, text } from "../strings";
import { NumberField } from "./NumberField";
import { Select } from "./Select";
import type { EditorProps } from "./types";

const custom = "__custom__";

/**
 * A menu of named choices plus "Custom…", which shows a number field. A row whose default is
 * "unset" (`browser.hibernation`: never discard) lists that first, by its label; picking it
 * removes the key.
 */
export function ChoiceOrNumberEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const [customPicked, setCustomPicked] = useState(false);
  // A new value from outside the menu (Reset, another client) ends a Custom… pick that wrote
  // nothing, so a reset row shows its default instead of an empty number field.
  const [seenValue, setSeenValue] = useState(value);
  if (!Object.is(seenValue, value)) {
    setSeenValue(value);
    if (customPicked) setCustomPicked(false);
  }
  const isNumber = typeof value === "number";
  const showCustom = isNumber || customPicked;
  return (
    <span className="choice-or-number">
      <Select
        value={showCustom ? custom : String(value ?? "")}
        disabled={disabled}
        labelId={labelId}
        onChange={(next) => {
          setCustomPicked(next === custom);
          if (next === "" && row.default === null) void store.reset(row.key);
          else if (next !== custom) void store.set(row.key, next);
        }}
      >
        {row.default === null && <option value="">{text(row.default_label)}</option>}
        {(row.choices ?? []).map((choice) => (
          <option key={choice.value} value={choice.value}>
            {text(choice.title)}
          </option>
        ))}
        <option value={custom}>{t("settingsPage.custom")}</option>
      </Select>
      {showCustom && (
        <NumberField
          value={isNumber ? value : null}
          range={row.range}
          placeholder={String(row.range?.placeholder ?? "")}
          disabled={disabled}
          labelId={labelId}
          onCommit={(next) => void store.set(row.key, next)}
        />
      )}
    </span>
  );
}
