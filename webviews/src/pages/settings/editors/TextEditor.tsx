import { useState } from "react";
import { useStore } from "../context";
import { text } from "../strings";
import type { EditorProps } from "./types";

/**
 * A text field committed on Return or blur. `check` refuses a value before it is sent and
 * names the message to show; url rows use it, domain rows without published names do not.
 */
export function TextEditor({
  row,
  value,
  disabled,
  labelId,
  check,
}: EditorProps & { check?: (input: string) => string | null }) {
  const store = useStore();
  const [draft, setDraft] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const stored = typeof value === "string" ? value : "";
  const commit = () => {
    if (draft === null) return;
    const next = draft.trim();
    const refused = check?.(next) ?? null;
    setProblem(refused);
    if (refused) return;
    setDraft(null);
    if (next !== stored) void (next === "" && row.default === null ? store.reset(row.key) : store.set(row.key, next));
  };
  return (
    <span className="text-editor">
      <input
        className="field text"
        type="text"
        spellCheck={false}
        value={draft ?? stored}
        placeholder={text(row.default_label)}
        disabled={disabled}
        aria-labelledby={labelId}
        aria-invalid={problem !== null}
        onChange={(event) => setDraft(event.currentTarget.value)}
        onBlur={commit}
        onKeyDown={(event) => {
          if (event.key === "Enter") commit();
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
