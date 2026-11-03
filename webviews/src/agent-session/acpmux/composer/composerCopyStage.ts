import type { ComposerCopy, CopyItem } from "./composerCopy";
import { base64 } from "./imageWork";

type Call = <T>(method: string, params: Record<string, unknown>) => Promise<T>;
type Reply = { copyID?: string; files?: { item?: unknown; name?: unknown }[] };
type Payload = { data: string } | { text: string };
type Options = { signal?: AbortSignal; progress?: (written: number, total: number) => void };

// A routing threshold, not an attachment limit. Larger copies cross the bridge as bounded chunks.
const INLINE_BYTES = 256 * 1024;
const CHUNK_BYTES = 192 * 1024; // divisible by three, so base64 chunks keep their byte boundaries
const TEXT_CHARS = CHUNK_BYTES / 3;
const encoder = new TextEncoder();

function* textBytes(text: string): Generator<Uint8Array> {
  for (let at = 0; at < text.length;) {
    let end = Math.min(at + TEXT_CHARS, text.length);
    const last = text.charCodeAt(end - 1);
    if (end < text.length && last >= 0xd800 && last <= 0xdbff) end--;
    yield encoder.encode(text.slice(at, end));
    at = end;
  }
}

function sizeOf(payload: Payload): number {
  if ("data" in payload)
    return (payload.data.length / 4) * 3 - (payload.data.endsWith("==") ? 2 : payload.data.endsWith("=") ? 1 : 0);
  let size = 0;
  for (const bytes of textBytes(payload.text)) size += bytes.length;
  return size;
}

function* chunks(payload: Payload): Generator<{ data: string; bytes: number }> {
  if ("data" in payload) {
    const chars = (CHUNK_BYTES / 3) * 4;
    for (let at = 0; at < payload.data.length; at += chars) {
      const data = payload.data.slice(at, at + chars);
      yield { data, bytes: sizeOf({ data }) };
    }
  } else for (const bytes of textBytes(payload.text)) yield { data: base64(bytes), bytes: bytes.length };
}

function abortable<T>(request: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return request;
  return new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason);
    signal.addEventListener("abort", abort, { once: true });
    const settled = () => signal.removeEventListener("abort", abort);
    void request.then(
      (value) => {
        settled();
        resolve(value);
      },
      (error: unknown) => {
        settled();
        reject(error);
      },
    );
    if (signal.aborted) abort();
  });
}

/// Copies large selections through local staging. Only bounded strings/byte arrays are created;
/// existing legacy base64 is sliced without decoding the whole file. Every acknowledgement must
/// advance by the exact chunk length. Cancelling or an error takes back all staged references.
export function stagesComposerCopy(copy: ComposerCopy): boolean {
  const estimate = copy.items.reduce(
    (sum, item) => sum + ("data" in item ? item.data.length : "text" in item ? item.text.length * 3 : 0),
    copy.text.length * 3,
  );
  return estimate > INLINE_BYTES;
}

export async function stageComposerCopy(copy: ComposerCopy, call: Call, options: Options = {}): Promise<Reply> {
  options.signal?.throwIfAborted();
  if (!stagesComposerCopy(copy)) return call<Reply>("composer.copy", { text: copy.text, items: copy.items });

  let orderOffset = 0;
  const order = copy.parts.map((part) => {
    if ("item" in part) return part;
    const start = orderOffset;
    let length = part.text.length;
    for (let at = part.text.indexOf("\r\n"); at !== -1; at = part.text.indexOf("\r\n", at + 2)) length--;
    orderOffset += length;
    return { range: [start, orderOffset] };
  });
  const payloads: Payload[] = [{ text: copy.text }, { text: JSON.stringify(order) }];
  const indexes = new Map<number, number>();
  copy.items.forEach((item, index) => {
    if ("path" in item) return;
    indexes.set(index, payloads.length);
    payloads.push(item);
  });
  const manifest = payloads.map((payload, index) => ({ name: `copy-${index}`, size: sizeOf(payload) }));
  const total = manifest.reduce((sum, item) => sum + item.size, 0);
  const references: string[] = [];
  const tokens: string[] = [];
  let batchToken: string | undefined;
  let written = 0;
  const check = () => options.signal?.throwIfAborted();
  try {
    options.progress?.(0, total);
    for (const [index, payload] of payloads.entries()) {
      check();
      const started = await call<{ token: string; batchToken?: string; chunkSize: number }>("composer.copy.begin", {
        ...manifest[index],
        ...(batchToken ? { batchToken } : { batch: manifest }),
      });
      if (!started.token) throw new Error("composer.copy.stage-unavailable");
      tokens.push(started.token);
      batchToken ??= started.batchToken;
      if (started.chunkSize < CHUNK_BYTES) throw new Error("composer.copy.stage-unavailable");
      let offset = 0;
      for (const chunk of chunks(payload)) {
        check();
        const next = await call<{ offset: number }>("composer.copy.chunk", {
          token: started.token,
          offset,
          data: chunk.data,
        });
        offset += chunk.bytes;
        if (next.offset !== offset) throw new Error("composer.copy.incomplete-chunk");
        written += chunk.bytes;
        options.progress?.(written, total);
      }
      check();
      const done = await call<{ reference: string }>("composer.copy.finish", { token: started.token });
      if (!done.reference) throw new Error("composer.copy.missing-reference");
      references.push(done.reference);
    }
    check();
    const items = copy.items.map((item: CopyItem, index) => {
      const payload = indexes.get(index);
      return payload === undefined
        ? item
        : { name: item.name, mimeType: item.mimeType, reference: references[payload] };
    });
    return await abortable(
      call<Reply>("composer.copy.staged", { text: references[0], order: references[1], items }),
      options.signal,
    );
  } catch (error) {
    await Promise.allSettled(tokens.map((token) => call("composer.copy.cancel", { token })));
    throw error;
  }
}
