// ↑ and ↓ in an empty prompt step through the chat's earlier prompts, newest first (Codex and
// Claude Code parity, cx-ncc.89). ↓ past the newest empties the prompt again. A recalled prompt
// the user edits is a draft from then on, which the arrows no longer replace.
import { useMemo, useRef } from "react";
import type { AcpmuxRow } from "../model";

type PromptGroup = {
  text: string;
  rowIds: string[];
};

type PromptHistory = {
  groups: PromptGroup[];
  byRowId: Map<string, PromptGroup>;
};

/// `shown`: a sent prompt as the field takes it back (a Codex skill's `/$name` read `/name`,
/// slashCommands.ts withoutSkillDollars), applied to a prompt only as it is recalled or compared.
export function usePromptHistory(rows: readonly AcpmuxRow[], shown: (sent: string) => string = (sent) => sent) {
  const history = useMemo<PromptHistory>(() => {
    const groups: PromptGroup[] = [];
    const byRowId = new Map<string, PromptGroup>();
    for (const row of rows) {
      // Another agent's message or a task's result is not a prompt the person wrote.
      const text = row.kind === "user" && !row.untyped ? row.text?.trim() : undefined;
      // The same prompt sent twice in a row is one step.
      if (!text) continue;
      const last = groups.at(-1);
      const group = last?.text === text ? last : { text, rowIds: [] };
      if (group !== last) groups.push(group);
      group.rowIds.push(row.id);
      byRowId.set(row.id, group);
    }
    return { groups, byRowId };
  }, [rows]);
  const recalled = useRef<{ rowId: string; text: string } | undefined>(undefined);
  const anchorGroup = () => {
    const anchor = recalled.current;
    if (!anchor) return undefined;
    const group = history.byRowId.get(anchor.rowId);
    // A page can be replaced or an edited row can change its text while the composer is open.
    // In either case the old browsing position no longer has a stable history anchor.
    if (!group || group.text !== anchor.text) {
      recalled.current = undefined;
      return undefined;
    }
    return group;
  };
  /// Whether the prompt still shows what the arrows brought back. `current` gives the prompt as
  /// the agent would get it (the field escapes `[`, `*`, URLs); it runs only while one is shown.
  const showing = (current: () => string) => {
    const group = anchorGroup();
    return group !== undefined && shown(group.text) === current().trim();
  };
  /// What ↑ (-1) or ↓ (+1) writes over `current`: undefined when the key is not history's, null
  /// when it is but nothing changes (↑ on the oldest).
  const step = (direction: -1 | 1, current: string): string | null | undefined => {
    const browsing = showing(() => current) ? anchorGroup() : undefined;
    // Text that no longer shows the recalled prompt ends browsing: drop the anchor so a later
    // edit back to that text is the caret's, not history's.
    if (!browsing) recalled.current = undefined;
    if (!browsing && current.trim()) return undefined;
    const index = (browsing ? history.groups.indexOf(browsing) : history.groups.length) + direction;
    // ↑ on the oldest keeps it; ↓ with nothing recalled is the caret's.
    if (index < 0) return browsing ? null : undefined;
    if (index >= history.groups.length) {
      recalled.current = undefined;
      return browsing ? "" : undefined;
    }
    const group = history.groups[index];
    const rowId = group?.rowIds.at(-1);
    if (!group || !rowId) return undefined;
    recalled.current = { rowId, text: group.text };
    return shown(group.text);
  };
  /// The recalled prompt as it was sent, while one shows.
  const recalledRaw = () => anchorGroup()?.text;
  return { showing, step, recalledRaw };
}
