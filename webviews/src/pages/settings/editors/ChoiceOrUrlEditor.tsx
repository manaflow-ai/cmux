import { useState } from "react";
import { useStore } from "../context";
import { t, text } from "../strings";
import { isHttpOrigin } from "../validate";
import { Select } from "./Select";
import type { EditorProps } from "./types";

const address = "__address__";

/** The address an object value names (`{[url_key]: url}`), else null. */
function storedAddress(value: unknown, key: string): string | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const url = (value as Record<string, unknown>)[key];
  return typeof url === "string" ? url : null;
}

/**
 * A menu of named choices plus "Self-Hosted Server…", which shows an address field
 * (`home.server`: cmux Cloud, or `{"selfHosted": "http://mini.tail1234.ts.net:7320"}`).
 */
export function ChoiceOrUrlEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const key = row.url_key ?? "url";
  const stored = storedAddress(value, key);
  const [addressPicked, setAddressPicked] = useState(false);
  const [draft, setDraft] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  // A new stored value (a Reset, a host update) ends the address being typed and the pick of the
  // address field that went with the old one.
  const [seen, setSeen] = useState(JSON.stringify(value ?? null));
  if (seen !== JSON.stringify(value ?? null)) {
    setSeen(JSON.stringify(value ?? null));
    setAddressPicked(false);
    setDraft(null);
    setProblem(null);
  }
  const showAddress = stored !== null || addressPicked;
  const commit = () => {
    if (draft === null) return;
    const next = draft.trim();
    const refused = isHttpOrigin(next) ? null : t("settingsPage.invalidUrl");
    setProblem(refused);
    if (refused) return;
    setDraft(null);
    if (next !== stored) void store.set(row.key, { [key]: next });
  };
  return (
    <span className="choice-or-url">
      <Select
        value={showAddress ? address : String(value ?? "")}
        disabled={disabled}
        labelId={labelId}
        onChange={(next) => {
          setAddressPicked(next === address);
          setProblem(null);
          if (next !== address) void store.set(row.key, next);
        }}
      >
        {(row.choices ?? []).map((choice) => (
          <option key={choice.value} value={choice.value}>
            {text(choice.title)}
          </option>
        ))}
        <option value={address}>{t("settingsPage.selfHostedServer")}</option>
      </Select>
      {showAddress && (
        // A form, so Return in the address field commits it (implicit submission), as a blur does.
        <form
          className="text-editor"
          onSubmit={(event) => {
            event.preventDefault();
            commit();
          }}
        >
          <input
            className="field text"
            type="text"
            spellCheck={false}
            value={draft ?? stored ?? ""}
            placeholder="http://mini.tail1234.ts.net:7320"
            disabled={disabled}
            aria-labelledby={labelId}
            aria-invalid={problem !== null}
            onChange={(event) => setDraft(event.currentTarget.value)}
            onBlur={commit}
            onKeyDown={(event) => {
              if (event.key === "Escape" && (draft !== null || problem !== null)) {
                // Cancels the edit: blur must not commit what was typed.
                event.stopPropagation();
                setDraft(null);
                setProblem(null);
              }
            }}
          />
          {problem && (
            <span className="field-error" role="alert">
              {problem}
            </span>
          )}
        </form>
      )}
    </span>
  );
}
