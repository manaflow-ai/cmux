import { queryTerms } from "../search";

const escaped = (term: string) => term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** The query's terms that mark something in `texts` (Highlight's own match), as a query. Highlight
 * marks the same with it, and it stays equal while a keystroke changes only terms these texts do
 * not show (a row matched on its help or keywords), so the row's props stay equal. */
export function markingQuery(query: string, texts: readonly string[]): string {
  return queryTerms(query)
    .filter((term) => {
      const pattern = new RegExp(escaped(term), "i");
      return texts.some((one) => pattern.test(one));
    })
    .join(" ");
}

/** `text` with every occurrence of the query's terms wrapped in <mark>. */
export function Highlight({ text, query }: { text: string; query: string }) {
  const terms = queryTerms(query);
  if (terms.length === 0) return text;
  const pattern = new RegExp(`(${terms.map(escaped).join("|")})`, "gi");
  const parts = text.split(pattern);
  return (
    <>
      {parts.map((part, index) =>
        index % 2 === 1 ? (
          // oxlint-disable-next-line react/no-array-index-key -- parts are positional and static
          <mark key={index}>{part}</mark>
        ) : (
          part
        ),
      )}
    </>
  );
}
