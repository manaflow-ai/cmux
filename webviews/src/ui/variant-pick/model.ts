/** Navigation changes focus only; the caller commits a pick on activation. */
export function moveVariant(ids: readonly string[], current: string | null, key: string, dir = "ltr"): string | null {
  if (!ids.length) return null;
  const index = current === null ? -1 : ids.indexOf(current);
  if (key === "Home" || index < 0) return ids[0]!;
  if (key === "End") return ids[ids.length - 1]!;
  const horizontal = dir === "rtl" ? -1 : 1;
  const step =
    key === "ArrowRight"
      ? horizontal
      : key === "ArrowLeft"
        ? -horizontal
        : key === "ArrowDown"
          ? 1
          : key === "ArrowUp"
            ? -1
            : 0;
  return ids[(index + step + ids.length) % ids.length]!;
}

export type PickContext = { entryId: string; threadId?: never } | { threadId: string; entryId?: never };
export type PickRecord = PickContext & {
  variantId: string;
  recommendedId?: string | null;
  who: string;
  when: string;
  note: string;
};

/** The beads sink returns authoritative identity/time; the feed consumes that receipt. */
export interface PickSink {
  record(pick: PickRecord): Promise<PickRecord>;
}
