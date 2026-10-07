/**
 * Rewrites the provider's exec result, a JSON object, into the public
 * ExecResult `{"exitCode":…,"stdout":"…","stderr":"…"}` as bytes arrive.
 *
 * Output can be megabytes, so nothing is buffered: string contents pass
 * through byte for byte (JSON escapes included, so the output stays valid
 * JSON), and only object keys and the exit code token are held, each capped.
 * Every field the provider adds besides statusCode, stdout and stderr is
 * skipped, whatever its shape, so a new provider field can never reach a
 * client. A truncated or malformed upstream body errors the stream rather
 * than ending it as if it were complete.
 */

const QUOTE = 0x22;
const BACKSLASH = 0x5c;
const COLON = 0x3a;
const COMMA = 0x2c;
const OPEN_BRACE = 0x7b;
const CLOSE_BRACE = 0x7d;
const OPEN_BRACKET = 0x5b;
const CLOSE_BRACKET = 0x5d;

const MAX_KEY_BYTES = 64;
const MAX_SCALAR_BYTES = 32;

const isSpace = (byte: number) => byte === 0x20 || byte === 0x09 || byte === 0x0a || byte === 0x0d;

type Field = "exitCode" | "stdout" | "stderr";

const PUBLIC_NAME: Readonly<Record<string, Field>> = { statusCode: "exitCode", stdout: "stdout", stderr: "stderr" };

type State =
  | { readonly at: "start" }
  | { readonly at: "key_or_end" }
  | { readonly at: "key_after_comma" }
  | { readonly at: "key"; bytes: number[]; escaped: boolean; overflow: boolean }
  | { readonly at: "colon"; readonly field: Field | null }
  | { readonly at: "value"; readonly field: Field | null }
  /** Copying a stdout/stderr string's contents to the output. */
  | { readonly at: "copy"; escaped: boolean }
  /** Reading the exit code (a number or null). */
  | { readonly at: "scalar"; readonly field: Field; bytes: number[] }
  /** Skipping an unknown value of any shape. */
  | { readonly at: "skip"; depth: number; inString: boolean; escaped: boolean; scalar: boolean }
  | { readonly at: "after_value" }
  | { readonly at: "end" };

class MalformedUpstreamBody extends Error {
  constructor(reason: string) {
    super(`malformed exec result from upstream: ${reason}`);
  }
}

const encoder = new TextEncoder();

export function execResultStream(): TransformStream<Uint8Array, Uint8Array> {
  let state: State = { at: "start" };
  const written = new Set<Field>();

  return new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      const out: Array<Uint8Array> = [];
      const emit = (text: string) => out.push(encoder.encode(text));
      const openField = (field: Field) => {
        emit(`${written.size === 0 ? "" : ","}"${field}":`);
        written.add(field);
      };
      // A string being copied may continue from the previous chunk.
      let copyFrom = state.at === "copy" ? 0 : -1;
      const flushCopy = (end: number) => {
        if (copyFrom >= 0 && end > copyFrom) out.push(chunk.slice(copyFrom, end));
        copyFrom = -1;
      };

      for (let index = 0; index < chunk.length; index += 1) {
        const byte = chunk[index] ?? 0;
        switch (state.at) {
          case "start":
            if (isSpace(byte)) break;
            if (byte !== OPEN_BRACE) throw new MalformedUpstreamBody("not an object");
            emit("{");
            state = { at: "key_or_end" };
            break;
          case "key_or_end":
          case "key_after_comma":
            if (isSpace(byte)) break;
            if (byte === CLOSE_BRACE && state.at === "key_or_end") {
              state = { at: "end" };
              break;
            }
            if (byte !== QUOTE) throw new MalformedUpstreamBody("expected a key");
            state = { at: "key", bytes: [], escaped: false, overflow: false };
            break;
          case "key":
            if (state.escaped) {
              state.escaped = false;
              state.overflow = true;
              break;
            }
            if (byte === BACKSLASH) {
              state.escaped = true;
              break;
            }
            if (byte === QUOTE) {
              const name = state.overflow ? "" : new TextDecoder().decode(new Uint8Array(state.bytes));
              const field = Object.hasOwn(PUBLIC_NAME, name) ? (PUBLIC_NAME[name] ?? null) : null;
              state = { at: "colon", field: field !== null && written.has(field) ? null : field };
              break;
            }
            if (state.bytes.length >= MAX_KEY_BYTES) state.overflow = true;
            else state.bytes.push(byte);
            break;
          case "colon":
            if (isSpace(byte)) break;
            if (byte !== COLON) throw new MalformedUpstreamBody("expected ':'");
            state = { at: "value", field: state.field };
            break;
          case "value": {
            if (isSpace(byte)) break;
            const field = state.field;
            if (field === "stdout" || field === "stderr") {
              if (byte === QUOTE) {
                openField(field);
                emit('"');
                state = { at: "copy", escaped: false };
                copyFrom = index + 1;
                break;
              }
              // null: emitted as "" when the object ends.
              state = { at: "skip", depth: 0, inString: false, escaped: false, scalar: true };
              index -= 1;
              break;
            }
            if (field === "exitCode") {
              state = { at: "scalar", field, bytes: [] };
              index -= 1;
              break;
            }
            if (byte === QUOTE) state = { at: "skip", depth: 0, inString: true, escaped: false, scalar: false };
            else if (byte === OPEN_BRACE || byte === OPEN_BRACKET) state = { at: "skip", depth: 1, inString: false, escaped: false, scalar: false };
            else state = { at: "skip", depth: 0, inString: false, escaped: false, scalar: true };
            break;
          }
          case "copy":
            if (state.escaped) {
              state.escaped = false;
              break;
            }
            if (byte === BACKSLASH) {
              state.escaped = true;
              break;
            }
            if (byte === QUOTE) {
              flushCopy(index + 1);
              state = { at: "after_value" };
            }
            break;
          case "scalar":
            if (byte === COMMA || byte === CLOSE_BRACE || isSpace(byte)) {
              const token = new TextDecoder().decode(new Uint8Array(state.bytes));
              if (token !== "null" && !/^-?\d{1,10}$/u.test(token)) throw new MalformedUpstreamBody("exit code is not an integer");
              if (token !== "null") {
                openField(state.field);
                emit(String(Number(token)));
              }
              state = { at: "after_value" };
              index -= 1;
              break;
            }
            if (state.bytes.length >= MAX_SCALAR_BYTES) throw new MalformedUpstreamBody("exit code too long");
            state.bytes.push(byte);
            break;
          case "skip":
            if (state.inString) {
              if (state.escaped) state.escaped = false;
              else if (byte === BACKSLASH) state.escaped = true;
              else if (byte === QUOTE) {
                state.inString = false;
                if (state.depth === 0) state = { at: "after_value" };
              }
              break;
            }
            if (state.scalar) {
              if (byte === COMMA || byte === CLOSE_BRACE || isSpace(byte)) {
                state = { at: "after_value" };
                index -= 1;
              }
              break;
            }
            if (byte === QUOTE) state.inString = true;
            else if (byte === OPEN_BRACE || byte === OPEN_BRACKET) state.depth += 1;
            else if (byte === CLOSE_BRACE || byte === CLOSE_BRACKET) {
              state.depth -= 1;
              if (state.depth === 0) state = { at: "after_value" };
            }
            break;
          case "after_value":
            if (isSpace(byte)) break;
            if (byte === COMMA) state = { at: "key_after_comma" };
            else if (byte === CLOSE_BRACE) state = { at: "end" };
            else throw new MalformedUpstreamBody("expected ',' or '}'");
            break;
          case "end":
            if (!isSpace(byte)) throw new MalformedUpstreamBody("trailing data");
            break;
        }
      }
      if (state.at === "copy") flushCopy(chunk.length);
      for (const piece of out) controller.enqueue(piece);
    },
    flush(controller) {
      if (state.at !== "end") throw new MalformedUpstreamBody("truncated");
      const tail: string[] = [];
      const add = (field: Field, value: string) => {
        if (written.has(field)) return;
        tail.push(`${written.size === 0 && tail.length === 0 ? "" : ","}"${field}":${value}`);
      };
      add("exitCode", "null");
      add("stdout", '""');
      add("stderr", '""');
      controller.enqueue(encoder.encode(`${tail.join("")}}`));
    },
  });
}
