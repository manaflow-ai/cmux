// Search across every section by title, help, keywords, key and current value, in the page's
// language and in English. Every whitespace-separated term must match somewhere.
import { valueText } from "./format";
import { schema, sections, type SchemaRow, type SchemaSection } from "./schema";
import { text } from "./strings";

export function queryTerms(query: string): string[] {
  return query.toLowerCase().split(/\s+/).filter(Boolean);
}

export function rowMatches(row: SchemaRow, value: unknown, terms: string[]): boolean {
  if (terms.length === 0) return false;
  const haystack = [
    text(row.title),
    row.title.text,
    text(row.help),
    row.help?.text ?? "",
    row.key,
    ...row.keywords,
    valueText(row, value),
  ]
    .join("\n")
    .toLowerCase();
  return terms.every((term) => haystack.includes(term));
}

export type SearchGroup = { section: SchemaSection; rows: SchemaRow[] };

export function searchRows(query: string, valueOf: (key: string) => unknown): SearchGroup[] {
  const terms = queryTerms(query);
  return sections
    .map((section) => ({
      section,
      rows: schema.rows.filter((row) => row.section === section.id && rowMatches(row, valueOf(row.key), terms)),
    }))
    .filter((group) => group.rows.length > 0);
}
