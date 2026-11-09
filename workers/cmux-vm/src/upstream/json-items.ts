/**
 * Reads the objects of one top-level array field of a JSON document as its text streams in, holding only the item being
 * read: a listing far larger than the 1 MiB a whole provider reply may be (live-http.ts) is read item by item, and only
 * what `onItem` keeps of each stays in memory. Used for the provider's tunnel listing, which has no paging
 * (src/upstream/orphan-sweep.ts).
 *
 * The whole document is checked against the JSON grammar as it streams, not just its nesting: each `}` and `]` must
 * close its own opener, object members and array elements must be separated by exactly one comma, a key must be
 * followed by a colon, literals and numbers must be well formed, strings may hold no raw control character and only
 * valid escapes, and the document is exactly one object with nothing but whitespace after it. The document must have
 * `field` once, as an array of objects; each item is also parsed with JSON.parse. Any violation, an item over
 * `maxItemChars`, or a document that ends early throws, and the caller must then act on none of the items it was
 * handed (the sweep deletes only after `end` returned).
 */

export class JsonItemsError extends Error {}

/** Longest key the scanner compares; a longer one never matches `field`. */
const MAX_KEY_CHARS = 256;
/** Longest number or literal outside the items (`true`, a count): anything longer is not a listing. */
const MAX_TOKEN_CHARS = 64;
const TOKEN_CHAR = /[0-9a-zA-Z+\-.]/u;
const NUMBER = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$/u;
const HEX = /[0-9a-fA-F]/u;
const WHITESPACE = new Set([" ", "\t", "\n", "\r"]);

export interface JsonItemsScanner {
  /** The next piece of the document's text. */
  readonly feed: (text: string) => void;
  /** The document ended: throws unless it was complete, valid, and had the field. */
  readonly end: () => void;
}

type ObjectState = "keyOrEnd" | "key" | "colon" | "value" | "commaOrEnd";
type ArrayState = "valueOrEnd" | "value" | "commaOrEnd";
type Frame =
  | { readonly kind: "object"; state: ObjectState }
  | { readonly kind: "array"; state: ArrayState; readonly items: boolean };

const fail = (reason: string): never => {
  throw new JsonItemsError(reason);
};

export const jsonItemsScanner = (field: string, maxItemChars: number, onItem: (item: unknown) => void): JsonItemsScanner => {
  const stack: Frame[] = [];
  /** Before the one top-level value, or after it (only whitespace may follow). */
  let top: "value" | "done" = "value";
  let inString = false;
  let stringIsKey = false;
  let escape = false;
  /** Hex digits still owed by a `\u` escape. */
  let hexLeft = 0;
  /** A top-level key being read, or null. */
  let key: string | null = null;
  /** The last top-level key read: the one whose value comes next. */
  let lastKey: string | null = null;
  let token = "";
  let seen = false;
  /** The text of the item being read, and the stack depth its object sits at. */
  let item: string | null = null;
  let itemDepth = 0;

  const current = (): Frame | undefined => stack[stack.length - 1];

  /** A value ended at the current position: the enclosing container (or the document) moves on. */
  const valueDone = () => {
    const frame = current();
    if (frame === undefined) top = "done";
    else frame.state = "commaOrEnd";
  };

  /** Whether a value may start here, failing otherwise; true when it is an item of the field's array. */
  const valueStarts = (): boolean => {
    const frame = current();
    if (frame === undefined) {
      if (top !== "value") fail("text after the document");
      return false;
    }
    if (frame.kind === "object") {
      if (frame.state !== "value") fail("a value where a key, colon, comma or end belongs");
      return false;
    }
    if (frame.state === "commaOrEnd") fail("a missing comma between array elements");
    return frame.items;
  };

  const finishToken = () => {
    if (token.length === 0) return;
    if (token !== "true" && token !== "false" && token !== "null" && !NUMBER.test(token)) fail("a malformed literal");
    token = "";
    valueDone();
  };

  const close = (kind: "object" | "array") => {
    const frame = current();
    if (frame === undefined || frame.kind !== kind) fail("a closer that does not match its opener");
    if (frame?.kind === "object" && frame.state !== "keyOrEnd" && frame.state !== "commaOrEnd") fail("an object closed after a comma or key");
    if (frame?.kind === "array" && frame.state !== "valueOrEnd" && frame.state !== "commaOrEnd") fail("an array closed after a comma");
    stack.pop();
    if (item !== null && stack.length === itemDepth - 1) {
      const text = item;
      item = null;
      onItem(JSON.parse(text));
    }
    valueDone();
  };

  const feed = (text: string) => {
    for (const c of text) {
      if (item !== null) {
        item += c;
        if (item.length > maxItemChars) fail("item too large");
      }
      if (inString) {
        if (hexLeft > 0) {
          if (!HEX.test(c)) fail("a malformed \\u escape");
          hexLeft -= 1;
        } else if (escape) {
          escape = false;
          if (c === "u") hexLeft = 4;
          else if (!'"\\/bfnrt'.includes(c)) fail("an invalid escape");
        } else if (c === "\\") {
          escape = true;
        } else if (c === '"') {
          inString = false;
          if (stringIsKey) {
            const frame = current();
            if (frame?.kind === "object") frame.state = "colon";
            if (key !== null) lastKey = key;
            key = null;
          } else {
            valueDone();
          }
          continue;
        } else if (c < " ") {
          fail("a raw control character in a string");
        }
        if (key !== null && key.length <= MAX_KEY_CHARS) key += c;
        continue;
      }
      if (TOKEN_CHAR.test(c)) {
        if (token.length === 0 && valueStarts()) fail("item not an object");
        token += c;
        if (token.length > MAX_TOKEN_CHARS) fail("a literal too long");
        continue;
      }
      finishToken();
      if (WHITESPACE.has(c)) continue;
      const frame = current();
      switch (c) {
        case '"': {
          if (frame?.kind === "object" && (frame.state === "keyOrEnd" || frame.state === "key")) {
            stringIsKey = true;
            key = stack.length === 1 && item === null ? "" : null;
          } else {
            if (valueStarts()) fail("item not an object");
            stringIsKey = false;
          }
          inString = true;
          break;
        }
        case ":":
          if (frame?.kind !== "object" || frame.state !== "colon") fail("a colon out of place");
          if (frame?.kind === "object") frame.state = "value";
          break;
        case ",":
          if (frame === undefined || frame.state !== "commaOrEnd") fail("a comma out of place");
          if (frame?.kind === "object") frame.state = "key";
          else if (frame?.kind === "array") frame.state = "value";
          break;
        case "{": {
          if (frame === undefined && top === "value") {
            stack.push({ kind: "object", state: "keyOrEnd" });
            break;
          }
          if (frame === undefined) fail("text after the document");
          const isItem = valueStarts();
          stack.push({ kind: "object", state: "keyOrEnd" });
          if (isItem) {
            item = "{";
            itemDepth = stack.length;
          }
          break;
        }
        case "[": {
          if (frame === undefined) fail(top === "value" ? "not an object" : "text after the document");
          if (valueStarts()) fail("item not an object");
          const isField = stack.length === 1 && item === null && lastKey === field;
          if (isField) {
            if (seen) fail("the field twice");
            seen = true;
          }
          stack.push({ kind: "array", state: "valueOrEnd", items: isField });
          break;
        }
        case "}":
          close("object");
          break;
        case "]":
          close("array");
          break;
        default:
          fail("an unexpected character");
      }
    }
  };

  const end = () => {
    if (inString) fail("incomplete");
    finishToken();
    if (top !== "done" || stack.length > 0 || !seen) fail("incomplete");
  };

  return { feed, end };
};
