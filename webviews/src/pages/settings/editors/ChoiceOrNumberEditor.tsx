import { useState } from "react";
import { useStore } from "../context";
import { t, text } from "../strings";
import { NumberField } from "./NumberField";
import { Select } from "./Select";
import type { EditorProps } from "./types";

const custom = "__custom__";

/** A menu of named choices plus "Custom…", which shows a number field. */
export function ChoiceOrNumberEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const [customPicked, setCustomPicked] = useState(false);
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
          if (next !== custom) void store.set(row.key, next);
        }}
      >
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
