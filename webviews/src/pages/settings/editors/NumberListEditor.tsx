import { useState } from "react";
import { useStore } from "../context";
import { displayNumber, parseNumber } from "../format";
import { Icon } from "../icons";
import { t } from "../strings";
import type { EditorProps } from "./types";

/** Number tokens (editor.rulers): Return or comma adds a number in the row's range, Backspace in an
 * empty field removes the last one. The list keeps the user's order and drops repeats. */
export function NumberListEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const numbers = Array.isArray(value) ? value.filter((item): item is number => typeof item === "number") : [];
  const [draft, setDraft] = useState("");
  const [invalid, setInvalid] = useState(false);
  const write = (next: number[]) => void store.set(row.key, next);
  const add = () => {
    const text = draft.trim().replace(/,$/, "");
    if (text === "") return;
    const parsed = parseNumber(text, row.range);
    const inRange =
      parsed !== null &&
      (row.range?.min === undefined || parsed >= row.range.min) &&
      (row.range?.max === undefined || parsed <= row.range.max);
    if (!inRange) return setInvalid(true);
    setInvalid(false);
    setDraft("");
    if (!numbers.includes(parsed)) write([...numbers, parsed]);
  };
  return (
    <span className="host-list number-list">
      <span className="tokens">
        {numbers.map((number) => {
          const label = displayNumber(number, row.range);
          return (
            <span key={number} className="token">
              {label}
              <button
                type="button"
                className="token-remove"
                aria-label={`${t("settingsPage.remove")} ${label}`}
                disabled={disabled}
                onClick={() => write(numbers.filter((item) => item !== number))}
              >
                <Icon name="xmark" />
              </button>
            </span>
          );
        })}
        <input
          className="field token-input"
          type="text"
          inputMode="decimal"
          spellCheck={false}
          value={draft}
          disabled={disabled}
          aria-labelledby={labelId}
          aria-invalid={invalid}
          onChange={(event) => {
            setDraft(event.currentTarget.value);
            if (invalid) setInvalid(false);
          }}
          onBlur={add}
          // ui-allow: the token field's own editing keys (Return or comma adds the number, Backspace in an empty field removes the last).
          onKeyDown={(event) => {
            if (event.key === "Enter" || event.key === ",") {
              event.preventDefault();
              add();
            } else if (event.key === "Backspace" && draft === "" && numbers.length > 0 && !event.metaKey) {
              write(numbers.slice(0, -1));
            }
          }}
        />
      </span>
      {invalid && (
        <span className="field-error" role="alert">
          {t("settingsPage.invalidValue")}
        </span>
      )}
    </span>
  );
}
