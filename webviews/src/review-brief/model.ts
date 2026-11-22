// A chat's review brief (acpmux `_acpmux/review_brief`, `review_brief.rs`): what the agent set out
// to do, what it dropped and where it was unsure, each unsure spot linked to a file of the diff.
// Pure: the diff page (diff-viewer/useReviewBrief.ts) and any other surface (a review queue) parse
// the same answer and find a spot's hunk the same way.

/** Why a spot is in the brief: the agent's own hedge, or an edit it undid, redid or rewrote. */
export type BriefSpotKind = "hedge" | "reverted" | "redone" | "reworked";

export type BriefSpot = {
  kind: BriefSpotKind;
  /** The hedge's sentence; empty for an edit's spot. */
  text: string;
  /** The file, relative to the diff's repository root; empty when none is known. */
  path: string;
  line?: number;
  /** The edit's first changed line, which finds the hunk. */
  snippet: string;
  /** How many times the text was rewritten (reworked). */
  count: number;
  seq: number;
};

export type BriefPlanItem = { content: string; status: string };
export type BriefNote = { text: string; seq: number };

export type ReviewBrief = {
  goal: string;
  planText: string;
  plan: BriefPlanItem[];
  rejected: BriefNote[];
  unsure: BriefSpot[];
};

const KINDS: readonly BriefSpotKind[] = ["hedge", "reverted", "redone", "reworked"];
/** The daemon caps its lists; the page caps again so a bad answer cannot grow the panel. */
const MAX_ROWS = 24;

const str = (value: unknown): string => (typeof value === "string" ? value : "");
const num = (value: unknown): number => (typeof value === "number" && Number.isFinite(value) ? value : 0);
const rows = (value: unknown): Record<string, unknown>[] =>
  Array.isArray(value)
    ? value.filter((row): row is Record<string, unknown> => row != null && typeof row === "object").slice(0, MAX_ROWS)
    : [];

/** The brief of an `_acpmux/review_brief` answer (`{sessionId, seq, brief}`, or the brief itself);
 * null when it is not one. */
export function parseReviewBrief(answer: unknown): ReviewBrief | null {
  if (answer == null || typeof answer !== "object") return null;
  const outer = answer as Record<string, unknown>;
  const value = (outer.brief && typeof outer.brief === "object" ? outer.brief : outer) as Record<string, unknown>;
  if (!("goal" in value) && !("unsure" in value)) return null;
  return {
    goal: str(value.goal),
    planText: str(value.planText),
    plan: rows(value.plan)
      .map((row) => ({ content: str(row.content), status: str(row.status) }))
      .filter((item) => item.content !== ""),
    rejected: rows(value.rejected)
      .map((row) => ({ text: str(row.text), seq: num(row.seq) }))
      .filter((note) => note.text !== ""),
    unsure: rows(value.unsure).flatMap((row): BriefSpot[] => {
      const kind = KINDS.find((k) => k === row.kind);
      if (!kind) return [];
      const line = num(row.line);
      return [
        {
          kind,
          text: str(row.text),
          path: str(row.path),
          ...(line > 0 ? { line } : {}),
          snippet: str(row.snippet),
          count: num(row.count),
          seq: num(row.seq),
        },
      ];
    }),
  };
}

/** Nothing to show: no goal, plan, dropped approach or unsure spot. */
export function isEmptyBrief(brief: ReviewBrief): boolean {
  return (
    brief.goal === "" &&
    brief.planText === "" &&
    brief.plan.length === 0 &&
    brief.rejected.length === 0 &&
    brief.unsure.length === 0
  );
}

/** The hunk shape a spot's line is found in (Pierre's parsed file diff). */
type FileLines = {
  hunks?: readonly {
    additionStart: number;
    additionCount: number;
    additionLineIndex: number;
    deletionStart: number;
    deletionCount: number;
    deletionLineIndex: number;
  }[];
  additionLines?: readonly string[];
  deletionLines?: readonly string[];
};

/** Where a snippet is in a parsed file diff: the new side first (the change as it stands), then the
 * old side (text an undo took out). Undefined when it is in no hunk. */
export function snippetLine(
  fileDiff: unknown,
  snippet: string,
): { lineNumber: number; side: "additions" | "deletions" } | undefined {
  const wanted = snippet.replace(/…$/, "").trim();
  if (wanted === "" || fileDiff == null || typeof fileDiff !== "object") return undefined;
  const file = fileDiff as FileLines;
  const hunks = Array.isArray(file.hunks) ? file.hunks : [];
  const find = (side: "additions" | "deletions") => {
    const lines = side === "additions" ? file.additionLines : file.deletionLines;
    if (!Array.isArray(lines)) return undefined;
    for (const hunk of hunks) {
      const [start, count, index] =
        side === "additions"
          ? [hunk.additionStart, hunk.additionCount, hunk.additionLineIndex]
          : [hunk.deletionStart, hunk.deletionCount, hunk.deletionLineIndex];
      for (let k = 0; k < count; k += 1) {
        const text = lines[index + k];
        if (typeof text === "string" && text.trim().startsWith(wanted)) return { lineNumber: start + k, side };
      }
    }
    return undefined;
  };
  return find("additions") ?? find("deletions");
}

/** A spot's place in the diff: the file's item, and the line when its snippet is in a hunk (else
 * the spot's own line on the new side). Undefined when the file is not in this diff. */
export function spotTarget<T extends { id: string; fileDiff?: unknown }>(
  items: readonly T[],
  spot: BriefSpot,
  itemIdOf: (items: readonly T[], path: string) => string | undefined,
): { itemId: string; lineNumber?: number; side?: "additions" | "deletions" } | undefined {
  if (spot.path === "") return undefined;
  const itemId = itemIdOf(items, spot.path);
  if (itemId == null) return undefined;
  const item = items.find((entry) => entry.id === itemId);
  const found = snippetLine(item?.fileDiff, spot.snippet);
  if (found) return { itemId, ...found };
  return spot.line ? { itemId, lineNumber: spot.line, side: "additions" } : { itemId };
}
