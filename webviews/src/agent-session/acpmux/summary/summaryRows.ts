// Stub (red commit): the typed rows of a pinned summary section.
export type SummaryProvenance = "builtin" | "user" | "agent";
export type SummaryRowState = "ok" | "warn" | "error" | "running";
export type SummaryRowInput = {
  title?: unknown;
  subtitle?: unknown;
  icon?: unknown;
  href?: unknown;
  badge?: unknown;
  state?: unknown;
};
export type SummarySectionInput = {
  id: string;
  title: string;
  source: SummaryProvenance;
  rows?: readonly SummaryRowInput[];
  error?: string;
};
export type SummaryLink = { kind: "url"; url: string; host: string; confirm: boolean } | { kind: "path"; path: string };
export type SummaryRow = {
  key: string;
  title: string;
  subtitle?: string;
  badge?: string;
  state?: SummaryRowState;
  link?: SummaryLink;
};
export type SummaryCustomSection = {
  id: string;
  title: string;
  source: SummaryProvenance;
  rows: SummaryRow[];
  error?: string;
};
export const MAX_ROWS = 50;
export function sanitizeSection(input: SummarySectionInput, _folder?: string): SummaryCustomSection {
  return { id: input.id, title: input.title, source: input.source, rows: [] };
}
