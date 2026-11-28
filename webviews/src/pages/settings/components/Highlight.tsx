import { queryTerms } from "../search";

/** `text` with every occurrence of the query's terms wrapped in <mark>. */
export function Highlight({ text, query }: { text: string; query: string }) {
  const terms = queryTerms(query);
  if (terms.length === 0) return text;
  const pattern = new RegExp(`(${terms.map((term) => term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})`, "gi");
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
