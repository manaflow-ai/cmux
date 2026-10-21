// ↑ and ↓ in an empty prompt step through the chat's earlier prompts, newest first (Codex and
// Claude Code parity, cx-ncc.89). ↓ past the newest empties the prompt again. A recalled prompt
// the user edits is a draft from then on, which the arrows no longer replace.
import { useMemo, useRef } from "react";
import type { AcpmuxRow } from "../model";

export function usePromptHistory(rows: readonly AcpmuxRow[]) {
  const prompts = useMemo(() => {
    const sent: string[] = [];
    for (const row of rows) {
      // Another agent's message or a task's result is not a prompt the person wrote.
      const text = row.kind === "user" && !row.untyped ? row.text?.trim() : undefined;
      // The same prompt sent twice in a row is one step.
      if (text && sent[sent.length - 1] !== text) sent.push(text);
    }
    return sent;
  }, [rows]);
  const recalled = useRef<{ index: number; text: string } | undefined>(undefined);
  /// Whether the prompt still shows what the arrows brought back. `current` gives the prompt as
  /// the agent would get it (the field escapes `[`, `*`, URLs); it runs only while one is shown.
  const showing = (current: () => string) =>
    recalled.current !== undefined && recalled.current.text === current().trim();
  /// What ↑ (-1) or ↓ (+1) writes over `current`: undefined when the key is not history's, null
  /// when it is but nothing changes (↑ on the oldest).
  const step = (direction: -1 | 1, current: string): string | null | undefined => {
    const browsing = showing(() => current) ? recalled.current : undefined;
    recalled.current = browsing;
    if (!browsing && current.trim()) return undefined;
    const index = (browsing?.index ?? prompts.length) + direction;
    // ↑ on the oldest keeps it; ↓ with nothing recalled is the caret's.
    if (index < 0) return browsing ? null : undefined;
    if (index >= prompts.length) {
      recalled.current = undefined;
      return browsing ? "" : undefined;
    }
    recalled.current = { index, text: prompts[index]! };
    return prompts[index];
  };
  return { showing, step };
}
