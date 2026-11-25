// The ended todo lists the reader opened (PlanList.tsx), by plan row id, for this page's life: a
// list that scrolls out and back, or whose turn draws again, keeps the state it was left in, and
// the row height estimate (model.ts) reads it too. Bounded: the oldest opened ids go first.
const OPEN_LIMIT = 256;
const opened = new Set<string>();

export const planOpen = (id: string | undefined): boolean => id !== undefined && opened.has(id);

export function setPlanOpen(id: string | undefined, open: boolean): void {
  if (id === undefined) return;
  opened.delete(id);
  if (!open) return;
  opened.add(id);
  if (opened.size > OPEN_LIMIT) opened.delete(opened.values().next().value!);
}
