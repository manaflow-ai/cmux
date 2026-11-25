import { useState } from "react";
import { useStore } from "../context";
import { t } from "../strings";
import { validate } from "../validate";
import type { EditorProps } from "./types";

/**
 * A `json` row that has no editor of its own: its value as JSON text, committed on blur or
 * Cmd-Return, Escape drops the edit. The page checks only that it parses and has the shape's top
 * level type; the daemon checks the rest and its refusal shows under the row's title. Empty text
 * resets the row.
 */
export function JsonEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const stored = value === null || value === undefined ? "" : JSON.stringify(value, null, 2);
  const [draft, setDraft] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [seen, setSeen] = useState(stored);
  if (seen !== stored) {
    setSeen(stored);
    setDraft(null);
    setProblem(null);
  }
  const commit = () => {
    if (draft === null) return;
    if (draft.trim() === "") {
      setDraft(null);
      setProblem(null);
      if (stored !== "") void store.reset(row.key);
      return;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(draft);
    } catch {
      setProblem(t("settingsPage.rowLayout.json.invalid"));
      return;
    }
    if (validate(row, parsed) !== null) {
      setProblem(
        t(row.shape?.type === "object" ? "settingsPage.rowLayout.json.object" : "settingsPage.rowLayout.json.list"),
      );
      return;
    }
    setProblem(null);
    setDraft(null);
    if (JSON.stringify(parsed) !== JSON.stringify(value)) void store.set(row.key, parsed);
  };
  return (
    <span className="json-editor">
      <textarea
        className="ui-field field json-field"
        spellCheck={false}
        rows={Math.min(8, Math.max(2, (draft ?? stored).split("\n").length))}
        value={draft ?? stored}
        placeholder={row.shape?.type === "object" ? "{}" : "[]"}
        disabled={disabled}
        aria-labelledby={labelId}
        aria-invalid={problem !== null}
        onChange={(event) => setDraft(event.currentTarget.value)}
        onBlur={commit}
        onKeyDown={(event) => {
          if (event.key === "Enter" && event.metaKey) {
            event.preventDefault();
            commit();
          } else if (event.key === "Escape" && (draft !== null || problem !== null)) {
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
    </span>
  );
}
