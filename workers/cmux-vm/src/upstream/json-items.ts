/**
 * Reads the objects of one top-level array field of a JSON document as its text streams in, holding only the item being
 * read: a listing far larger than the 1 MiB a whole provider reply may be (live-http.ts) is read item by item, and only
 * what `onItem` keeps of each stays in memory. Used for the provider's tunnel listing, which has no paging
 * (src/upstream/orphan-sweep.ts).
 *
 * The document must be an object whose `field` is an array of objects; any other shape, an item over `maxItemChars`,
 * or a document that ends early fails. Other fields are skipped without being kept.
 */

export class JsonItemsError extends Error {}

/** Longest key the scanner compares; a longer one never matches `field`. */
const MAX_KEY_CHARS = 256;

export interface JsonItemsScanner {
  /** The next piece of the document's text. */
  readonly feed: (text: string) => void;
  /** The document ended: throws unless it was complete and had the field. */
  readonly end: () => void;
}

export const jsonItemsScanner = (field: string, maxItemChars: number, onItem: (item: unknown) => void): JsonItemsScanner => {
  let depth = 0;
  let inString = false;
  let escape = false;
  /** The key being read (a string at the top object's level), or null. */
  let key: string | null = null;
  let lastString: string | null = null;
  /** The key whose value comes next, at the top object's level. */
  let pendingKey: string | null = null;
  let inArray = false;
  let seen = false;
  let item: string | null = null;
  let started = false;

  const feed = (text: string) => {
    for (const c of text) {
      if (item !== null) {
        item += c;
        if (item.length > maxItemChars) throw new JsonItemsError("item too large");
      }
      if (inString) {
        if (escape) {
          escape = false;
          if (key !== null && key.length <= MAX_KEY_CHARS) key += c;
        } else if (c === "\\") {
          escape = true;
          if (key !== null && key.length <= MAX_KEY_CHARS) key += c;
        } else if (c === '"') {
          inString = false;
          if (key !== null) {
            lastString = key;
            key = null;
          }
        } else if (key !== null && key.length <= MAX_KEY_CHARS) {
          key += c;
        }
        continue;
      }
      switch (c) {
        case '"':
          if (inArray && depth === 2 && item === null) throw new JsonItemsError("item not an object");
          inString = true;
          if (depth === 1 && item === null) key = "";
          break;
        case ":":
          if (depth === 1) pendingKey = lastString;
          break;
        case ",":
          if (depth === 1) pendingKey = null;
          break;
        case "{":
        case "[":
          if (depth === 0) {
            if (c !== "{" || started) throw new JsonItemsError("not an object");
            started = true;
          }
          if (inArray && depth === 2 && item === null) {
            if (c !== "{") throw new JsonItemsError("item not an object");
            item = c;
          }
          if (c === "[" && depth === 1 && pendingKey === field && !seen) {
            inArray = true;
            seen = true;
          }
          depth += 1;
          break;
        case "}":
        case "]":
          depth -= 1;
          if (depth < 0) throw new JsonItemsError("unbalanced");
          if (item !== null && depth === 2) {
            const parsed: unknown = JSON.parse(item);
            item = null;
            onItem(parsed);
          }
          if (inArray && depth === 1) inArray = false;
          break;
        default:
          if (depth === 0 && !/\s/u.test(c)) throw new JsonItemsError("not an object");
          if (inArray && depth === 2 && item === null && !/[\s,]/u.test(c)) throw new JsonItemsError("item not an object");
      }
    }
  };

  const end = () => {
    if (!started || depth !== 0 || inString || !seen) throw new JsonItemsError("incomplete");
  };

  return { feed, end };
};
