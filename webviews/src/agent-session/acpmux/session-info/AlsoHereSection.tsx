// Session Info's "Also working here" (alsoHere.ts): the other live chats in this chat's worktree or
// folder, or on its feature branch, each a row that opens that chat (ChildSessionRows.tsx, the rows
// Subagents draws). A peer's chat names its machine. Absent when there is none.
import { ChildSessionRows } from "./ChildSessionRows";
import type { AlsoHere } from "./alsoHere";
import { alsoHereRow } from "./alsoHereSectionModel";

export function AlsoHereSection({ rows, onOpen }: { rows: readonly AlsoHere[]; onOpen?: (sessionId: string) => void }) {
  return (
    <ul className="acpmux-summary-list" data-also-here="">
      {/* However many chats, it draws the rows that can show: ChildSessionRows windows them (WindowedRows). */}
      <ChildSessionRows sessions={rows.map(alsoHereRow)} onOpen={onOpen} />
    </ul>
  );
}
